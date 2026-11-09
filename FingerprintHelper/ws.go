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

type wsOpenSpec struct {
	URL       string      `json:"url"`
	Headers   [][2]string `json:"headers"`
	Protocols []string    `json:"protocols"`
}

type wsSession struct {
	id       string
	conn     *websocket.Conn
	writeMu  sync.Mutex
	closed   sync.Once
	onCancel context.CancelFunc
}

var (
	wsMu       sync.Mutex
	wsSessions = map[string]*wsSession{}
)

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
	spec, err := profiles.Chrome_108.GetClientHelloSpec()
	if err != nil {
		raw.Close()
		return nil, err
	}
	uconn := utls.UClient(raw, &utls.Config{ServerName: host}, utls.HelloCustom, false, false, true)
	if err := uconn.ApplyPreset(&spec); err != nil {
		raw.Close()
		return nil, err
	}
	if err := uconn.HandshakeContext(ctx); err != nil {
		raw.Close()
		return nil, err
	}
	return uconn, nil
}

func openWebSocket(c *conn, id, jsonSpec string) {
	spec := wsOpenSpec{}
	if err := json.Unmarshal([]byte(jsonSpec), &spec); err != nil {
		_ = c.writeJSONLine("WSERR "+id+" ", map[string]string{"error": "bad json: " + err.Error()})
		return
	}

	ctx := registerCancel(id)
	defer releaseCancel(id)
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

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

	dialer := &websocket.Dialer{
		NetDialContext:    (&net.Dialer{Timeout: 15 * time.Second}).DialContext, // plain ws://
		NetDialTLSContext: dialTLSChrome,                                        // wss://, Chrome's ClientHello
		HandshakeTimeout:  15 * time.Second,
		Subprotocols:      spec.Protocols,
		// Chromium offers permessage-deflate on websocket upgrades.
		EnableCompression: true,
	}
	ws, response, err := dialer.DialContext(ctx, spec.URL, header)
	if err != nil {
		status := 0
		if response != nil {
			status = response.StatusCode
		}
		reason := err.Error()
		if len(reason) > 300 {
			reason = reason[:300]
		}
		_ = c.writeJSONLine("WSERR "+id+" ", struct {
			Error  string `json:"error"`
			Status int    `json:"status"`
		}{Error: reason, Status: status})
		return
	}

	session := &wsSession{id: id, conn: ws, onCancel: cancel}
	wsMu.Lock()
	wsSessions[id] = session
	wsMu.Unlock()

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
			session.finish()
			wsMu.Lock()
			delete(wsSessions, id)
			wsMu.Unlock()
			_ = c.writeJSONLine("WSCLOSED "+id+" "+strconv.Itoa(code)+" ", map[string]string{"reason": reason})
			return
		}
		kind := "binary"
		if messageType == websocket.TextMessage {
			kind = "text"
		}
		if err := c.writeLineAndBytes("WSMSG "+id+" "+kind+" "+strconv.Itoa(len(payload))+"\n", payload); err != nil {
			session.finish()
			return
		}
	}
}

func (s *wsSession) finish() {
	s.closed.Do(func() {
		s.conn.Close()
	})
}

func sendWebSocket(id, kind string, payload []byte) {
	wsMu.Lock()
	session := wsSessions[id]
	wsMu.Unlock()
	if session == nil {
		return
	}
	messageType := websocket.BinaryMessage
	if kind == "text" {
		messageType = websocket.TextMessage
	}
	session.writeMu.Lock()
	writeErr := session.conn.WriteMessage(messageType, payload)
	session.writeMu.Unlock()
	if writeErr != nil {
		session.finish()
	}
}

func closeWebSocket(id string, code int) {
	wsMu.Lock()
	session := wsSessions[id]
	delete(wsSessions, id)
	wsMu.Unlock()
	if session == nil {
		return
	}
	message := websocket.FormatCloseMessage(code, "")
	session.writeMu.Lock()
	_ = session.conn.WriteControl(websocket.CloseMessage, message, time.Now().Add(5*time.Second))
	session.writeMu.Unlock()
	session.finish()
	session.onCancel() // stops the read pump; WSCLOSED follows from its error
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
