package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	http "github.com/bogdanfinn/fhttp"
	tls_client "github.com/bogdanfinn/tls-client"
	"github.com/bogdanfinn/tls-client/profiles"
)

// Protocol (one line per command, LF-terminated; binary payloads are exactly <len> bytes and
// are followed immediately by the next frame, with no trailing newline):
//
//	client → server                          server → client
//	HELLO                                    OK <version> <profile>
//	REQ <id> {json}                          RES <id> {json}              (complete response)
//	                                         RESHEAD <id> {json}          (stream: headers only)
//	                                         CHUNK <id> <len>\n<bytes>    (stream body)
//	                                         END <id>                     (stream finished)
//	                                         ERR <id> {json}              (request failed)
//	CANCEL <id>
//	WSOPEN <id> {json}                       WSOPENED <id> {json} | WSERR <id> {json}
//	WSSEND <id> text|binary <len>\n<bytes>   WSMSG <id> text|binary <len>\n<bytes>
//	WSCLOSE <id> <code>                      WSCLOSED <id> <code> {json}
//	SHUTDOWN
//
// REQ JSON (one line): {"method","url","headers":[["name","value"],…],"bodyB64":"",
// "timeoutMs":0,"stream":false,"follow":true,"maxBytes":0,"idleMs":30000,"firstByteMs":0}
// RES JSON: {"status","statusText","headers":[[…]],"url","bodyB64","error"}

type httpRequestSpec struct {
	Method      string      `json:"method"`
	URL         string      `json:"url"`
	Headers     [][2]string `json:"headers"`
	BodyB64     string      `json:"bodyB64"`
	TimeoutMs   int         `json:"timeoutMs"`
	Stream      bool        `json:"stream"`
	Follow      bool        `json:"follow"`
	MaxBytes    int64       `json:"maxBytes"`
	IdleMs      int         `json:"idleMs"`
	FirstByteMs int         `json:"firstByteMs"`
}

type httpResponseSpec struct {
	Status     int         `json:"status"`
	StatusText string      `json:"statusText"`
	Headers    [][2]string `json:"headers"`
	URL        string      `json:"url"`
	BodyB64    string      `json:"bodyB64,omitempty"`
	Error      string      `json:"error,omitempty"`
}

// Two pooled clients: redirects followed (normal traffic) and not (Swift re-issues those so
// per-hop headers stay under its control, exactly like the URLSession path).
var (
	httpFollow, httpNoFollow tls_client.HttpClient
	clientsOnce              sync.Once
	clientsErr               error
)

func httpClients() (follow, noFollow tls_client.HttpClient, err error) {
	clientsOnce.Do(func() {
		options := []tls_client.HttpClientOption{
			tls_client.WithTimeoutSeconds(600),
			tls_client.WithClientProfile(profiles.Chrome_108),
			tls_client.WithCookieJar(nil), // Olaz passes cookies explicitly and harvests Set-Cookie itself
		}
		httpFollow, clientsErr = tls_client.NewHttpClient(tls_client.NewNoopLogger(), options...)
		if clientsErr == nil {
			noFollowOptions := append(append([]tls_client.HttpClientOption{}, options...), tls_client.WithNotFollowRedirects())
			httpNoFollow, clientsErr = tls_client.NewHttpClient(tls_client.NewNoopLogger(), noFollowOptions...)
		}
	})
	return httpFollow, httpNoFollow, clientsErr
}

// Cancellation for in-flight requests and websocket sessions, by id.
var (
	cancelsMu sync.Mutex
	cancels   = map[string]context.CancelFunc{}
)

func registerCancel(id string) context.Context {
	cancelsMu.Lock()
	defer cancelsMu.Unlock()
	ctx, cancel := context.WithCancel(context.Background())
	cancels[id] = cancel
	return ctx
}

func cancelRequest(id string) {
	cancelsMu.Lock()
	defer cancelsMu.Unlock()
	if cancel, ok := cancels[id]; ok {
		cancel()
	}
}

func releaseCancel(id string) {
	cancelsMu.Lock()
	defer cancelsMu.Unlock()
	delete(cancels, id)
}

// conn is one Olaz↔helper connection: commands are read sequentially, replies are written
// from many goroutines under a lock.
type conn struct {
	net.Conn
	writeMu sync.Mutex
}

func (c *conn) writeLine(line string) error {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	_, err := c.Conn.Write([]byte(line))
	return err
}

func (c *conn) writeLineAndBytes(line string, payload []byte) error {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	if _, err := c.Conn.Write([]byte(line)); err != nil {
		return err
	}
	_, err := c.Conn.Write(payload)
	return err
}

func (c *conn) writeJSONLine(prefix string, value any) error {
	encoded, err := json.Marshal(value)
	if err != nil {
		return err
	}
	return c.writeLine(prefix + string(encoded) + "\n")
}

func handleConn(nc net.Conn) {
	defer nc.Close()
	c := &conn{Conn: nc}

	reader := bufio.NewReaderSize(nc, 64<<10)
	for {
		line, err := reader.ReadString('\n')
		if err != nil {
			if !errors.Is(err, io.EOF) {
				log.Printf("read: %v", err)
			}
			return
		}
		line = strings.TrimRight(line, "\n")
		command, id, rest := splitCommand(line)
		switch command {
		case "HELLO":
			_ = c.writeLine("OK " + strconv.Itoa(helperVersion) + " " + profileName + "\n")
		case "REQ":
			if id == "" {
				continue
			}
			if debugPath := os.Getenv("FP_DEBUG"); debugPath != "" {
				if file, err := os.OpenFile(debugPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600); err == nil {
					fmt.Fprintf(file, "REQ-LINE: %q\n", line)
					file.Close()
				}
			}
			go func(id, jsonSpec string) {
				defer releaseCancel(id)
				spec := httpRequestSpec{}
				if err := json.Unmarshal([]byte(jsonSpec), &spec); err != nil {
					_ = c.writeJSONLine("ERR "+id+" ", httpResponseSpec{Error: "bad request json: " + err.Error()})
					return
				}
				if spec.Stream {
					performStream(c, id, spec)
				} else {
					performRequest(c, id, spec)
				}
			}(id, rest)
		case "CANCEL":
			if id != "" {
				cancelRequest(id)
			}
		case "WSOPEN":
			if id != "" {
				go openWebSocket(c, id, rest)
			}
		case "WSSEND":
			// rest = "text|binary <len>"
			parts := strings.SplitN(rest, " ", 2)
			if id == "" || len(parts) != 2 {
				continue
			}
			length, err := strconv.Atoi(parts[1])
			if err != nil || length < 0 {
				continue
			}
			payload := make([]byte, length)
			if _, err := io.ReadFull(reader, payload); err != nil {
				log.Printf("wssend read: %v", err)
				return
			}
			sendWebSocket(id, parts[0], payload)
		case "WSCLOSE":
			code := 1000
			if value, err := strconv.Atoi(rest); err == nil {
				code = value
			}
			if id != "" {
				closeWebSocket(id, code)
			}
		case "SHUTDOWN":
			_ = c.writeLine("BYE\n")
			return
		}
	}
}

// "REQ <id> <json…>" → ("REQ", "<id>", "<json…>")
func splitCommand(line string) (command, id, rest string) {
	first := strings.IndexByte(line, ' ')
	if first < 0 {
		return line, "", ""
	}
	command = line[:first]
	remainder := line[first+1:]
	second := strings.IndexByte(remainder, ' ')
	if second < 0 {
		return command, remainder, ""
	}
	return command, remainder[:second], remainder[second+1:]
}

// ---- HTTP ----

func newUpstreamRequest(ctx context.Context, spec httpRequestSpec) (*http.Request, error) {
	var body io.Reader
	if spec.BodyB64 != "" {
		decoded, err := base64.StdEncoding.DecodeString(spec.BodyB64)
		if err != nil {
			return nil, errors.New("bad bodyB64: " + err.Error())
		}
		body = bytes.NewReader(decoded)
	}
	request, err := http.NewRequestWithContext(ctx, spec.Method, spec.URL, body)
	if err != nil {
		return nil, err
	}
	// fhttp only sends headers listed in HeaderOrderKey (in that order); headers not
	// registered there are dropped. Registering every header also pins the wire order.
	var order []string
	for _, header := range spec.Headers {
		if header[0] == "" {
			continue
		}
		request.Header.Set(header[0], header[1])
		order = append(order, header[0])
	}
	request.Header[http.HeaderOrderKey] = order
	return request, nil
}

// non-streaming: the whole body in one RES frame (base64, capped).
func performRequest(c *conn, id string, spec httpRequestSpec) {
	ctx := registerCancel(id)
	defer releaseCancel(id)
	if spec.TimeoutMs > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, time.Duration(spec.TimeoutMs)*time.Millisecond)
		defer cancel()
	}

	follow, noFollow, err := httpClients()
	if err != nil {
		_ = c.writeJSONLine("ERR "+id+" ", httpResponseSpec{Error: "client: " + err.Error()})
		return
	}
	client := follow
	if !spec.Follow {
		client = noFollow
	}
	request, err := newUpstreamRequest(ctx, spec)
	if err != nil {
		_ = c.writeJSONLine("ERR "+id+" ", httpResponseSpec{Error: err.Error()})
		return
	}
	if debugPath := os.Getenv("FP_DEBUG"); debugPath != "" {
		if file, err := os.OpenFile(debugPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600); err == nil {
			fmt.Fprintf(file, "REQ-HEADERS: %v\n", request.Header)
			file.Close()
		}
	}
	response, err := client.Do(request)
	if err != nil {
		_ = c.writeJSONLine("ERR "+id+" ", httpResponseSpec{Error: "request: " + cleanError(err)})
		return
	}
	defer response.Body.Close()

	const maxBufferedBody = 64 << 20
	limit := int64(maxBufferedBody)
	if spec.MaxBytes > 0 && spec.MaxBytes < limit {
		limit = spec.MaxBytes
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, limit+1))
	if err != nil {
		_ = c.writeJSONLine("ERR "+id+" ", httpResponseSpec{Error: "body: " + cleanError(err)})
		return
	}
	if int64(len(body)) > limit {
		_ = c.writeJSONLine("ERR "+id+" ", httpResponseSpec{Error: "body too large; use stream"})
		return
	}
	_ = c.writeJSONLine("RES "+id+" ", httpResponseSpec{
		Status:     response.StatusCode,
		StatusText: response.Status,
		Headers:    responseHeaders(response),
		URL:        response.Request.URL.String(),
		BodyB64:    base64.StdEncoding.EncodeToString(body),
	})
}

// streaming: RESHEAD, then CHUNK frames until END (or ERR). Redirects are answered as a
// complete RES so Swift can re-issue them with its own per-hop headers.
func performStream(c *conn, id string, spec httpRequestSpec) {
	ctx := registerCancel(id)
	defer releaseCancel(id)
	ctx, requestCancel := context.WithCancel(ctx)
	defer requestCancel()

	follow, noFollow, err := httpClients()
	if err != nil {
		_ = c.writeJSONLine("ERR "+id+" ", httpResponseSpec{Error: "client: " + err.Error()})
		return
	}
	client := follow
	if !spec.Follow {
		client = noFollow
	}
	request, err := newUpstreamRequest(ctx, spec)
	if err != nil {
		_ = c.writeJSONLine("ERR "+id+" ", httpResponseSpec{Error: err.Error()})
		return
	}
	if debugPath := os.Getenv("FP_DEBUG"); debugPath != "" {
		if file, err := os.OpenFile(debugPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600); err == nil {
			fmt.Fprintf(file, "REQ-HEADERS: %v\n", request.Header)
			file.Close()
		}
	}
	response, err := client.Do(request)
	if err != nil {
		_ = c.writeJSONLine("ERR "+id+" ", httpResponseSpec{Error: "request: " + cleanError(err)})
		return
	}
	defer response.Body.Close()

	if response.StatusCode >= 300 && response.StatusCode < 400 {
		body, _ := io.ReadAll(io.LimitReader(response.Body, 1<<20))
		_ = c.writeJSONLine("RES "+id+" ", httpResponseSpec{
			Status:     response.StatusCode,
			StatusText: response.Status,
			Headers:    responseHeaders(response),
			URL:        response.Request.URL.String(),
			BodyB64:    base64.StdEncoding.EncodeToString(body),
		})
		return
	}

	_ = c.writeJSONLine("RESHEAD "+id+" ", httpResponseSpec{
		Status:     response.StatusCode,
		StatusText: response.Status,
		Headers:    responseHeaders(response),
		URL:        response.Request.URL.String(),
	})

	idle := time.Duration(spec.IdleMs) * time.Millisecond
	if idle <= 0 {
		idle = 30 * time.Second
	}
	firstByte := time.Duration(spec.FirstByteMs) * time.Millisecond
	watchdog := newStallWatchdog(requestCancel, idle, firstByte)
	defer watchdog.stop()

	var total int64
	buffer := make([]byte, 64<<10)
	for {
		watchdog.activity()
		n, readErr := response.Body.Read(buffer)
		if n > 0 {
			total += int64(n)
			if spec.MaxBytes > 0 && total > spec.MaxBytes {
				_ = c.writeJSONLine("ERR "+id+" ", httpResponseSpec{Error: "body too large"})
				return
			}
			if err := c.writeLineAndBytes("CHUNK "+id+" "+strconv.Itoa(n)+"\n", buffer[:n]); err != nil {
				return // Olaz went away
			}
		}
		if readErr != nil {
			if errors.Is(readErr, io.EOF) || errors.Is(readErr, context.Canceled) {
				_ = c.writeLine("END " + id + "\n")
			} else {
				_ = c.writeJSONLine("ERR "+id+" ", map[string]string{"error": "body: " + cleanError(readErr)})
			}
			return
		}
	}
}

func responseHeaders(response *http.Response) [][2]string {
	var headers [][2]string
	for name, values := range response.Header {
		for _, value := range values {
			headers = append(headers, [2]string{name, value})
		}
	}
	return headers
}

// cleanError makes transport failures read like transport failures (short, no Go internals).
func cleanError(err error) string {
	if errors.Is(err, context.Canceled) {
		return "canceled"
	}
	message := err.Error()
	if len(message) > 300 {
		message = message[:300]
	}
	return message
}

// stallWatchdog cancels the request when nothing arrives within the idle window (a shorter
// window applies until the first byte, when FirstByteMs is set).
type stallWatchdog struct {
	cancel    context.CancelFunc
	stopCh    chan struct{}
	mu        sync.Mutex
	last      time.Time
	firstSeen bool
	idle      time.Duration
	firstByte time.Duration
}

func newStallWatchdog(cancel context.CancelFunc, idle, firstByte time.Duration) *stallWatchdog {
	w := &stallWatchdog{
		cancel: cancel, stopCh: make(chan struct{}),
		idle: idle, firstByte: firstByte, last: time.Now(),
	}
	go w.loop()
	return w
}

func (w *stallWatchdog) loop() {
	ticker := time.NewTicker(250 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-w.stopCh:
			return
		case <-ticker.C:
			w.mu.Lock()
			window := w.idle
			if !w.firstSeen && w.firstByte > 0 {
				window = w.firstByte
			}
			expired := time.Since(w.last) > window
			w.mu.Unlock()
			if expired {
				w.cancel()
				return
			}
		}
	}
}

func (w *stallWatchdog) activity() {
	w.mu.Lock()
	w.last = time.Now()
	w.firstSeen = true
	w.mu.Unlock()
}

func (w *stallWatchdog) stop() {
	select {
	case <-w.stopCh:
	default:
		close(w.stopCh)
	}
}
