// Olaz host script — reports the official renderer's state to Swift so the
// native SwiftUI interface can render it. The renderer's own DOM stays hidden.
//
// login.html: the QR login component (`.login-qr-page`) — QR image, scan state,
// scanned account preview, errors. Posts {page:'login', ...} via `zstate`.
(() => {
  'use strict';
  if (window.__zaloStateAdapter) return;
  window.__zaloStateAdapter = true;
  const post = (state) => { try { window.webkit.messageHandlers.zstate.postMessage(state); } catch {} };
  const diag = (s) => { try { window.webkit.messageHandlers.zlog.postMessage('[adapter] ' + s); } catch {} };
  const page = location.pathname.split('/').pop();

  // ---- webpack access: lets Swift observe official services directly ----
  // Pushing a probe chunk onto `webpackJsonp` (webpack 4 JSONP runtime) yields
  // `__webpack_require__`, whose module cache holds every loaded service.
  const withRequire = (cb) => {
    const tryCapture = () => {
      if (window.__zaloRequire) return cb(window.__zaloRequire);
      const jsonp = window.webpackJsonp;
      if (!jsonp || jsonp.push === Array.prototype.push) return false; // runtime not booted yet
      const id = '__olaz_probe_' + Date.now();
      jsonp.push([[id], { [id]: (m, e, r) => { window.__zaloRequire = r; } }, [[id]]]);
      return window.__zaloRequire ? cb(window.__zaloRequire) : false;
    };
    if (tryCapture() === false) { const t = setInterval(() => { if (tryCapture() !== false) clearInterval(t); }, 200); }
  };
  // Calls `visit(exportValue, moduleId)` for every loaded module export.
  const eachExport = (req, visit) => {
    for (const [id, mod] of Object.entries(req.c || {})) {
      const ex = mod && mod.exports;
      if (!ex) continue;
      visit(ex, id);
      if (typeof ex === 'object') for (const k of Object.keys(ex)) { try { if (ex[k]) visit(ex[k], id); } catch {} }
    }
  };
  // Every registration in the official tsyringe container(s): {provider, options, instance}.
  const diRegistrations = (req) => {
    const out = [];
    const seen = new Set();
    eachExport(req, (ex) => {
      if (!ex || typeof ex !== 'object' || seen.has(ex)) return;
      const registry = ex._registry && ex._registry._registryMap;
      if (typeof ex.resolve !== 'function' || !(registry instanceof Map)) return;
      seen.add(ex);
      for (const regs of registry.values()) for (const r of regs || []) out.push(r);
    });
    return out;
  };
  window.__zaloDI = diRegistrations;

  // The official "UI-Crash" error boundary logs only to the encrypted zlog;
  // surface render crashes in the host log as well.
  withRequire((req) => {
    const patchBoundaries = () => {
      let n = 0;
      eachExport(req, (ex) => {
        if (typeof ex !== 'function' || typeof ex.getDerivedStateFromError !== 'function') return;
        const proto = ex.prototype;
        if (!proto || typeof proto.componentDidCatch !== 'function' || proto.componentDidCatch.__olaz) return;
        const original = proto.componentDidCatch;
        proto.componentDidCatch = function (error, info) {
          diag('UI-CRASH ' + (error && error.name) + ': ' + (error && error.message) + ' | ' + String(error && error.stack || '').split('\n').slice(0, 6).join(' < ') + ' | component: ' + String(info && info.componentStack || '').split('\n').slice(0, 8).join(' < '));
          return original.call(this, error, info);
        };
        proto.componentDidCatch.__olaz = true;
        n++;
      });
      return n;
    };
    patchBoundaries();
    const t = setInterval(patchBoundaries, 400);
    setTimeout(() => clearInterval(t), 20000);
    return true;
  });
  window.__zaloWithRequire = withRequire;
  window.__zaloEachExport = eachExport;

  if (page === 'index.html') {
    // Storage: Zalo PC 26.10 migrates new sessions from IndexedDB to its native
    // SQLite host. This host has no SQLite backend yet, so it takes the official
    // "migration disabled by server config" branch and stays on IndexedDB.
    withRequire((req) => {
      const patch = () => {
        let done = false;
        for (const reg of diRegistrations(req)) {
          for (const c of [reg.instance, reg.provider && reg.provider.useClass, reg.provider]) {
            const proto = typeof c === 'function' ? c.prototype : c && typeof c === 'object' ? Object.getPrototypeOf(c) : null;
            if (!proto || typeof proto.waitForDBMigrate !== 'function' || proto.waitForDBMigrate.__olaz) continue;
            const original = proto.waitForDBMigrate;
            proto.waitForDBMigrate = function (session, config, diskConfig) {
              diag('db: migration to SQLite disabled (no SQLite backend in host)');
              return original.call(this, session, Object.assign({}, config || {}, { enable: false }), diskConfig);
            };
            proto.waitForDBMigrate.__olaz = true;
            done = true;
          }
        }
        return done;
      };
      if (!patch()) { const t = setInterval(() => { if (patch()) clearInterval(t); }, 100); setTimeout(() => clearInterval(t), 60000); }
      return true;
    });

    // The official Redux store (slices: user, status, conversations, chatview…).
    withRequire((req) => {
      const findStore = () => {
        let store = null;
        eachExport(req, (ex) => {
          if (!store && ex && typeof ex === 'object' && typeof ex.getState === 'function' &&
              typeof ex.dispatch === 'function' && typeof ex.subscribe === 'function') {
            try { const st = ex.getState(); if (st && st.user && st.conversations) store = ex; } catch {}
          }
        });
        return store;
      };
      const attach = (store) => {
        window.__zaloStore = store;
        let lastUser = '';
        const publish = () => {
          const st = store.getState();
          const u = st.user || {};
          const user = { userId: u.userId || '', displayName: u.displayName || '', zaloName: u.zaloName || '', avatar: u.avatar || '', phoneNumber: u.phoneNumber || '' };
          const key = JSON.stringify(user);
          if (key !== lastUser) { lastUser = key; post({ page: 'main', user }); }
        };
        store.subscribe(publish);
        publish();
        diag('redux store attached');
      };
      const tryAttach = () => { const s = findStore(); if (s) { attach(s); startConversations(); return true; } return false; };

      // Conversation list from the official services: conv-info-manager (index),
      // friend/group modules (names, avatars), unread-manager, preview-manager.
      let convTimer = null;
      const startConversations = () => {
        if (convTimer) return;
        const regs = () => diRegistrations(req);
        const pick = (pred) => { for (const r of regs()) { const i = r.instance; if (i && typeof i === 'object') { try { if (pred(i)) return i; } catch {} } } return null; };
        let modules = null, requestedProfiles = new Set();
        const loadModules = async () => {
          const io = pick((i) => typeof i.getFriendManagerModule === 'function');
          if (!io) return null;
          const f = await io.getFriendManagerModule(), g = await io.getGroupManagerModule();
          return {
            friends: f.default || f, groups: g.default || g,
            convs: pick((i) => typeof i.getConvByIdSync === 'function' && typeof i.addOrUpdateConv === 'function'),
            unread: pick((i) => typeof i.getUnreadByConvIdSync === 'function'),
            preview: pick((i) => typeof i.convertDBMessageToPreviewItem === 'function'),
          };
        };
        const safe = (fn, d) => { try { const v = fn(); return v === undefined ? d : v; } catch { return d; } };
        // Official preview formatter: module exporting `a(previewItem, opts) -> {icon, message,
        // isSystemicMessage, systemicMessageArgs}` (the helper the conversation-list item calls; it
        // switches on messageType with STR_*_NO_BRACKET strings). Found by source signature (cached);
        // the language module (`str`/`trans`) localizes the result.
        let fmt = null, fmtTries = 0, fmtNextAt = 0, fmtLooked = false;
        // At most one lookup per publish tick (`beginTick`), retried every 30 s up to 10 times;
        // each module check is isolated so a throwing getter/factory can't abort the scan.
        const beginTick = () => { fmtLooked = false; };
        const findFormatter = () => {
          if (fmt || fmtLooked || fmtTries >= 10 || Date.now() < fmtNextAt) return fmt;
          fmtLooked = true; fmtTries++; fmtNextAt = Date.now() + 30000;
          const SIG = 'STR_VIDEO_MSG_NO_BRACKET';
          const isFmt = (f) => { try { return typeof f === 'function' && String(f).includes(SIG) && String(f).includes('computedMessage'); } catch { return false; } };
          let fn = null;
          try {
            for (const id of Object.keys(req.c || {})) {
              try { const ex = req.c[id] && req.c[id].exports; if (ex && typeof ex === 'object' && isFmt(ex.a)) { fn = ex.a; break; } } catch {}
            }
            if (!fn) {
              const mods = req.m || {};
              for (const id of Object.keys(mods)) {
                try {
                  const factory = mods[id];
                  // Cheap gate first: the formatter module is a large function with a fixed import shape.
                  if (typeof factory !== 'function' || factory.length < 3) continue;
                  const src = String(factory);
                  if (!src.includes(SIG) || !src.includes('STR_STICKERSET_MSG_NO_BRACKET') || !src.includes('computedMessage')) continue;
                  const ex = req(id);
                  if (ex && isFmt(ex.a)) { fn = ex.a; break; }
                } catch {}
              }
            }
          } catch (e) { diag('preview formatter lookup failed: ' + e); }
          if (!fn) return null;
          let lang = null;
          try {
            eachExport(req, (ex) => {
              try { if (!lang && ex && typeof ex === 'object' && ex.default && typeof ex.default.str === 'function' && typeof ex.default.trans === 'function' && typeof ex.default.currentLanguage === 'function') lang = ex.default; } catch {}
            });
          } catch {}
          fmt = { fn, lang };
          diag('preview formatter found');
          return fmt;
        };
        const LABEL_KEYS = ['STR_STICKER_NO_BRACKET', 'STR_FILE_PHOTO', 'STR_CONTACT_MSG_NO_BRACKET', 'STR_GIF_NO_BRACKET', 'STR_VIDEO_MSG_NO_BRACKET', 'STR_VOICE_MSG_NO_BRACKET', 'STR_DOODLE_MSG_NO_BRACKET', 'STR_POLL_MSG_NO_BRACKET', 'STR_STICKERSET_MSG_NO_BRACKET', 'STR_CARD_MSG_NO_BRACKET', 'STR_REMINDER_NO_BRACKET'];
        // Defensive fallback when the official helper is unavailable or throws.
        const LABEL_BY_TYPE = { 2: '[Hình ảnh]', 3: '[Tin nhắn thoại]', 4: '[Sticker]', 5: '[Hình vẽ]', 6: '[Danh thiếp]', 7: '[GIF]', 11: '[Hình ảnh]', 13: '[Sticker]', 17: '[Vị trí]', 18: '[Video]', 19: '[Tệp]', 21: '[Tin nhắn]', 25: '[Thiệp]', 26: '[Bình chọn]' };
        const textOf = (c) => {
          if (typeof c === 'string') return c;
          if (Array.isArray(c)) { for (const x of c) { const t = x && (x.title || x.description || x.text); if (t && typeof t === 'string') return t; } return ''; }
          const v = c && (c.title || c.description || c.text || c.msg || c.message);
          return typeof v === 'string' ? v : '';
        };
        const isKey = (s) => /^STR_[A-Z0-9_]+$/.test(s);
        const previewText = (p) => {
          const f = findFormatter();
          if (f) {
            try {
              const r = f.fn(p, {});
              let msg = r && typeof r.message === 'string' ? r.message : '';
              if (msg && f.lang) {
                if (isKey(msg)) msg = r.systemicMessageArgs ? f.lang.trans(msg, r.systemicMessageArgs) : f.lang.str(msg);
                // Bracket pure type labels only: the item has a type icon, is not text, and the result
                // is exactly a label string (so a real text message "Video" is left alone).
                else if (r.icon && Number(p.messageType) !== 1 && !msg.startsWith('[') && LABEL_KEYS.some((k) => { try { return f.lang.str(k) === msg; } catch { return false; } })) msg = '[' + msg + ']';
              }
              if (msg && !isKey(msg)) return msg;
            } catch (e) { /* fall through to the defensive mapping */ }
          }
          return textOf(p.computedMessage) || textOf(p.message) || textOf(p.content) || LABEL_BY_TYPE[Number(p.messageType)] || '';
        };
        // Preview text per preview item: the official formatter (plus the language lookups) runs for every conversation of the
        // index on every tick otherwise, and a large account has thousands. The memo is keyed by the item object and checked
        // against the fields a new message changes (time, ids, message / computedMessage identity, type); it is dropped as a
        // whole every PREVIEW_MEMO_MS so names that resolve later still reach the text.
        const PREVIEW_MEMO_MS = 20000;
        let previewMemo = new WeakMap(), previewMemoBorn = 0;
        const previewStamp = (p) => [p.messageTime, p.sendDttm, p.ts, p.msgId, p.cliMsgId, p.messageType, p.msgType].map((v) => (v === undefined || v === null ? '' : String(v))).join('|');
        const previewOf = (m, id) => {
          const p = safe(() => m.preview.data.get(id), null);
          if (!p) return null;
          // Preview items (preview-manager): {message, computedMessage, messageTime, fromUid ('0' = me), messageType}.
          const now = Date.now();
          if (now - previewMemoBorn > PREVIEW_MEMO_MS) { previewMemo = new WeakMap(); previewMemoBorn = now; }
          const stamp = previewStamp(p);
          const hit = typeof p === 'object' ? previewMemo.get(p) : null;
          let text;
          if (hit && hit.stamp === stamp && hit.message === p.message && hit.computed === p.computedMessage) text = hit.text;
          else {
            text = String(safe(() => previewText(p), '') || '').slice(0, 200);
            if (typeof p === 'object') previewMemo.set(p, { stamp, message: p.message, computed: p.computedMessage, text });
          }
          return { text, ts: Number(p.messageTime || p.sendDttm || p.ts || 0), fromMe: !!p.isMe || String(p.fromUid) === '0', type: p.messageType || p.msgType || '' };
        };
        // Rows are posted as deltas: the first post carries every row with `reset: true`; later posts only the rows whose
        // JSON changed since they were last posted, plus the ids that left the index (`removed`). Swift merges by id
        // (ZaloEngine.mergeConversations), so a tick costs the bridge and the UI only what actually changed.
        const posted = new Map();          // conv id → JSON of the row as last posted
        let published = false;
        const publish = async () => {
          beginTick();
          if (!modules) { modules = await loadModules().catch(() => null); if (!modules || !modules.convs) { modules = null; return; } }
          const m = modules;
          const missing = [];
          const changed = [];
          const seen = new Set();
          for (const [id, c] of m.convs.data) {
            const isGroup = !!c.isGroup;
            const name = safe(() => (isGroup ? m.groups.getDName(id) : m.friends.getDName(id)), '');
            if (!name && !isGroup) missing.push(id);
            const u = safe(() => m.unread.getUnreadByConvIdSync(id), null);
            const row = {
              id: String(id), isGroup, name: name || '',
              avatar: safe(() => (isGroup ? m.groups.getAvatarGroup(id) : m.friends.getAvatar(id)), '') || '',
              pinned: !!c.pinned, members: isGroup ? safe(() => m.groups.getTotalMember(id), 0) : 0,
              unread: (u && (u.smsUnreadCount || 0)) || 0,
              preview: previewOf(m, id),
            };
            if (seen.has(row.id)) continue;
            seen.add(row.id);
            const key = JSON.stringify(row);
            if (posted.get(row.id) !== key) { posted.set(row.id, key); changed.push(row); }
          }
          const removed = [];
          for (const id of posted.keys()) if (!seen.has(id)) removed.push(id);
          removed.forEach((id) => posted.delete(id));
          // Unknown 1-1 names: ask the official friend module to fetch profiles once.
          const toFetch = missing.filter((id) => !requestedProfiles.has(id));
          if (toFetch.length) { toFetch.forEach((id) => requestedProfiles.add(id)); safe(() => m.friends.getProfileFriendByIds(toFetch), null); }
          if (!published || changed.length || removed.length) {
            post({ page: 'main', conversations: changed, removed, reset: !published });
            published = true;
          }
        };
        convTimer = setInterval(() => { publish().catch((e) => diag('conversations publish failed: ' + e)); }, 1500);
        publish().catch(() => {});
      };
      if (!tryAttach()) { const t = setInterval(() => { if (tryAttach()) clearInterval(t); }, 500); }
      return true;
    });
  }

  if (page === 'login.html') {
    // Wrap the trusted-device QR generators so Swift receives the exact QR the
    // official client shows (first QR, and the second "confirm" QR).
    withRequire((req) => {
      const patch = () => {
        let patched = 0;
        // The class is module-private; its module exports a singleton getter.
        const targets = new Set();
        for (const [id, factory] of Object.entries(req.m || {})) {
          if (!req.c[id] || typeof factory !== 'function' || !String(factory).includes('async genFirstQR(')) continue;
          const ex = req.c[id].exports;
          for (const v of [ex, ...Object.values(ex || {})]) {
            if (typeof v === 'function' && v.prototype && typeof v.prototype.genFirstQR === 'function') targets.add(v.prototype);
            if (typeof v === 'function' && v.length === 0) {
              try { const inst = v(); if (inst && typeof inst.genFirstQR === 'function') targets.add(Object.getPrototypeOf(inst)); } catch {}
            }
          }
        }
        eachExport(req, (ex) => {
          if (typeof ex === 'function' && ex.prototype && typeof ex.prototype.genFirstQR === 'function') targets.add(ex.prototype);
        });
        // Services are tsyringe singletons: look through the DI container registry.
        for (const reg of diRegistrations(req)) {
          for (const c of [reg.instance, reg.provider && reg.provider.useClass, reg.provider && reg.provider.useValue, reg.provider]) {
            if (!c) continue;
            if (typeof c === 'function' && c.prototype && typeof c.prototype.genFirstQR === 'function') targets.add(c.prototype);
            else if (typeof c === 'object' && typeof c.genFirstQR === 'function') targets.add(Object.getPrototypeOf(c));
          }
        }
        for (const target of targets) {
          if (!target || typeof target.genFirstQR !== 'function' || target.genFirstQR.__olaz) continue;
          // Outcome of every trusted-device step (names only — never arguments or results).
          for (const name of Object.getOwnPropertyNames(target)) {
            const fn = target[name];
            if (name === 'constructor' || typeof fn !== 'function' || fn.__olazTrace) continue;
            target[name] = function (...args) {
              let out;
              try { out = fn.apply(this, args); } catch (e) { diag('trust ' + name + ' threw: ' + (e && (e.code || '') + ' ' + (e.message || e))); throw e; }
              if (out && typeof out.then === 'function') {
                diag('trust ' + name + ' started');
                out.then(() => diag('trust ' + name + ' ok'), (e) => diag('trust ' + name + ' FAILED: ' + (e && ((e.code || '') + ' ' + (e.message || JSON.stringify(e))))));
              }
              return out;
            };
            target[name].__olazTrace = true;
          }
          for (const name of ['genFirstQR', 'genSecondQR']) {
            const original = target[name];
            if (typeof original !== 'function') continue;
            target[name] = async function (...args) {
              const qr = await original.apply(this, args);
              post({ page: 'login', event: name === 'genFirstQR' ? 'qr' : 'qr2', qr });
              return qr;
            };
            target[name].__olaz = true;
            patched++;
          }
        }
        diag('patch pass: require modules=' + Object.keys(req.c || {}).length + ' factoriesWithGenFirstQR=' + Object.entries(req.m || {}).filter(([, f]) => String(f).includes('async genFirstQR(')).map(([id]) => id + (req.c[id] ? '(loaded)' : '(not loaded)')).join(',') + ' patched=' + patched);
        return patched;
      };
      // Lazy login chunks may load after the runtime; retry until found.
      if (!patch()) { const t = setInterval(() => { if (patch()) clearInterval(t); }, 300); setTimeout(() => clearInterval(t), 30000); }
      return true;
    });
    let last = '';
    const snapshot = () => {
      const root = document.querySelector('.login-qr-page') || document.querySelector('#app-page');
      if (!root) return null;
      const imgs = Array.from(root.querySelectorAll('img')).filter((i) => i.src && i.naturalWidth >= 64);
      const qrImg = root.querySelector('.qr-image img, img.qr-image, .login-qr__frame-qr img') || imgs.find((i) => i.src.startsWith('data:image/png') || i.src.startsWith('data:image/svg'));
      const canvas = root.querySelector('.login-qr__frame-qr canvas, .qr-code canvas');
      let qr = qrImg ? qrImg.src : null;
      if (!qr && canvas) { try { qr = canvas.toDataURL('image/png'); } catch {} }
      // The official page stops polling after `qr_retry` long-polls (~21 s each, so ~1 min) and marks the QR dead by
      // renaming its <img> to `qr-image--none` (src becomes a placeholder). Older builds used the other classes.
      const invalid = !!root.querySelector('img.qr-image--none, .qr--invalid, .qr-img-err, .off--qr-code');
      if (invalid) qr = null;   // never forward the placeholder as a scannable QR
      const avatar = Array.from(root.querySelectorAll('img')).find((i) => /ava|avatar/.test(i.className + ' ' + i.src) && i !== qrImg);
      const buttons = Array.from(root.querySelectorAll('button, .z--btn--v2')).map((b) => (b.innerText || '').trim()).filter(Boolean);
      const text = (root.innerText || '').trim().replace(/\n{2,}/g, '\n').slice(0, 600);
      return { page: 'login', qr, invalid, avatar: avatar ? avatar.src : null, text, buttons };
    };
    const tick = () => {
      const s = snapshot();
      if (!s) return;
      const key = JSON.stringify([s.qr && s.qr.length, s.qr && s.qr.slice(-40), s.invalid, s.avatar, s.text]);
      if (key !== last) { last = key; post(s); }
    };
    const start = () => {
      new MutationObserver(tick).observe(document.body, { subtree: true, childList: true, attributes: true, characterData: true });
      setInterval(tick, 1500);
      tick();
    };
    if (document.body) start(); else document.addEventListener('DOMContentLoaded', start);

    // Native buttons trigger the official component's own actions.
    window.__zaloLoginAction = (label) => {
      const root = document.querySelector('.login-qr-page') || document.body;
      const target = Array.from(root.querySelectorAll('button, .z--btn--v2, a, [role=button]'))
        .find((b) => (b.innerText || '').trim().toLowerCase().includes(String(label).toLowerCase()));
      if (target) { target.click(); return true; }
      return false;
    };
  }
})();
