// Olaz host script — bridge members that are pure JavaScript in Node/Electron
// and need no Swift round trip. Exposed through `window.__zaloLocal`, which
// bridge.js consults before falling back to Swift.
(() => {
  'use strict';
  if (window.__zaloLocal) return;

  // ---- Node's `path` (POSIX flavour, as on macOS) ----
  const normalizeArray = (parts, allowAboveRoot) => {
    const out = [];
    for (const p of parts) {
      if (!p || p === '.') continue;
      if (p === '..') { if (out.length && out[out.length - 1] !== '..') out.pop(); else if (allowAboveRoot) out.push('..'); }
      else out.push(p);
    }
    return out;
  };
  const path = {
    sep: '/', delimiter: ':',
    isAbsolute: (p) => String(p).startsWith('/'),
    normalize(p) {
      p = String(p); if (!p) return '.';
      const abs = p.startsWith('/'), trailing = p.endsWith('/');
      let r = normalizeArray(p.split('/'), !abs).join('/');
      if (!r && !abs) r = '.';
      if (r && trailing) r += '/';
      return (abs ? '/' : '') + r;
    },
    join(...parts) { const j = parts.filter((x) => typeof x === 'string' && x).join('/'); return j ? path.normalize(j) : '.'; },
    resolve(...parts) {
      let resolved = '', abs = false;
      for (let i = parts.length - 1; i >= -1 && !abs; i--) {
        const p = i >= 0 ? String(parts[i]) : (window.__zaloCwd || '/');
        if (!p) continue;
        resolved = p + '/' + resolved; abs = p.startsWith('/');
      }
      resolved = normalizeArray(resolved.split('/'), !abs).join('/');
      return ((abs ? '/' : '') + resolved) || '.';
    },
    dirname(p) {
      p = String(p); if (!p) return '.';
      const trimmed = p.replace(/\/+$/, '') || '/';
      const i = trimmed.lastIndexOf('/');
      if (i === -1) return '.'; if (i === 0) return '/';
      return trimmed.slice(0, i);
    },
    basename(p, ext) {
      let b = String(p).replace(/\/+$/, ''); b = b.slice(b.lastIndexOf('/') + 1);
      if (ext && b.endsWith(ext) && b !== ext) b = b.slice(0, -ext.length);
      return b;
    },
    extname(p) { const b = path.basename(p); const i = b.lastIndexOf('.'); return i <= 0 ? '' : b.slice(i); },
    relative(from, to) {
      const f = path.resolve(from).split('/').filter(Boolean), t = path.resolve(to).split('/').filter(Boolean);
      let i = 0; while (i < f.length && i < t.length && f[i] === t[i]) i++;
      return [...Array(f.length - i).fill('..'), ...t.slice(i)].join('/');
    },
    parse(p) {
      const root = String(p).startsWith('/') ? '/' : '', base = path.basename(p), ext = path.extname(p);
      return { root, dir: path.dirname(p), base, ext, name: ext ? base.slice(0, -ext.length) : base };
    },
    format(o) { const dir = o.dir || o.root || ''; const base = o.base || ((o.name || '') + (o.ext || '')); return dir ? (dir === o.root ? dir + base : dir + '/' + base) : base; },
    toNamespacedPath: (p) => p,
  };
  path.posix = path;

  // ---- electron-store (sync JSON file at <userData>/<name>.json) ----
  // Mirrors the preload's `$zelectron.getElectronStore(opts)`: one cached
  // instance per name, dot-path keys, synchronous reads and writes.
  const sync = (p, args) => window.__zaloBridge.callSync(p, args);
  const getPathValue = (obj, key) => String(key).split('.').reduce((o, k) => (o == null ? undefined : o[k]), obj);
  const setPathValue = (obj, key, value) => {
    const parts = String(key).split('.'); let o = obj;
    for (const k of parts.slice(0, -1)) { if (o[k] == null || typeof o[k] !== 'object') o[k] = {}; o = o[k]; }
    o[parts[parts.length - 1]] = value;
  };
  const deletePathValue = (obj, key) => {
    const parts = String(key).split('.'); let o = obj;
    for (const k of parts.slice(0, -1)) { if (o == null) return; o = o[k]; }
    if (o) delete o[parts[parts.length - 1]];
  };
  const stores = new Map();
  function createStore(opts) {
    const name = (opts && opts.name) || 'config';
    let data = Object.assign({}, (opts && opts.defaults) || {}, sync('$zelectron.storeRead', [name]) || {});
    const listeners = new Set();
    const persist = (old) => { sync('$zelectron.storeWrite', [name, data]); for (const l of listeners) { try { l(data, old); } catch {} } };
    const clone = (v) => (v === undefined ? undefined : JSON.parse(JSON.stringify(v)));
    return {
      get(key, def) { if (key === undefined) return clone(data); const v = getPathValue(data, key); return v === undefined ? def : clone(v); },
      set(key, value) {
        const old = clone(data);
        if (key && typeof key === 'object') for (const [k, v] of Object.entries(key)) setPathValue(data, k, v);
        else setPathValue(data, key, value);
        persist(old);
      },
      has(key) { return getPathValue(data, key) !== undefined; },
      delete(key) { const old = clone(data); deletePathValue(data, key); persist(old); },
      clear() { const old = clone(data); data = {}; persist(old); },
      reset(...keys) { const old = clone(data); for (const k of keys) setPathValue(data, k, getPathValue((opts && opts.defaults) || {}, k)); persist(old); },
      get store() { return clone(data); },
      set store(v) { const old = clone(data); data = Object.assign({}, v); persist(old); },
      get size() { return Object.keys(data).length; },
      get path() { return sync('$zelectron.storePath', [name]); },
      onDidChange(key, cb) { const l = (n, o) => { const a = getPathValue(n, key), b = getPathValue(o, key); if (JSON.stringify(a) !== JSON.stringify(b)) cb(a, b); }; listeners.add(l); return () => listeners.delete(l); },
      onDidAnyChange(cb) { listeners.add(cb); return () => listeners.delete(cb); },
      openInEditor() {},
    };
  }
  const getElectronStore = (opts) => {
    const name = (opts && opts.name) || 'default';
    if (!stores.has(name)) stores.set(name, createStore(opts));
    return stores.get(name);
  };

  // ---- Node's `url` (file URL helpers the official image/file components use) ----
  // `pathToFileURL` returns a WHATWG URL like Node's; only %, \\, newline, CR, tab, ? and # are escaped
  // by hand, the URL parser encodes the rest.
  const nodeUrl = {
    pathToFileURL(p) {
      const abs = path.resolve(String(p));
      const escaped = abs.replace(/%/g, '%25').replace(/\\/g, '%5C').replace(/\n/g, '%0A').replace(/\r/g, '%0D')
        .replace(/\t/g, '%09').replace(/\?/g, '%3F').replace(/#/g, '%23');
      return new URL('file://' + escaped);
    },
    fileURLToPath(u) {
      const url = typeof u === 'string' ? new URL(u) : u;
      if (!url || url.protocol !== 'file:') throw new TypeError('The URL must be of scheme file');
      return decodeURIComponent(url.pathname);
    },
  };

  // ---- Node's `os` — values supplied by Swift in the bridge spec ----
  const info = (window.__zaloBridgeSpec && window.__zaloBridgeSpec.values['$znode.os.__info']) || {};
  const os = {
    EOL: '\n',
    platform: () => 'darwin', type: () => 'Darwin', arch: () => info.arch || 'arm64',
    release: () => info.release || '', version: () => info.version || '', hostname: () => info.hostname || 'Mac',
    homedir: () => info.homedir || '/', tmpdir: () => info.tmpdir || '/tmp', endianness: () => 'LE',
    totalmem: () => info.totalmem || 0, freemem: () => info.freemem || 0, uptime: () => info.uptime || 0,
    cpus: () => Array.from({ length: info.cpus || 1 }, () => ({ model: info.cpuModel || 'Apple', speed: 0, times: { user: 0, nice: 0, sys: 0, idle: 0, irq: 0 } })),
    loadavg: () => [0, 0, 0],
    // [name, [addresses…]] pairs (getifaddrs order) → Node's { en0: […] } shape; a fresh object
    // per call, like Node's. The official QoS code takes the first non-internal IPv4 as local IP.
    networkInterfaces: () => {
      const out = {};
      for (const [name, addrs] of (info.networkInterfaces ? JSON.parse(info.networkInterfaces) : [])) out[name] = addrs;
      return out;
    },
    userInfo: () => ({ username: info.username || '', homedir: info.homedir || '/', shell: '/bin/zsh', uid: 501, gid: 20 }),
  };

  // ---- webFrame/process stats the preload read synchronously ----
  const usage = () => { const z = { count: 0, size: 0, liveSize: 0 }; return { images: z, scripts: z, cssStyleSheets: z, xslStyleSheets: z, fonts: z, other: z }; };

  // ---- Node crypto stateful objects (state lives in Swift, CryptoBridge.swift) ----
  const cipher = (kind, alg, key, iv) => {
    const h = sync('$znode.crypto.__cipherCreate', [kind, alg, key, iv]);
    const obj = {
      update: (data, inEnc, outEnc) => sync('$znode.crypto.__cipherUpdate', [h, data, inEnc, outEnc]),
      final: (outEnc) => sync('$znode.crypto.__cipherFinal', [h, outEnc]),
      setAutoPadding: (on = true) => { sync('$znode.crypto.__cipherOption', [h, 'autoPadding', on]); return obj; },
      setAuthTag: (tag) => { sync('$znode.crypto.__cipherOption', [h, 'authTag', tag]); return obj; },
      setAAD: (aad) => { sync('$znode.crypto.__cipherOption', [h, 'aad', aad]); return obj; },
      getAuthTag: () => sync('$znode.crypto.__cipherOption', [h, 'getAuthTag']),
    };
    return obj;
  };
  const createHash = (alg) => {
    const h = sync('$znode.crypto.__hashCreate', [alg]);
    const obj = { update: (data, enc) => { sync('$znode.crypto.__hashUpdate', [h, data, enc]); return obj; }, digest: (enc) => sync('$znode.crypto.__hashDigest', [h, enc]) };
    return obj;
  };

  // ---- $zFeatures.fileRes (preload module Hz92) ----
  // createKeepDelDb: bounded list of resource records persisted as JSON in the
  // Zalo data dir (`config.db_name` with `$0$` → userId), saved every `trans_batch` ops.
  let keepDel = null;
  const createKeepDelDb = (initialConfig) => {
    if (!keepDel) {
      keepDel = {
        config: initialConfig || {}, data: null, pending: [], trans: 0,
        get storeName() { return 'keepdel-' + String(this.config.db_name || 'db').replace('$0$', this.config.userId || '') .replace(/[^\w.-]/g, '_'); },
        load() { if (!this.data) { const s = sync('$zelectron.storeRead', [this.storeName]) || {}; this.data = Array.isArray(s.items) ? s.items : []; } },
        save(force) {
          if (!this.data) return;
          const limit = this.config.keep_limit || 5000, batch = this.config.trans_batch || 1;
          if (!force && this.trans < batch) return;
          this.trans = 0;
          if (this.data.length > limit) this.data.splice(0, this.data.length - limit);
          sync('$zelectron.storeWrite', [this.storeName, { items: this.data }]);
        },
        add(item, front) {
          if (!item) return;
          this.trans++;
          if (!this.data) { this.pending.push(item); return; }
          for (const it of [...this.pending.splice(0), item]) { const json = JSON.stringify(it); front ? this.data.unshift(json) : this.data.push(json); }
          this.save(false);
        },
      };
    }
    keepDel.config = Object.assign({}, keepDel.config, initialConfig || {});
    return {
      loadConfig: (c) => { keepDel.config = Object.assign({}, keepDel.config, c || {}); },
      setup: () => { keepDel.load(); },
      destroy: () => { keepDel.save(true); keepDel.data = null; keepDel.trans = 0; },
      uninstall: async () => { keepDel.data = []; sync('$zelectron.storeWrite', [keepDel.storeName, { items: [] }]); },
      connect: async () => { keepDel.load(); },
      unshift: (item) => keepDel.add(item, true),
      push: (item) => keepDel.add(item, false),
      pop: () => { if (!keepDel.data) return undefined; keepDel.trans++; const v = keepDel.data.pop(); keepDel.save(false); try { return v ? JSON.parse(v) : undefined; } catch { return undefined; } },
    };
  };
  // createDetachCleaner: removes a directory tree in the background.
  const createDetachCleaner = (target) => ({
    start: () => window.__zaloBridge.callAsync('$znode.fsExtra.remove', [String(target)]).then(() => 0, () => 0),
    stop: () => Promise.resolve(),
  });

  // ---- Native-module features without a native module here (spec §1.4) ----
  const unsupported = (name) => () => Promise.reject(Object.assign(new Error("Cannot find module '" + name + "'"), { code: 'MODULE_NOT_FOUND' }));

  // ---- MetriczGlobal: process stats ----
  const metrics = {
    getProcessStats: () => ({ heapUsed: 0, heapTotal: 0, rss: 0, cpu: 0 }),
    getProcessMemory: () => 0,
    startCPUMonitor: () => {}, stopCPUMonitor: () => {}, getCPUUsage: () => 0,
    onCPUChange: () => {}, removeCPUChangeListener: () => {},
    getArch: () => (info.arch === 'x64' ? 'x64' : 'arm64'),
  };

  // `$zsqlite` (preload-shared-worker only): native sqlite3 binding behind the message search
  // index and the phone-backup reader. This host has no SQLite backend (storage is forced to
  // IndexedDB), so every call fails the way a missing native lib does; the bundle only needs
  // the global to exist when its modules load.
  const noSqlite = (what) => Promise.reject(Object.assign(new Error('SQLite is not available (' + what + ')'), { code: 'ENOTSUP' }));
  const sqliteMethods = ['openDb', 'query', 'queryV2', 'queryGlobalMessage', 'queryGlobalMessageV2', 'queryGlobalMessageV3', 'queryGlobalMessageV4',
    'deleteRow', 'deleteRows', 'write', 'writev2', 'pureQuery', 'prepareInsertSearch', 'prepareDeleteSearch', 'getConversationMatch', 'flushDb',
    'flushDbBatchv2', 'flushDbBatch', 'closeDb', 'finalizeInsertStatement', 'finalizeDeleteStatement', 'doListSqls', 'createKey', 'initDebug', 'countTotal'];
  const sqliteConnection = () => new Proxy({}, { get: (_c, m) => (typeof m === 'string' && /^(open|close|run|get|each|all|exec|prepare)/.test(m)) ? () => noSqlite(m) : undefined });
  const sqliteStub = {
    isLoadedLib: () => false,
    isDbTransactionStepError: () => false,
    createConnection: sqliteConnection,
  };
  for (const m of sqliteMethods) sqliteStub[m] = () => noSqlite(m);

  window.__zaloLocal = {
    '$zsqlite': sqliteStub,
    'MetriczGlobal': metrics,
    '$zpreload.triggerWindowLoadedEvent': () => undefined,
    '$zcommon.send': () => undefined,
    '$zcommon.receive': () => undefined,
    '$zcommon.remove': () => undefined,
    '$zelectronNative.lockWebframeZoom': () => undefined,
    '$zelectronNative.setZoomFactor': () => undefined,
    '$zelectronNative.getClipboardText': () => sync('$zelectronNative.clipboardText', []) || '',
    '$zelectronNative.writeTextToClipboard': (text) => { sync('$zelectronNative.clipboardWriteText', [String(text == null ? '' : text)]); },
    '$zelectronNative.availableClipboardFormats': () => sync('$zelectronNative.clipboardFormats', []) || [],
    '$zelectronNative.readClipboard': () => '',
    '$zelectronNative.getClipboardImage': () => ({ isEmpty: () => true, toJPEG: () => new Uint8Array(0), toPNG: () => new Uint8Array(0) }),
    '$zFeatures.libvips.resizeImage': unsupported('libvips'),
    '$zFeatures.libjxl.decodeToJpeg': unsupported('libjxl'),
    '$zFeatures.libjxl.encodeJxl': unsupported('libjxl'),
    '$zFeatures.libjxl.getJxlInfo': unsupported('libjxl'),
    '$zFeatures.libjxl.jxlDecompressMulti': unsupported('libjxl'),
    '$zFeatures.libjxl.moduleReady': () => Promise.resolve(false),
    '$zFeatures.fileRes.createKeepDelDb': createKeepDelDb,
    '$zFeatures.fileRes.createDetachCleaner': createDetachCleaner,
    '$znode.crypto.createCipheriv': (alg, key, iv) => cipher('cipher', alg, key, iv),
    '$znode.crypto.createDecipheriv': (alg, key, iv) => cipher('decipher', alg, key, iv),
    '$znode.crypto.createHash': createHash,
    '$znode.path': path,
    '$znode.url': nodeUrl,
    '$znode.os': os,
    '$zelectron.getElectronStore': getElectronStore,
    '$zelectronNative.getResourceUsage': usage,
    '$zelectronNative.clearCache': () => {},
    '$zelectronNative.getAvailableHeapSize': () => 4 * 1024 * 1024 * 1024,
    // Native .node addons: synchronous factories returning addon objects whose
    // methods are implemented in Swift under $znode.nativelibs.<addon>.*
    '$znode.nativelibs.fileUtilities': () => window.$znode.nativelibs.fileUtilitiesAddon,
    '$znode.nativelibs.fileUtils': () => window.$znode.nativelibs.fileUtilsAddon,
    '$znode.nativelibs.dbUtils': () => window.$znode.nativelibs.dbUtilsAddon,
    '$znode.nativelibs.zcall': () => window.$znode.nativelibs.zcallAddon,
  };
})();
