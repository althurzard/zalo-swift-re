package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"strconv"
	"sync"
	"time"

	http0 "github.com/bogdanfinn/fhttp"
	"github.com/bogdanfinn/tls-client/profiles"
	utls "github.com/bogdanfinn/utls"
	"github.com/bogdanfinn/websocket"
)

// WebSockets dial with the same ClientHello as the HTTP path (Chrome 108's utls spec), so the
// realtime channel's handshake is indistinguishable too. The websocket fork is fhttp-based, so
// the handshake request's headers keep the order Olaz set them in.
//
// Each session has one writer goroutine fed by a buffered channel: WSSEND / WSCLOSE only
// enqueue, so a stalled upstream can never block the helper's command loop (and with it every
// other request on the connection). A write that misses its deadline, or a full queue, closes
// the session; the read pump then reports WSCLOSED as usual.

const (
	wsWriteTimeout = 15 * time.Second
	wsCloseTimeout = 5 * time.Second
	wsQueueSize    = 1024
)

type wsOpenSpec struct {
	URL       string      `json:"url"`
	Headers   [][2]string `json:"headers"`
	Protocols []string    `json:"protocols"`
}

type wsOutgoing struct {
	messageType int // websocket.TextMessage / BinaryMessage / CloseMessage
	payload     []byte
}

type wsSession struct {
	id     string
	conn   *websocket.Conn
	out    chan wsOutgoing
	done   chan struct{}
	closed sync.Once

	mu      sync.Mutex
	failure string // set when the session dies on a write (WSCLOSED then reports 1006 + this)
}

// dialTLSChrome performs the TCP connection and the TLS handshake with Chrome 108's ClientHello.
func dialTLSChrome(ctx context.Context, network, addr string) (net.Conn, error) {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		host = addr
	}
	raw, err := (&net.Dialer{Timeout: 15 * time.Second}).DialContext(ctx, network, addr)
	if err != nil {
		return nil, err
	}
	// Chrome_108 has no ClientHelloSpec factory in this utls build (ToSpec → "please implement this method"),
	// so dial with the predefined ClientHelloID itself. Chrome offers only http/1.1 in ALPN on a WebSocket's
	// connection (the upgrade is HTTP/1.1); do the same, or the server may pick h2 and refuse the upgrade.
	uconn := utls.UClient(raw, &utls.Config{ServerName: host, NextProtos: []string{"http/1.1"}},
		profiles.Chrome_108.GetClientHelloId(), false, false, true)
	if err := uconn.BuildHandshakeState(); err != nil {
		raw.Close()
		return nil, err
	}
	// The preset carries ALPN [h2, http/1.1] and ALPS (application_settings) for h2. Restrict ALPN
	// to http/1.1 and drop ALPS: BoringSSL only sends ALPS for an offered protocol that has
	// settings, so Chrome's http/1.1-only socket has none, and ALPS for h2 next to an ALPN without
	// h2 is an anomaly. HandshakeContext rebuilds the hello from these extensions (ApplyConfig
	// re-applies ALPN to the config and the handshake state; the padding is recomputed), and the
	// handshake state is updated here too so the server's ALPN answer is checked against it.
	extensions := uconn.Extensions[:0]
	for _, ext := range uconn.Extensions {
		switch typed := ext.(type) {
		case *utls.ALPNExtension:
			typed.AlpnProtocols = []string{"http/1.1"}
		case *utls.ApplicationSettingsExtension, *utls.ApplicationSettingsExtensionNew:
			continue
		}
		extensions = append(extensions, ext)
	}
	uconn.Extensions = extensions
	uconn.HandshakeState.Hello.AlpnProtocols = []string{"http/1.1"}
	if err := uconn.MarshalClientHello(); err != nil {
		raw.Close()
		return nil, err
	}
	if err := uconn.HandshakeContext(ctx); err != nil {
		raw.Close()
		return nil, err
	}
	if negotiated := uconn.ConnectionState().NegotiatedProtocol; negotiated != "" && negotiated != "http/1.1" {
		uconn.Close()
		return nil, errors.New("tls: server negotiated " + negotiated + " for a websocket")
	}
	return uconn, nil
}

// openWebSocket runs the whole session: dial, then the read pump until the socket ends. ctx is
// the id's registration (CANCEL / WSCLOSE cancel it, also while dialing); release ends it.
func openWebSocket(ctx context.Context, release func(), c *conn, id, jsonSpec string) {
	defer release()
	spec := wsOpenSpec{}
	if err := json.Unmarshal([]byte(jsonSpec), &spec); err != nil {
		_ = c.writeJSONLine("WSERR "+id+" ", map[string]string{"error": "bad json: " + err.Error()})
		return
	}

	header := make(http0.Header)
	var order []string
	for _, entry := range spec.Headers {
		if entry[0] == "" {
			continue
		}
		header.Set(entry[0], entry[1])
		order = append(order, entry[0])
	}
	// fhttp only sends headers registered in HeaderOrderKey (in that order).
	header[http0.HeaderOrderKey] = order

	// The dialer honours ctx while connecting and in the TLS handshake, but not while it writes
	// the upgrade request and reads the response (only HandshakeTimeout bounds that). Track the
	// connections it dials and close them when ctx is cancelled, so a WSCLOSE / CANCEL during the
	// open aborts it at once.
	var dialedMu sync.Mutex
	var dialed []net.Conn
	track := func(dial func(context.Context, string, string) (net.Conn, error)) func(context.Context, string, string) (net.Conn, error) {
		return func(dialCtx context.Context, network, addr string) (net.Conn, error) {
			nc, err := dial(dialCtx, network, addr)
			if err != nil {
				return nil, err
			}
			dialedMu.Lock()
			dialed = append(dialed, nc)
			dialedMu.Unlock()
			if ctx.Err() != nil {
				nc.Close()
			}
			return nc, nil
		}
	}
	stopAbort := context.AfterFunc(ctx, func() {
		dialedMu.Lock()
		defer dialedMu.Unlock()
		for _, nc := range dialed {
			nc.Close()
		}
	})

	dialer := &websocket.Dialer{
		NetDialContext:    track((&net.Dialer{Timeout: 15 * time.Second}).DialContext), // plain ws://
		NetDialTLSContext: track(dialTLSChrome),                                        // wss://, Chrome's ClientHello
		HandshakeTimeout:  15 * time.Second,
		Subprotocols:      spec.Protocols,
		// Chromium offers permessage-deflate on websocket upgrades.
		EnableCompression: true,
	}
	ws, response, err := dialer.DialContext(ctx, spec.URL, header)
	stopAbort()
	if err == nil && ctx.Err() != nil {
		ws.Close()
		err = context.Canceled
	}
	if err != nil {
		status := 0
		if response != nil {
			status = response.StatusCode
		}
		reason := err.Error()
		if ctx.Err() != nil {
			reason = "canceled"
		}
		if len(reason) > 300 {
			reason = reason[:300]
		}
		_ = c.writeJSONLine("WSERR "+id+" ", struct {
			Error  string `json:"error"`
			Status int    `json:"status"`
		}{Error: reason, Status: status})
		return
	}

	session := &wsSession{
		id: id, conn: ws,
		out:  make(chan wsOutgoing, wsQueueSize),
		done: make(chan struct{}),
	}
	c.mu.Lock()
	c.ws[id] = session
	c.mu.Unlock()
	go session.writeLoop()
	// A CANCEL of the id, or the Olaz connection ending, closes the socket; the read pump below
	// then exits. (release cancels ctx too, after the session is already finished.)
	stopClose := context.AfterFunc(ctx, session.finish)
	defer stopClose()

	// Every exit of the read pump drops the session, so later WSSENDs for it are discarded.
	defer func() {
		c.mu.Lock()
		if c.ws[id] == session {
			delete(c.ws, id)
		}
		c.mu.Unlock()
		session.finish()
	}()

	negotiated := ""
	if response != nil && len(response.Header) > 0 {
		if values := response.Header["Sec-WebSocket-Protocol"]; len(values) > 0 {
			negotiated = values[0]
		}
	}
	_ = c.writeJSONLine("WSOPENED "+id+" ", map[string]string{"protocol": negotiated})

	// Read pump: every message goes back to Olaz; a close frame or error ends the session.
	for {
		messageType, payload, readErr := ws.ReadMessage()
		if readErr != nil {
			code, reason := closeDetails(readErr)
			if failure := session.failureReason(); failure != "" {
				code, reason = 1006, failure
			}
			session.finish()
			_ = c.writeJSONLine("WSCLOSED "+id+" "+strconv.Itoa(code)+" ", map[string]string{"reason": reason})
			return
		}
		kind := "binary"
		if messageType == websocket.TextMessage {
			kind = "text"
		}
		if err := c.writeLineAndBytes("WSMSG "+id+" "+kind+" "+strconv.Itoa(len(payload))+"\n", payload); err != nil {
			return // Olaz went away
		}
	}
}

// writeLoop is the session's only writer of data and close frames (gorilla allows one
// concurrent writer; pongs from the read pump go through WriteControl, which is safe).
func (s *wsSession) writeLoop() {
	for {
		select {
		case <-s.done:
			return
		case message := <-s.out:
			if message.messageType == websocket.CloseMessage {
				_ = s.conn.WriteControl(websocket.CloseMessage, message.payload, time.Now().Add(wsCloseTimeout))
				s.finish()
				return
			}
			if err := s.conn.SetWriteDeadline(time.Now().Add(wsWriteTimeout)); err != nil {
				s.fail("write: " + err.Error())
				return
			}
			if err := s.conn.WriteMessage(message.messageType, message.payload); err != nil {
				s.fail("write: " + err.Error())
				return
			}
		}
	}
}

// enqueue never blocks: a session whose queue is full is stalled upstream and is closed.
func (s *wsSession) enqueue(message wsOutgoing) {
	select {
	case <-s.done:
	case s.out <- message:
	default:
		s.fail("send queue full (upstream stalled)")
	}
}

func (s *wsSession) fail(reason string) {
	s.mu.Lock()
	if s.failure == "" {
		if len(reason) > 300 {
			reason = reason[:300]
		}
		s.failure = reason
	}
	s.mu.Unlock()
	s.finish()
}

func (s *wsSession) failureReason() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.failure
}

func (s *wsSession) finish() {
	s.closed.Do(func() {
		close(s.done)
		s.conn.Close()
	})
}

func lookupWebSocket(c *conn, id string) *wsSession {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.ws[id]
}

func sendWebSocket(c *conn, id, kind string, payload []byte) {
	session := lookupWebSocket(c, id)
	if session == nil {
		return
	}
	messageType := websocket.BinaryMessage
	if kind == "text" {
		messageType = websocket.TextMessage
	}
	session.enqueue(wsOutgoing{messageType: messageType, payload: payload})
}

// closeWebSocket sends a close frame after anything already queued, then closes the socket (the
// read pump reports WSCLOSED). For an id still dialing — or not even opened yet — it cancels
// the id instead, which aborts the dial (WSERR follows).
func closeWebSocket(c *conn, id string, code int) {
	session := lookupWebSocket(c, id)
	if session == nil {
		c.cancel(id)
		return
	}
	select {
	case <-session.done:
	case session.out <- wsOutgoing{messageType: websocket.CloseMessage, payload: websocket.FormatCloseMessage(code, "")}:
	default:
		session.finish() // queue full: skip the close frame, just drop the socket
	}
}

// closeDetails maps a read error to the websocket close code (1006 for anything abnormal).
func closeDetails(err error) (int, string) {
	var closeErr *websocket.CloseError
	if errors.As(err, &closeErr) {
		return closeErr.Code, closeErr.Text
	}
	if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) || errors.Is(err, net.ErrClosed) {
		return 1005, ""
	}
	if errors.Is(err, context.Canceled) {
		return 1000, ""
	}
	return 1006, ""
}
