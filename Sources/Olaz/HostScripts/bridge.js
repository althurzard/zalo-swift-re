// Olaz host script — re-creates the Electron preload bridge ($z* globals)
// that the official Zalo renderer expects, backed by Swift (`ZaloBridge`).
//
// Members are declared by Swift in `__zaloBridgeSpec` (injected before this
// script): { "<global>.<member path>": "async" | "sync" | "event" | "off" | "value" }.
// Unknown members resolve to a logging stub so new requirements surface in the log.
(() => {
  'use strict';
  if (window.__zaloBridge) return;
  const spec = window.__zaloBridgeSpec || { members: {}, values: {}, globals: [] };
  const post = (msg) => window.webkit.messageHandlers.zbridge.postMessage(msg);
  const log = (...a) => { try { window.webkit.messageHandlers.zlog.postMessage(a.map(String).join(' ').slice(0, 500)); } catch {} };

  // Electron hands the renderer Uint8Array/ArrayBuffer through structured clone;
  // across WebKit message handlers we tag binary values as base64.
  const encode = (v) => {
    if (v instanceof ArrayBuffer) v = new Uint8Array(v);
    if (ArrayBuffer.isView(v)) {
      const b = new Uint8Array(v.buffer, v.byteOffset, v.byteLength); let s = '';
      for (let i = 0; i < b.length; i += 0x8000) s += String.fromCharCode.apply(null, b.subarray(i, i + 0x8000));
      return { __bytes: btoa(s) };
    }
    if (Array.isArray(v)) return v.map(encode);
    if (v && typeof v === 'object') { const o = {}; for (const k of Object.keys(v)) { if (typeof v[k] !== 'function') o[k] = encode(v[k]); } return o; }
    return typeof v === 'function' ? undefined : v;
  };
  const decode = (v) => {
    if (Array.isArray(v)) return v.map(decode);
    if (v && typeof v === 'object') {
      if (typeof v.__bytes === 'string') { const s = atob(v.__bytes); const u = new Uint8Array(s.length); for (let i = 0; i < s.length; i++) u[i] = s.charCodeAt(i); return v.__arraybuffer ? u.buffer : u; }
      if (v.__undefined) return undefined;
      if (v.__stats) {
        const st = { size: v.size, mode: v.mode, mtimeMs: v.mtimeMs, ctimeMs: v.ctimeMs, atimeMs: v.atimeMs, birthtimeMs: v.birthtimeMs,
          mtime: new Date(v.mtimeMs), ctime: new Date(v.ctimeMs), atime: new Date(v.atimeMs), birthtime: new Date(v.birthtimeMs) };
        st.isFile = () => v.isFile; st.isDirectory = () => v.isDirectory; st.isSymbolicLink = () => v.isSymbolicLink;
        return st;
      }
      const o = {}; for (const k of Object.keys(v)) o[k] = decode(v[k]); return o;
    }
    return v;
  };

  const listeners = new Map(); // event path -> Set(callback)
  let nextListener = 1;

  // Node errors carry `code` (ENOENT, EACCES…); Swift reports "CODE: detail".
  const toError = (e) => { const msg = String(e); const err = new Error(msg); const m = /^([A-Z][A-Z0-9_]+):/.exec(msg); if (m) err.code = m[1]; return err; };
  function callAsync(path, args) {
    // Node callback style: fs.access(p, mode, (err, result) => …)
    const cb = typeof args[args.length - 1] === 'function' ? args.pop() : null;
    const promise = post({ kind: 'call', path, args: encode(args) }).then((r) => decode(r), (e) => { throw toError(e); });
    if (!cb) return promise;
    if (/\.fs\.exists$/.test(path)) promise.then((r) => cb(!!r), () => cb(false)); // legacy fs.exists(p, cb(bool))
    else promise.then((r) => cb(null, r), (e) => cb(e));
    return undefined;
  }
  function callSync(path, args) {
    const xhr = new (window.__zaloNativeXHR || XMLHttpRequest)();
    xhr.open('POST', 'zalo-app://local/__olaz/bridge-sync', false);
    xhr.send(JSON.stringify({ path, args: encode(args) }));
    const res = JSON.parse(xhr.responseText || '{}');
    if (res.error) throw toError(res.error);
    return decode(res.value);
  }
  function subscribe(path, args) {
    const cb = args.find((a) => typeof a === 'function');
    if (!cb) return undefined;
    if (!listeners.has(path)) { listeners.set(path, new Set()); post({ kind: 'subscribe', path }); }
    listeners.get(path).add(cb);
    cb.__zid = cb.__zid || nextListener++;
    return () => listeners.get(path) && listeners.get(path).delete(cb);
  }
  function unsubscribe(path, args) {
    // removeListenX(cb) pairs with onX(cb); without a callback, drop all.
    const target = path.replace(/\.(removeListen|removeListener|off)([A-Z])/, (m, p, c) => '.on' + c);
    const set = listeners.get(target); if (!set) return;
    const cb = args.find((a) => typeof a === 'function');
    if (cb) set.delete(cb); else set.clear();
  }

  // ---- Electron IPC emulation (table-driven preload members) ----
  // The official preload maps {apiKey, type} entries to ipcRenderer calls
  // (module DmP7). Swift plays the main process (`ZaloBridge` channel handlers).
  const ipcListeners = new Map(); // channel -> Set(cb(event, ...args))
  let nextV2Key = 0;
  const ipcHandlers = new Map();  // channel -> handler(event, ...args) (PROVIDE)
  const ipcEvent = () => ({ sender: null, ports: [], returnValue: undefined });
  const ipc = {
    invoke: (channel, args) => post({ kind: 'invoke', channel, args: encode(args) }).then(decode, (e) => { throw toError(e); }),
    send: (channel, args) => { post({ kind: 'send', channel, args: encode(args) }); },
    sendSync(channel, args) {
      const xhr = new (window.__zaloNativeXHR || XMLHttpRequest)();
      xhr.open('POST', 'zalo-app://local/__olaz/bridge-sync', false);
      xhr.send(JSON.stringify({ channel, args: encode(args) }));
      const res = JSON.parse(xhr.responseText || '{}');
      if (res.error) throw toError(res.error);
      return decode(res.value);
    },
    on(channel, cb, once) {
      if (typeof cb !== 'function') return;
      if (!ipcListeners.has(channel)) { ipcListeners.set(channel, new Set()); post({ kind: 'subscribe', channel }); }
      const wrapped = once ? (...a) => { ipcListeners.get(channel).delete(wrapped); cb(...a); } : cb;
      ipcListeners.get(channel).add(wrapped);
    },
    removeAll(channel) { ipcListeners.delete(channel); },
  };
  function ipcMember(path, entry) {
    const { channel, type } = entry;
    switch (type) {
      case 'NOTIFY': case 'REQUEST': return (...a) => ipc.invoke(channel, a);
      case 'REQUEST_SYNC': return (...a) => ipc.sendSync(channel, a);
      case 'RAW_SEND': return (...a) => ipc.send(channel, a);
      case 'SUBSCRIBE': return (cb) => ipc.on(channel, cb);
      case 'SUBSCRIBE_ONCE': return (cb) => ipc.on(channel, cb, true);
      // The official preload hands V2 subscribers a key and posts the event's MessagePorts to the page under that key
      // (`window.postMessage({zChannelId:'__Z_I2M__', apiKey, key}, 'file://', ports)`); `ipcEmitPorts` does both.
      case 'SUBSCRIBE_V2': return (cb) => ipc.on(channel, (event, ...a) => cb(event.v2Key || 0, event, ...a));
      case 'UNSUBSCRIBE': return () => ipc.removeAll(channel);
      case 'PROVIDE': return (handler) => { ipcHandlers.set(channel, handler); post({ kind: 'provide', channel }); };
      case 'STOP_PROVIDE': return () => { ipcHandlers.delete(channel); };
      default: return (...a) => ipc.invoke(channel, a);
    }
  }

  function member(path) {
    if (spec.ipc && spec.ipc[path]) return ipcMember(path, spec.ipc[path]);
    const mode = spec.members[path];
    if (mode === 'value') return decode(spec.values[path]);
    const name = path.slice(path.lastIndexOf('.') + 1);
    const fn = (...args) => {
      switch (mode) {
        case 'async': return callAsync(path, args);
        case 'sync': return callSync(path, args);
        case 'event': return subscribe(path, args);
        case 'off': return unsubscribe(path, args);
        case 'noop': return undefined;
        case 'noop-async': return Promise.resolve(undefined);
        default:
          if (/^(on|once)[A-Z]/.test(name)) return subscribe(path, args);
          if (/^remove(Listen|Listener)/.test(name)) return unsubscribe(path, args);
          log('[bridge:missing]', path, JSON.stringify(encode(args.filter((a) => typeof a !== 'function'))).slice(0, 200));
          // Most preload members wrap ipcRenderer.invoke (→ Promise); *Sync members return plain values.
          if (/Sync$/.test(name)) return undefined;
          { const cb = args.find((a) => typeof a === 'function'); if (cb) setTimeout(() => cb(null)); }
          return Promise.resolve(undefined);
      }
    };
    return fn;
  }

  // Every bridge path is a hybrid: callable (a preload function) and indexable
  // (nested preload objects such as $znode.nativelibs.fileUtilities()).
  const resolved = new Map();
  function resolve(full) {
    if (resolved.has(full)) return resolved.get(full);
    let v;
    if (spec.members[full] === 'value') v = member(full);
    else if (window.__zaloLocal && window.__zaloLocal[full] !== undefined) v = window.__zaloLocal[full];
    else v = hybrid(full);
    resolved.set(full, v);
    return v;
  }
  function hybrid(path) {
    const fn = member(path);
    const children = () => Array.from(new Set(Object.keys(spec.members).filter((k) => k.startsWith(path + '.')).map((k) => k.slice(path.length + 1).split('.')[0])));
    return new Proxy(fn, {
      get(target, prop) {
        if (typeof prop === 'symbol') return target[prop];
        if (prop === 'then' || prop === 'toJSON' || prop === 'prototype') return undefined;
        if (prop === 'bind' || prop === 'call' || prop === 'apply') return Function.prototype[prop].bind(target);
        return resolve(path + '.' + prop);
      },
      has() { return true; },
      ownKeys() { return [...children(), 'length', 'name', 'prototype'].filter((k, i, a) => a.indexOf(k) === i); },
      getOwnPropertyDescriptor(target, prop) {
        if (prop === 'prototype' || prop === 'length' || prop === 'name') return Reflect.getOwnPropertyDescriptor(target, prop);
        return { enumerable: true, configurable: true, value: resolve(path + '.' + String(prop)) };
      }
    });
  }
  const namespace = hybrid;

  for (const g of spec.globals) {
    if (window.__zaloLocal && window.__zaloLocal[g] !== undefined) window[g] = window.__zaloLocal[g];
    else window[g] = namespace(g);
  }

  window.__zaloBridge = {
    // Main → renderer: webContents.send(channel, ...args)
    ipcEmit(channel, args) {
      const set = ipcListeners.get(channel); if (!set) return 0;
      const decoded = decode(args || []);
      for (const cb of Array.from(set)) { try { cb(ipcEvent(), ...decoded); } catch (e) { setTimeout(() => { throw e; }); } }
      return set.size;
    },
    // Main → renderer: webContents.postMessage(channel, message, ports) — a V2 subscription event carrying MessagePorts.
    // `args` are plain JS values (no bridge encoding): the caller is a host script in the same page.
    ipcEmitPorts(channel, args, ports) {
      const set = ipcListeners.get(channel); if (!set) return 0;
      const key = ++nextV2Key;
      // The official `$zsub` wrapper (renderer) pairs the ports it receives in a window message with the event of the
      // same key; it only accepts the message from this window and the Electron file:// origin.
      const data = { zChannelId: '__Z_I2M__', apiKey: channel, key };
      try { window.dispatchEvent(new MessageEvent('message', { data, origin: 'file://', source: window, ports: ports || [] })); }
      catch (e) { log('[bridge] port message failed', String(e)); }
      const event = Object.assign(ipcEvent(), { ports: ports || [], v2Key: key });
      for (const cb of Array.from(set)) { try { cb(event, ...(args || [])); } catch (e) { setTimeout(() => { throw e; }); } }
      return set.size;
    },
    // Whether the page listens on an IPC channel (host scripts emulating main-process pushes).
    ipcHasListener(channel) { const set = ipcListeners.get(channel); return !!set && set.size > 0; },
    // Main → renderer request: webContents.invoke(channel, ...args) answered by a PROVIDE handler.
    async ipcInvokeRenderer(channel, args) {
      const handler = ipcHandlers.get(channel);
      if (!handler) throw new Error('No handler registered for ' + channel);
      return encode(await handler(ipcEvent(), ...decode(args || [])));
    },
    // Swift → JS events for path-keyed (non-IPC) members.
    emit(path, args) {
      const set = listeners.get(path); if (!set) return 0;
      const decoded = decode(args || []);
      for (const cb of Array.from(set)) { try { cb({ sender: null }, ...decoded); } catch (e) { setTimeout(() => { throw e; }); } }
      return set.size;
    },
    emitRaw(path, args) {
      const set = listeners.get(path); if (!set) return 0;
      const decoded = decode(args || []);
      for (const cb of Array.from(set)) { try { cb(...decoded); } catch (e) { setTimeout(() => { throw e; }); } }
      return set.size;
    },
    callAsync, callSync
  };
})();
