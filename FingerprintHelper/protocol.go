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
// per-hop headers stay under its control, exactly like the URLSession path). They have no
// overall timeout (0 lifts tls-client's whole-request deadline, which would kill any stream
// longer than it): every request bounds itself with its own context instead —
// performRequest for the whole exchange, performStream for the response headers, then the
// stall watchdog for the body.
// defaultRequestTimeout bounds a request (or a stream's wait for headers) whose spec has no
// timeoutMs; it is the old client-wide timeout.
const defaultRequestTimeout = 600 * time.Second

var (
	httpFollow, httpNoFollow tls_client.HttpClient
	clientsOnce              sync.Once
	clientsErr               error
)

func httpClients() (follow, noFollow tls_client.HttpClient, err error) {
	clientsOnce.Do(func() {
		options := []tls_client.HttpClientOption{
			tls_client.WithTimeoutSeconds(0),
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

// conn is one Olaz↔helper connection: commands are read sequentially, replies are written
// from many goroutines under a lock. In-flight requests and websocket sessions belong to the
// connection that started them, so ids from another (or a later) connection never collide and
// everything still running is torn down when Olaz goes away.
type conn struct {
	net.Conn
	writeMu sync.Mutex

	ctx context.Context // cancelled when the connection ends

	mu        sync.Mutex
	inflight  map[string]*inflightEntry // REQ / WSOPEN ids, registered before their goroutine starts
	early     map[string]time.Time      // CANCEL / WSCLOSE for an id not registered yet
	finished  map[string]time.Time      // ids released recently: a late CANCEL for them is not "early"
	lastPrune time.Time
	ws        map[string]*wsSession
}

type inflightEntry struct {
	cancel context.CancelFunc
}

// earlyCancelTTL is how long a CANCEL that names an unknown id is remembered (Swift may send
// CANCEL before REQ when its task is already cancelled), and how long a released id is
// remembered so a CANCEL arriving just after completion is not mistaken for an early one.
const earlyCancelTTL = 10 * time.Second

func newConn(nc net.Conn, ctx context.Context) *conn {
	return &conn{
		Conn: nc, ctx: ctx,
		inflight: map[string]*inflightEntry{},
		early:    map[string]time.Time{},
		finished: map[string]time.Time{},
		ws:       map[string]*wsSession{},
	}
}

// register makes id cancellable. It runs on the command loop, before the goroutine that serves
// the id starts, so a CANCEL that follows the command always finds it; a CANCEL that came
// before it (remembered in early) cancels it right away. release must be called when done.
func (c *conn) register(id string) (ctx context.Context, release func()) {
	ctx, cancel := context.WithCancel(c.ctx)
	entry := &inflightEntry{cancel: cancel}
	c.mu.Lock()
	c.pruneLocked()
	delete(c.finished, id)
	if _, ok := c.early[id]; ok {
		delete(c.early, id)
		cancel()
	}
	c.inflight[id] = entry
	c.mu.Unlock()
	return ctx, func() {
		c.mu.Lock()
		if c.inflight[id] == entry {
			delete(c.inflight, id)
			c.finished[id] = time.Now()
		}
		c.mu.Unlock()
		cancel()
	}
}

// cancel cancels id if it is in flight; an id that is neither in flight nor recently finished
// is remembered briefly, in case its REQ / WSOPEN is still behind this command.
func (c *conn) cancel(id string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.pruneLocked()
	if entry, ok := c.inflight[id]; ok {
		entry.cancel()
		return
	}
	if _, ok := c.finished[id]; !ok {
		c.early[id] = time.Now()
	}
}

func (c *conn) pruneLocked() {
	now := time.Now()
	if now.Sub(c.lastPrune) < time.Second {
		return
	}
	c.lastPrune = now
	for id, at := range c.early {
		if now.Sub(at) > earlyCancelTTL {
			delete(c.early, id)
		}
	}
	for id, at := range c.finished {
		if now.Sub(at) > earlyCancelTTL {
			delete(c.finished, id)
		}
	}
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

// maxWSSendBytes caps one WSSEND payload; a larger one is read and dropped (framing intact).
const maxWSSendBytes = 64 << 20

func handleConn(nc net.Conn) {
	ctx, cancelAll := context.WithCancel(context.Background())
	defer nc.Close()
	defer cancelAll() // aborts every request and closes every websocket of this connection
	c := newConn(nc, ctx)

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
			requestCtx, release := c.register(id)
			go func(id, jsonSpec string) {
				defer release()
				spec := httpRequestSpec{}
				if err := json.Unmarshal([]byte(jsonSpec), &spec); err != nil {
					_ = c.writeJSONLine("ERR "+id+" ", httpResponseSpec{Error: "bad request json: " + err.Error()})
					return
				}
				if spec.Stream {
					performStream(requestCtx, c, id, spec)
				} else {
					performRequest(requestCtx, c, id, spec)
				}
			}(id, rest)
		case "CANCEL":
			if id != "" {
				c.cancel(id)
			}
		case "WSOPEN":
			if id != "" {
				dialCtx, release := c.register(id)
				go openWebSocket(dialCtx, release, c, id, rest)
			}
		case "WSSEND":
			// rest = "text|binary <len>". The payload must be consumed whatever else is wrong
			// with the frame; a length that cannot be read leaves no way to find the next frame.
			parts := strings.SplitN(rest, " ", 2)
			if len(parts) != 2 {
				log.Printf("wssend: malformed frame %q; closing connection", line)
				return
			}
			length, err := strconv.ParseInt(parts[1], 10, 64)
			if err != nil || length < 0 {
				log.Printf("wssend: bad length %q; closing connection", parts[1])
				return
			}
			if id == "" || length > maxWSSendBytes {
				if _, err := io.CopyN(io.Discard, reader, length); err != nil {
					log.Printf("wssend skip: %v", err)
					return
				}
				continue
			}
			payload := make([]byte, length)
			if _, err := io.ReadFull(reader, payload); err != nil {
				log.Printf("wssend read: %v", err)
				return
			}
			sendWebSocket(c, id, parts[0], payload)
		case "WSCLOSE":
			code := 1000
			if value, err := strconv.Atoi(rest); err == nil {
				code = value
			}
			if id != "" {
				closeWebSocket(c, id, code)
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
func performRequest(ctx context.Context, c *conn, id string, spec httpRequestSpec) {
	timeout := defaultRequestTimeout
	if spec.TimeoutMs > 0 {
		timeout = time.Duration(spec.TimeoutMs) * time.Millisecond
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

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
//
// Timeouts: timeoutMs (default defaultRequestTimeout) bounds only the wait for the response
// headers; the body has no overall deadline, only the stall watchdog (idleMs between reads,
// firstByteMs until the first body byte). END is sent only for a body read to EOF — a
// cancelled, stalled or failed stream ends with ERR so a truncated body is never complete.
func performStream(ctx context.Context, c *conn, id string, spec httpRequestSpec) {
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
	headerTimeout := defaultRequestTimeout
	if spec.TimeoutMs > 0 {
		headerTimeout = time.Duration(spec.TimeoutMs) * time.Millisecond
	}
	// A timer rather than context.WithTimeout: the same context must stay alive for the body.
	headerTimer := time.AfterFunc(headerTimeout, requestCancel)
	response, err := client.Do(request)
	headersInTime := headerTimer.Stop()
	if err != nil {
		message := "request: " + cleanError(err)
		if !headersInTime {
			message = "request: timed out waiting for response headers"
		}
		_ = c.writeJSONLine("ERR "+id+" ", httpResponseSpec{Error: message})
		return
	}
	defer response.Body.Close()
	if !headersInTime {
		_ = c.writeJSONLine("ERR "+id+" ", httpResponseSpec{Error: "request: timed out waiting for response headers"})
		return
	}

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
		watchdog.reading()
		n, readErr := response.Body.Read(buffer)
		if n > 0 {
			watchdog.received()
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
			switch {
			case errors.Is(readErr, io.EOF):
				_ = c.writeLine("END " + id + "\n")
			case watchdog.fired():
				_ = c.writeJSONLine("ERR "+id+" ", httpResponseSpec{Error: "body: stalled, no data within " + watchdog.window().String()})
			default:
				_ = c.writeJSONLine("ERR "+id+" ", httpResponseSpec{Error: "body: " + cleanError(readErr)})
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
// window applies until the first body byte, when FirstByteMs is set). Before the first byte
// the window runs from RESHEAD; after it, from the start of the current read, so time spent
// handing a chunk to Olaz never counts as an upstream stall.
type stallWatchdog struct {
	cancel    context.CancelFunc
	stopCh    chan struct{}
	stopOnce  sync.Once
	mu        sync.Mutex
	last      time.Time
	firstSeen bool
	expired   bool
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

func (w *stallWatchdog) windowLocked() time.Duration {
	if !w.firstSeen && w.firstByte > 0 {
		return w.firstByte
	}
	return w.idle
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
			expired := time.Since(w.last) > w.windowLocked()
			if expired {
				w.expired = true
			}
			w.mu.Unlock()
			if expired {
				w.cancel()
				return
			}
		}
	}
}

// reading is called before each body read.
func (w *stallWatchdog) reading() {
	w.mu.Lock()
	if w.firstSeen {
		w.last = time.Now()
	}
	w.mu.Unlock()
}

// received is called when a read returned bytes.
func (w *stallWatchdog) received() {
	w.mu.Lock()
	w.last = time.Now()
	w.firstSeen = true
	w.mu.Unlock()
}

// fired reports whether the watchdog cancelled the request.
func (w *stallWatchdog) fired() bool {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.expired
}

func (w *stallWatchdog) window() time.Duration {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.windowLocked()
}

func (w *stallWatchdog) stop() {
	w.stopOnce.Do(func() { close(w.stopCh) })
}
