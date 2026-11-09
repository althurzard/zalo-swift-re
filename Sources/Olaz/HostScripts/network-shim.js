// Olaz host script — injected at document start into the official Zalo renderer.
//
// Electron's renderer reached Zalo servers directly from a file:// page. Inside
// WKWebView we serve the renderer from zalo-app:// instead, so http(s)/ws(s)
// traffic is proxied through Swift's URLSession (cookie jar, user agent, no CORS).
// Local zalo-app:// loads keep using the native implementations.
(() => {
  'use strict';
  if (window.__zaloNet) return;
  const native = { XHR: window.XMLHttpRequest, fetch: window.fetch.bind(window), WebSocket: window.WebSocket };
  window.__zaloNativeXHR = native.XHR; // bridge.js uses it for synchronous bridge calls
  const bridge = (msg) => window.webkit.messageHandlers.znet.postMessage(msg);
  const isRemote = (url) => /^(https?|wss?):/i.test(String(url));
  const absolute = (url) => new URL(String(url), location.href).href;

  const toBase64 = (bytes) => {
    let s = '';
    for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    return btoa(s);
  };
  const fromBase64 = (b64) => {
    const s = atob(b64 || '');
    const out = new Uint8Array(s.length);
    for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
    return out;
  };

  // Encodes any XHR/fetch body into a JSON-safe description for Swift.
  async function encodeBody(body) {
    if (body == null) return null;
    if (typeof body === 'string') return { kind: 'text', text: body };
    if (body instanceof URLSearchParams) return { kind: 'text', text: body.toString(), contentType: 'application/x-www-form-urlencoded;charset=UTF-8' };
    if (body instanceof ArrayBuffer) return { kind: 'base64', data: toBase64(new Uint8Array(body)) };
    if (ArrayBuffer.isView(body)) return { kind: 'base64', data: toBase64(new Uint8Array(body.buffer, body.byteOffset, body.byteLength)) };
    if (body instanceof Blob) return { kind: 'base64', data: toBase64(new Uint8Array(await body.arrayBuffer())), contentType: body.type || undefined };
    if (body instanceof FormData) {
      const parts = [];
      for (const [name, value] of body.entries()) {
        if (typeof value === 'string') parts.push({ name, value });
        else parts.push({ name, filename: value.name || 'blob', type: value.type || 'application/octet-stream', data: toBase64(new Uint8Array(await value.arrayBuffer())) });
      }
      return { kind: 'formdata', parts };
    }
    return { kind: 'text', text: String(body) };
  }

  // ---------------------------------------------------------------- XHR
  class ProxiedXHR extends EventTarget {
    constructor() {
      super();
      this._native = null;
      this.readyState = 0; this.status = 0; this.statusText = ''; this.response = null; this.responseText = '';
      this.responseType = ''; this.responseURL = ''; this.timeout = 0; this.withCredentials = false;
      this._headers = {}; this._respHeaders = {}; this._aborted = false;
      this.upload = new EventTarget();
      for (const k of ['onreadystatechange','onload','onerror','onabort','ontimeout','onloadend','onloadstart','onprogress']) this[k] = null;
    }
    _emit(type, init) {
      const ev = new ProgressEvent(type, init || {});
      const h = this['on' + type];
      if (typeof h === 'function') { try { h.call(this, ev); } catch (e) { setTimeout(() => { throw e; }); } }
      this.dispatchEvent(ev);
    }
    _state(n) { this.readyState = n; this._emit('readystatechange'); }
    open(method, url, async = true, user, password) {
      this._method = String(method || 'GET').toUpperCase();
      this._url = absolute(url);
      if (!isRemote(this._url)) {
        // Local resource: delegate entirely to the native XHR.
        const x = this._native = new native.XHR();
        const sync = () => { for (const k of ['readyState','status','statusText','responseURL']) this[k] = x[k];
          try { this.response = x.response; } catch {} try { if (x.responseType === '' || x.responseType === 'text') this.responseText = x.responseText; } catch {} };
        for (const t of ['readystatechange','load','error','abort','timeout','loadend','loadstart','progress'])
          x.addEventListener(t, () => { sync(); this._emit(t); });
        x.open(method, url, async, user, password);
        return;
      }
      this._state(1);
    }
    setRequestHeader(k, v) { if (this._native) return this._native.setRequestHeader(k, v); this._headers[k] = String(v); }
    overrideMimeType(m) { if (this._native) this._native.overrideMimeType(m); }
    getResponseHeader(k) { if (this._native) return this._native.getResponseHeader(k); const v = this._respHeaders[String(k).toLowerCase()]; return v === undefined ? null : v; }
    getAllResponseHeaders() { if (this._native) return this._native.getAllResponseHeaders(); return Object.entries(this._respHeaders).map(([k, v]) => k + ': ' + v).join('\r\n'); }
    abort() { if (this._native) return this._native.abort(); this._aborted = true; if (this.readyState > 0 && this.readyState < 4) { this._state(4); this._emit('abort'); this._emit('loadend'); } }
    send(body) {
      if (this._native) {
        this._native.responseType = this.responseType; this._native.timeout = this.timeout; this._native.withCredentials = this.withCredentials;
        return this._native.send(body);
      }
      this._emit('loadstart');
      encodeBody(body).then((encoded) => bridge({ op: 'http', method: this._method, url: this._url, headers: this._headers, body: encoded, timeout: this.timeout }))
        .then((res) => {
          if (this._aborted) return;
          if (!res || res.error) {
            this._state(4);
            this._emit(res && res.timedOut ? 'timeout' : 'error');
            this._emit('loadend');
            return;
          }
          this.status = res.status; this.statusText = res.statusText || ''; this.responseURL = res.url || this._url;
          this._respHeaders = {}; for (const [k, v] of Object.entries(res.headers || {})) this._respHeaders[k.toLowerCase()] = v;
          this._state(2); this._state(3);
          const bytes = fromBase64(res.body);
          const text = () => new TextDecoder().decode(bytes);
          switch (this.responseType) {
            case 'arraybuffer': this.response = bytes.buffer; break;
            case 'blob': this.response = new Blob([bytes], { type: this._respHeaders['content-type'] || '' }); break;
            case 'json': try { this.response = JSON.parse(text()); } catch { this.response = null; } break;
            default: this.responseText = text(); this.response = this.responseText;
          }
          this._emit('progress', { lengthComputable: true, loaded: bytes.length, total: bytes.length });
          this._state(4);
          this._emit('load', { lengthComputable: true, loaded: bytes.length, total: bytes.length });
          this._emit('loadend');
        }, () => { if (!this._aborted) { this._state(4); this._emit('error'); this._emit('loadend'); } });
    }
  }
  ProxiedXHR.UNSENT = 0; ProxiedXHR.OPENED = 1; ProxiedXHR.HEADERS_RECEIVED = 2; ProxiedXHR.LOADING = 3; ProxiedXHR.DONE = 4;
  window.XMLHttpRequest = ProxiedXHR;

  // ---------------------------------------------------------------- fetch
  window.fetch = async function (input, init = {}) {
    const req = input instanceof Request ? input : null;
    const url = absolute(req ? req.url : input);
    if (!isRemote(url)) return native.fetch(input, init);
    const method = (init.method || (req && req.method) || 'GET').toUpperCase();
    const headers = {};
    new Headers((req && req.headers) || undefined).forEach((v, k) => { headers[k] = v; });
    new Headers(init.headers || undefined).forEach((v, k) => { headers[k] = v; });
    let body = init.body;
    if (body === undefined && req && method !== 'GET' && method !== 'HEAD') body = await req.arrayBuffer();
    const res = await bridge({ op: 'http', method, url, headers, body: await encodeBody(body), timeout: 0 });
    if (!res || res.error) throw new TypeError('Failed to fetch' + (res && res.error ? ': ' + res.error : ''));
    const out = new Response([204, 205, 304].includes(res.status) ? null : fromBase64(res.body), { status: res.status, statusText: res.statusText || '', headers: res.headers || {} });
    Object.defineProperty(out, 'url', { value: res.url || url });
    return out;
  };

  // ---------------------------------------------------------------- WebSocket
  const sockets = new Map();
  let nextSocket = 1;
  class ProxiedWebSocket extends EventTarget {
    constructor(url, protocols) {
      super();
      this.url = absolute(url); this.protocol = ''; this.extensions = ''; this.binaryType = 'blob';
      this.readyState = 0; this.bufferedAmount = 0;
      this.onopen = this.onmessage = this.onclose = this.onerror = null;
      this._id = nextSocket++;
      sockets.set(this._id, this);
      bridge({ op: 'ws.open', id: this._id, url: this.url, protocols: protocols ? [].concat(protocols) : [] });
    }
    _emit(ev) { const h = this['on' + ev.type]; if (typeof h === 'function') { try { h.call(this, ev); } catch (e) { setTimeout(() => { throw e; }); } } this.dispatchEvent(ev); }
    send(data) {
      if (this.readyState !== 1) throw new DOMException('WebSocket is not open', 'InvalidStateError');
      if (typeof data === 'string') return bridge({ op: 'ws.send', id: this._id, text: data });
      const bytes = data instanceof ArrayBuffer ? new Uint8Array(data) : ArrayBuffer.isView(data) ? new Uint8Array(data.buffer, data.byteOffset, data.byteLength) : null;
      if (bytes) return bridge({ op: 'ws.send', id: this._id, data: toBase64(bytes) });
      if (data instanceof Blob) return data.arrayBuffer().then((b) => bridge({ op: 'ws.send', id: this._id, data: toBase64(new Uint8Array(b)) }));
    }
    close(code, reason) {
      if (this.readyState >= 2) return;
      this.readyState = 2;
      bridge({ op: 'ws.close', id: this._id, code: code || 1000, reason: reason || '' });
    }
  }
  ProxiedWebSocket.CONNECTING = 0; ProxiedWebSocket.OPEN = 1; ProxiedWebSocket.CLOSING = 2; ProxiedWebSocket.CLOSED = 3;
  window.WebSocket = function (url, protocols) {
    return isRemote(absolute(url)) ? new ProxiedWebSocket(url, protocols) : new native.WebSocket(url, protocols);
  };
  Object.assign(window.WebSocket, { CONNECTING: 0, OPEN: 1, CLOSING: 2, CLOSED: 3, prototype: ProxiedWebSocket.prototype });

  // ---------------------------------------------------------------- navigator.connection
  // Chromium's Network Information API (Electron 22 = Chromium 108); WebKit lacks it
  // and the official login layout assigns `navigator.connection.onchange` while
  // rendering. Swift (NWPathMonitor) updates it via `__zaloNet.connectionChanged`.
  if (!('connection' in navigator)) {
    const connection = new EventTarget();
    Object.assign(connection, { effectiveType: '4g', type: 'wifi', downlink: 10, downlinkMax: Infinity, rtt: 50, saveData: false, onchange: null });
    connection.addEventListener('change', (e) => { if (typeof connection.onchange === 'function') connection.onchange(e); });
    Object.defineProperty(Navigator.prototype, 'connection', { configurable: true, get: () => connection });
    window.__zaloConnection = connection;
  }

  // ---------------------------------------------------------------- Workers
  // Surface worker failures (their consoles are not hooked) in the host log.
  const NativeWorker = window.Worker;
  const hostLog = (s) => { try { window.webkit.messageHandlers.zlog.postMessage(s); } catch {} };
  window.Worker = function (url, options) {
    const w = new NativeWorker(url, options);
    const name = String(url).split('/').pop();
    hostLog('[worker] start ' + name);
    // Diagnostics forwarded by the DAL worker prelude (errors only, never record data).
    w.addEventListener('message', (e) => {
      const d = e.data;
      if (d && typeof d === 'object' && typeof d.__zhostLog === 'string') { e.stopImmediatePropagation(); hostLog('[worker:log] ' + name + ' ' + d.__zhostLog); }
    });
    w.addEventListener('error', (e) => hostLog('[worker:error] ' + name + ' ' + (e.message || '') + ' @' + (e.filename || '') + ':' + (e.lineno || '')));
    w.addEventListener('messageerror', () => hostLog('[worker:messageerror] ' + name));
    if (window.__zaloTraceWorkers) {
      const shape = (d) => { try { return d && typeof d === 'object' ? JSON.stringify(Object.fromEntries(Object.entries(d).slice(0, 6).map(([k, v]) => [k, typeof v === 'object' && v ? (Array.isArray(v) ? 'array' : Object.keys(v).slice(0, 6).join('|')) : (typeof v === 'string' ? v.slice(0, 40) : v)]))) : String(d).slice(0, 60); } catch { return '?'; } };
      w.addEventListener('message', (e) => hostLog('[worker:in] ' + name + ' ' + shape(e.data)));
      const post = w.postMessage.bind(w);
      w.postMessage = (d, t) => { hostLog('[worker:out] ' + name + ' ' + shape(d)); return post(d, t); };
    }
    return w;
  };
  window.Worker.prototype = NativeWorker.prototype;

  // Swift → JS socket events.
  window.__zaloNet = {
    connectionChanged(info) {
      const c = window.__zaloConnection;
      if (!c) return;
      Object.assign(c, info);
      c.dispatchEvent(new Event('change'));
    },
    socketEvent(id, type, payload) {
      const ws = sockets.get(id);
      if (!ws) return;
      switch (type) {
        case 'open': ws.readyState = 1; ws.protocol = payload.protocol || ''; ws._emit(new Event('open')); break;
        case 'text': ws._emit(new MessageEvent('message', { data: payload.text })); break;
        case 'binary': {
          const bytes = fromBase64(payload.data);
          ws._emit(new MessageEvent('message', { data: ws.binaryType === 'arraybuffer' ? bytes.buffer : new Blob([bytes]) }));
          break;
        }
        case 'error': ws._emit(new Event('error')); break;
        case 'close':
          ws.readyState = 3; sockets.delete(id);
          ws._emit(new CloseEvent('close', { code: payload.code || 1006, reason: payload.reason || '', wasClean: !!payload.wasClean }));
          break;
      }
    }
  };
})();
