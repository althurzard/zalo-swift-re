// Olaz composer adapter (index.html only): the composer's "+" menu — Ảnh hoặc Video, Tệp, Chụp màn hình, Danh thiếp, Nhắc hẹn —
// through the official chat-box controller and services. Attaches to `window.__zaloChat` (chat-adapter.js `chat.__core`) and
// exposes `window.__zaloCompose`.
//
// Where the official client keeps each path (offsets in default-login-main-startup-shared-worker-znotification.*.js):
//   Ảnh          toolbar `onUploadPhotoClicked` ~4214994: `$zFileManager.getPhotoWithPaths` (open dialog filtered to `supportPhoto`) →
//                `_uploadImg({target:{files}}, conv, Photo.CLICK_ICON_SEND_PHOTO, false)` ~4212288: ≤ maxNumberOfFile, several non-gif
//                photos share one group layout (album), each `_uploadDragPhoto(isUploaded)` → `sendPhotoMessage` (photo processor, JXL)
//                → `_sendMessage(MSG_PHOTO)`. Photos the processor refuses (size / dimension / decode) end in the "Gửi dưới dạng file"
//                confirm (module "KWGo" `p`, ConfirmManagerV2) whose OK sends them as files (`_sendOverlimitPhoto`).
//   Tệp          toolbar `_onUploadFileClick` ~4240828: `$zwindow.showOpenDialog` → executables renamed "<name>.zip" with sub type EEXC
//                (`isValidFileName` / `isEnableUpEecx`) → `_uploadFile({target:{files}})` ~4210900: count limit, then one
//                `_uploadDragFile(isUploaded)` per file → `_checkValidFile` (size / type, official toast) → `_sendMessage(MSG_FILE)`.
//                Videos have no toolbar path of their own on PC: they go as files (the inline player of remote config media_files).
//   Chụp màn hình  ZaloCap (Swift ScreenCapture.swift) leaves the shot on the clipboard. "Gửi" = `onCaptureResponseAccept` ~4177897:
//                lockSendMsg check, then `_uploadDragPhoto(blob "screenshot.png", {sendSource: Photo.SEND_FROM_SCREENSHOT})`; a refused
//                photo gets the official notice (KWGo `a`) and goes as a file. "Gửi vào Cloud của tôi" = `_onCaptureResponseSend2Me`
//                ~13072300: the same into the sendToMe conversation + toast STR_SEND2ME_SHARE_SUCCESS. "Chia sẻ" = `handleForwardScreenCap`
//                ~4176820: `sendPhotoMessage(blob, {targetConv})` per chosen conversation (the official picker is native here).
//                The composer drops the shot into its preview tray; this app has none, so it is sent right away (`isUploaded`).
//   Danh thiếp   SHARE_CONTACT modal (module "y4S7" ~16126369) `onConfirm` payload, built for my own profile:
//                {message:{action:'recommened.user', params:uid, thumb, title:zaloName, description:JSON{qrCodeUrl, phone?}}, msgType:6}
//                → chat-box `_shareMessage_new([msg], [convId], onDone)` (forward module). QR from module "F1+M" `c(uids)` (gated by
//                name_card.fetch_qr_enable, resolves {} on error), phone through `getPhoneNumberPro`, the "Gửi kèm số điện thoại" default
//                from `getRememberSendWithPhoneNumber`. The official UI only lists friends; the payload is the same for me.
//   Nhắc hẹn     chat-bar "…" menu ~4752975: hidden for OA; gate `Re` ~4754377 (1:1 `enable_reminder_1_1`, My Cloud
//                `ON_FEATURE.ENABLE_SENDTOME_REMINDER`, groups `isNoticeable` else STE_ADMIN_CREATE_TOPIC). Live config `reminder.enabled`
//                = 0, so the legacy compose modal (module "xzV+" ~16087737, `onConfirm` ~16097700) is the one in use: its validation, then
//                group `createGroupTopicv2(gid, TEXT_TOPIC, #081C36, "⏰", start, -1, {title}, needPin, 0, repeat, CREATE_NOTICE_SRC_CHAT_BAR)`
//                or 1:1 / My Cloud `createOneOneGroupTopic({toUid, …, needPin:false, repeat, creatorUid, src: REMINDER_SRC_CHATBAR})`
//                (module "dThN"). Nothing is inserted locally: the server pushes the reminder card.
//
// Files reach the renderer as browser `File`s, like Zalo Web's own `<input type=file>`: Swift picks them (NSOpenPanel) and answers
// the open panel of a hidden file input (`OfficialClientHost` WKUIDelegate) with exactly those URLs. The `File`s are disk-backed and
// carry no `path`, so the official readers use FileReader (`_readChunksArrayFile`, `getMd5LargeFileObject`, E2EE transforms) and the
// preload path-object branch (`$zFileManager.readChunksArrayObject`, not emulated) is never taken. The input is clicked synchronously
// in the call Swift makes (that call carries the user gesture WebKit requires).
//
// The official toasts and confirms of these paths would be drawn in the hidden page. While an action runs (and briefly after it, and
// after each confirm answer) the toast singleton (module "6uTC") is mirrored to Swift, ConfirmManagerV2 confirms become native alerts
// and the free-user upload-limit modal (EXCEED_SIZE_LIMIT_MODAL_V2) becomes its toast text. Actions do not queue behind text sends
// (no shared send chain: they never touch the quote banner); Swift hands over one pick at a time.
//
// Swift → JS : sendMedia(convId) sendFiles(convId) sendShot(convId, toMe) shareShot(convIds)   (each answers the hidden input first)
//              sendMyCard(convId, withPhone) myCard()
//              reminderInfo(convId) createReminder(convId, {title, startTime, repeat, needPin})
//              answer(token, ok)
//              → {status:'done'|'cancelled'|'not-open'|'not-ready'|'locked'|'denied'|'invalid'|'busy'|'pending'|'error', text?, …}
// JS → Swift (`zstate`): {page:'main', compose:{kind:'toast', convId, text}}
//                        {page:'main', compose:{kind:'confirm', token, convId, title, message, ok, cancel}}
(() => {
  'use strict';
  if (window.__zaloCompose) return;
  if (location.pathname.split('/').pop() !== 'index.html') return;
  const chat = window.__zaloChat;
  const core = chat && chat.__core;
  if (!core) return;
  const { S, safe, str, scrubErr, isGroupId, meNow, myName, myAvatar, sleep } = core;
  const diag = (s) => core.diag('compose: ' + s);
  const post = (compose) => { try { window.webkit.messageHandlers.zstate.postMessage({ page: 'main', compose }); } catch {} };

  const LOCKED_TEXT = 'Chỉ trưởng/phó nhóm được gửi tin nhắn vào nhóm này.';   // STR_LOCK_SEND_MESSAGE_MESSAGE_FULL
  const NOT_AVAILABLE = 'Chưa hỗ trợ trên ứng dụng này';
  const BUSY_TEXT = 'Thao tác trước đó vẫn đang được xử lý. Hãy chờ giây lát rồi kiểm tra lại cuộc trò chuyện.';
  const PENDING_TEXT = 'Thao tác đang được xử lý, chưa nhận được phản hồi. Hãy kiểm tra lại cuộc trò chuyện trước khi thử lại.';

  // ---- official modules, found by shape (throttled; real modules only, the host answers unknown globals with placeholders) ----
  const real = (o) => !!o && (typeof o === 'object' || typeof o === 'function') && safe(() => o.__olaz_not_a_member__, undefined) === undefined;
  const has = (o, ...fns) => fns.every((k) => typeof o[k] === 'function');
  const src = (f) => { try { return String(f); } catch { return ''; } };
  const M = {
    lang: null, toast: null, confirm: null, modal: null, overlimit: null, sendSrc: null, utils: null, consts: null,
    qr: null, phone: null, remember: null, verify: null, oa: null,
    rmdUtils: null, topics: null, rmdConsts: null, rmdCfg: null, community: null, jxlCfg: null,
  };
  const REQUIRED = ['lang', 'toast', 'confirm', 'modal', 'overlimit', 'sendSrc', 'utils', 'consts', 'qr', 'phone', 'remember', 'verify', 'oa', 'rmdUtils', 'topics', 'rmdConsts', 'rmdCfg', 'community'];
  let lastScan = 0;
  const scan = () => {
    if (REQUIRED.every((k) => M[k]) && M.jxlCfg) return;
    if (Date.now() - lastScan < 1500) return;
    lastScan = Date.now();
    const req = window.__zaloRequire;
    if (!req || typeof window.__zaloEachExport !== 'function') return;
    if (!M.verify && typeof window.__zaloDI === 'function') {
      safe(() => { for (const reg of window.__zaloDI(req)) { const i = reg && reg.instance; if (real(i) && typeof i === 'object' && typeof i.verifySetting === 'function') { M.verify = i; break; } } }, null);
    }
    safe(() => window.__zaloEachExport(req, (ex) => {
      if (!ex || ex === window.$capp || (typeof ex !== 'object' && typeof ex !== 'function') || !real(ex)) return;
      try {
        // send-source enums (`Ae.b.Photo` / `Ae.b.File`) next to their tracker
        if (!M.sendSrc && ex.b && ex.b.Photo && ex.b.File && ex.b.Photo.SEND_FROM_SCREENSHOT !== undefined && ex.b.File.CLICK_ICON_SEND_FILE !== undefined) M.sendSrc = ex.b;
        // the photo "Gửi dưới dạng file" confirm (`b`) and notice (`a`) of `_uploadImg` / the screenshot accept path
        if (!M.overlimit && typeof ex.a === 'function' && typeof ex.b === 'function' && src(ex.b).includes('InvalidPhotoSize')) M.overlimit = ex;
        if (!M.qr && typeof ex.c === 'function' && typeof ex.b === 'function' && src(ex.c).includes('getQRCodeUser')) M.qr = ex.c;
        if (!M.consts && ex.MSG_SUBTYPE_FILE_EEXC !== undefined && ex.MSG_FILE !== undefined) M.consts = ex;
        if (!M.rmdConsts && ex.REPEAT_CUSTOM !== undefined && ex.REMINDER_SRC_CHATBAR !== undefined && ex.CREATE_NOTICE_SRC_CHAT_BAR !== undefined && ex.ON_FEATURE) M.rmdConsts = ex;
        if (!M.community && ex.a && real(ex.a) && typeof ex.a.get === 'function' && src(ex.a.get).includes('COMMUNITY')) M.community = ex.a;
        if (!M.confirm && ex.ConfirmManagerV2 && typeof ex.ConfirmManagerV2.openConfirm === 'function') M.confirm = ex.ConfirmManagerV2;
        if (!M.modal && ex.ModalManagerV2 && has(ex.ModalManagerV2, 'openModal', 'closeModal')) M.modal = ex.ModalManagerV2;
        for (const o of [ex, ex.default, ex.a]) {
          if (!real(o) || (typeof o !== 'object' && typeof o !== 'function')) continue;
          if (!M.lang && has(o, 'str', 'trans', 'currentLanguage')) M.lang = o;
          if (!M.toast && has(o, 'createError', 'createMessagev2', 'createMessageCustom', '_createDom')) M.toast = o;
          if (!M.utils && has(o, 'isValidFileName', 'isEnableUpEecx', 'getExtension')) M.utils = o;
          if (!M.phone && typeof o.getPhoneNumberPro === 'function' && src(o.getPhoneNumberPro).includes('getCountryCode')) M.phone = o;
          if (!M.remember && typeof o.getRememberSendWithPhoneNumber === 'function' && src(o.getRememberSendWithPhoneNumber).includes('getItemForCurrentUser')) M.remember = o;
          if (!M.oa && has(o, 'isOABlocked', 'getOAStatus')) M.oa = o;
          if (!M.rmdUtils && has(o, 'isNoticeable', 'isAdminOrCreator', 'isOAType', 'getStringByteLength', 'checkAuth')) M.rmdUtils = o;
          if (!M.topics && has(o, 'createGroupTopicv2', 'createOneOneGroupTopic', 'getGroupInfoByLink')) M.topics = o;
          if (!M.rmdCfg && typeof o === 'function' && has(o, 'isNewUiEnabled', 'getMinLeadTimeMs', 'isOnlyMeEnabled')) M.rmdCfg = o;
          if (!M.jxlCfg && typeof o === 'function' && typeof o.canForwardAsJXL === 'function') M.jxlCfg = o;
        }
      } catch {}
    }), null);
  };
  const lang = (key, args) => safe(() => (args ? M.lang.trans(key, args) : M.lang.str(key)), '') || '';
  const cfg = () => S.cfg || {};

  // ---- official toasts / confirms → Swift while an action runs ----
  // Each running action has a scope {convId, running, until}; it stays open a little after the action (toasts and confirms the
  // official code raises right after) and again after each confirm answer (the official chain asks the next one then).
  const scopes = new Set();
  const confirms = new Map();  // token → {params, scope}
  const LOAD = Math.random().toString(36).slice(2, 8);   // tokens of an earlier page never match this one's
  let nextToken = 1;
  const liveScope = () => {
    let last = null;
    for (const s of scopes) { if (s.running || Date.now() < s.until) last = s; else scopes.delete(s); }
    return last;
  };
  const inScope = () => !!liveScope();
  const toast = (text, convId) => {
    const t = str(text).trim();
    const s = liveScope();
    if (t) post({ kind: 'toast', convId: str(convId || (s && s.convId)), text: t });
  };
  // Visible text of a React element (the official confirm messages): `textKey` nodes read from the string table; a div is a line of
  // its own unless it sits in a flex row.
  const textOf = (node, inFlex, depth) => {
    if (node == null || node === false || node === true || depth > 14) return '';
    if (typeof node === 'string' || typeof node === 'number') return String(node);
    if (Array.isArray(node)) return node.map((n) => textOf(n, inFlex, depth + 1)).join('');
    if (typeof node !== 'object' || !node.props) return '';
    const p = node.props;
    if (typeof p.textKey === 'string') return lang(p.textKey, p.params || p.textParams);
    const flex = /\bflx\b/.test(str(p.className));
    const inner = textOf(p.children, flex, depth + 1);
    return node.type === 'div' && !inFlex ? '\n' + inner + '\n' : inner;
  };
  const plain = (node) => textOf(node, false, 0).split('\n').map((l) => l.replace(/\s+/g, ' ').trim()).filter(Boolean).join('\n');
  let hooked = false;
  const hook = () => {
    scan();
    pinResizerConfig();
    if (hooked || !M.toast || !M.confirm || !M.modal) return hooked;
    const t = M.toast;
    if (!t.__olazCompose) {
      const dom = t._createDom, v3 = t.createMessagev3, custom = t.createMessageCustom;
      t._createDom = function (text) { if (inScope()) toast(text); return dom.apply(this, arguments); };
      if (typeof v3 === 'function') t.createMessagev3 = function (text) { if (inScope()) toast(text); return v3.apply(this, arguments); };
      t.createMessageCustom = function (opts) { if (inScope()) toast(opts && typeof opts.text === 'string' ? opts.text : ''); return custom.apply(this, arguments); };
      t.__olazCompose = true;
    }
    const cm = M.confirm;
    if (!cm.__olazCompose) {
      const open = cm.openConfirm;
      cm.openConfirm = function (opts) {
        const params = opts && opts.params;
        const s = liveScope();
        if (s && params && (typeof params.onOk === 'function' || typeof params.onCancel === 'function')) {
          const token = LOAD + '-' + nextToken++;
          confirms.set(token, { params, scope: s });
          post({
            kind: 'confirm', token, convId: str(s.convId),
            title: plain(params.title) || lang('STR_NOTIFICATION') || 'Thông báo', message: plain(params.message),
            ok: plain(params.okText) || 'OK', cancel: plain(params.cancelText) || lang('STR_CANCEL') || 'Hủy',
          });
          // Never answered (the window went away): the official promise is let go as a cancel.
          setTimeout(() => { if (confirms.has(token)) answer(token, false); }, 600000);
          return undefined;
        }
        return open.apply(this, arguments);
      };
      cm.__olazCompose = true;
    }
    const mm = M.modal;
    if (!mm.__olazCompose) {
      const openModal = mm.openModal;
      mm.openModal = function (opts) {
        const name = str(opts && opts.name);
        if (inScope() && name.includes('EXCEED_SIZE_LIMIT')) {
          // `handleValidationUI` free-user branch: the upgrade modal; the paid branch's toast says the same.
          const mb = Number(cfg().maxFileSize) || 1024;
          toast(lang('STR_TOAST_ERROR_FILE_SIZE_EXCEEDED', [mb >= 1024 ? Math.round(mb / 1024) + ' GB' : mb + ' MB']));
          return undefined;
        }
        if (inScope()) diag('modal ' + name.slice(0, 40));
        return openModal.apply(this, arguments);
      };
      mm.__olazCompose = true;
    }
    hooked = true;
    return true;
  };
  const answer = (token, ok) => {
    const entry = confirms.get(String(token));
    if (!entry) return false;
    confirms.delete(String(token));
    const params = entry.params;
    // A confirm the official code chains on this answer (gif after photo) is still bridged.
    entry.scope.until = Math.max(entry.scope.until, Date.now() + 2000);
    scopes.add(entry.scope);
    try { ok ? params.onOk && params.onOk() : params.onCancel && params.onCancel(); } catch (e) { diag('confirm ' + scrubErr(e)); }
    try { params.onClose && params.onClose(); } catch {}
    return true;
  };
  const withScope = async (convId, work) => {
    hook();
    const mine = { convId: String(convId), running: true, until: 0 };
    scopes.add(mine);
    try { return await work(); } catch (e) { diag('action ' + scrubErr(e)); return { status: 'error' }; }
    finally { mine.running = false; mine.until = Date.now() + 2500; core.refresh(); }
  };

  // DEVIATION FROM OFFICIAL (remote config `image_resizer.enable_libvips_macos` and `jxl.enable_upload` / `jxl.enable_upload_e2ee`).
  // Zalo PC for macOS relies on native Node addons (`libvips` and `zjxl/jxl.node`) that this host does not load (`local-modules.js`
  // stubs `$zFeatures.libvips` and `$zFeatures.libjxl` as unavailable). With `enable_libvips_macos` off, `3Rxw` resizes via
  // OffscreenCanvas; with `jxl.enable_upload` / `enable_upload_e2ee` off, `sendPhotoMessage` (`DhYn` / `X2DH`) sends standard
  // JPEG/PNG directly instead of stalling on the missing JXL worker in `pc-dist`.
  const pinResizerConfig = () => {
    if (M.jxlCfg) {
      safe(() => {
        const cur = M.jxlCfg._DevOnlyConfig || M.jxlCfg.DevOnlyJxlConfig || {};
        M.jxlCfg._DevOnlyConfig = Object.assign({}, cur, {
          enable_upload: false,
          enable_upload_e2ee: false,
          enable_native_electron_jxl: false,
        });
      }, null);
    }
    const c = S.cfg;
    if (!c || c.__olazResizer) return !!c;
    let resizerValue = c.image_resizer;
    let jxlValue = c.jxl;
    const patchedResizer = (v) => (v && typeof v === 'object' && !Array.isArray(v) ? Object.assign({}, v, { enable_libvips_macos: 0 }) : v);
    const patchedJxl = (v) => (v && typeof v === 'object' && !Array.isArray(v)
      ? Object.assign({}, v, { enable_upload: false, enable_upload_e2ee: false, enable_native_electron_jxl: false })
      : { enable_upload: false, enable_upload_e2ee: false, enable_native_electron_jxl: false });
    try {
      Object.defineProperty(c, 'image_resizer', { configurable: true, enumerable: true, get: () => patchedResizer(resizerValue), set: (v) => { resizerValue = v; } });
      Object.defineProperty(c, 'jxl', { configurable: true, enumerable: true, get: () => patchedJxl(jxlValue), set: (v) => { jxlValue = v; } });
      Object.defineProperty(c, '__olazResizer', { value: true });
    } catch (e) { diag('resizer config ' + scrubErr(e)); }
    return true;
  };

  // ---- the files Swift picked ----
  // Files <= 64 MB (clipboard images, Excel table renders, documents) are read straight into memory-backed `File`s via native XHR
  // `arraybuffer` on `AsarSchemeHandler` (`/__olaz/pending-file/<token>/<index>`), avoiding `<input type=file>` gesture issues and
  // custom-scheme Blob backing across Web Workers. Larger files (> 64 MB) use `<input type=file>` synchronously so WebKit streams
  // them from disk.
  const INLINE_FILE_LIMIT = 64 * 1024 * 1024;
  const readPendingMetaSync = (token) => {
    try {
      const XHR = window.__zaloNativeXHR || XMLHttpRequest;
      const xhr = new XHR();
      const url = token ? `zalo-app://local/__olaz/pending-files/${encodeURIComponent(token)}` : 'zalo-app://local/__olaz/pending-files';
      xhr.open('GET', url, false);
      xhr.send(null);
      if (xhr.status < 200 || xhr.status >= 300) return [];
      const meta = JSON.parse(xhr.responseText || '[]');
      return Array.isArray(meta) ? meta : [];
    } catch (e) {
      diag('pending meta ' + scrubErr(e));
      return [];
    }
  };
  const fetchArrayBuffer = (url) => new Promise((resolve, reject) => {
    try {
      const XHR = window.__zaloNativeXHR || XMLHttpRequest;
      const xhr = new XHR();
      xhr.open('GET', url, true);
      xhr.responseType = 'arraybuffer';
      xhr.onload = () => {
        if (xhr.status >= 200 && xhr.status < 300 && xhr.response) resolve(xhr.response);
        else reject(new Error('HTTP ' + xhr.status));
      };
      xhr.onerror = () => reject(new Error('XHR network error'));
      xhr.send(null);
    } catch (e) {
      reject(e);
    }
  });
  const fallbackPendingFiles = async (token, preloadedMeta) => {
    try {
      const meta = Array.isArray(preloadedMeta) && preloadedMeta.length ? preloadedMeta : readPendingMetaSync(token);
      if (!meta.length) return [];
      const out = [];
      for (const item of meta) {
        const path = token
          ? `zalo-app://local/__olaz/pending-file/${encodeURIComponent(token)}/${item.index}`
          : `zalo-app://local/__olaz/pending-file/${item.index}`;
        const buf = await fetchArrayBuffer(path);
        const f = new File([new Uint8Array(buf)], item.name || 'file', {
          type: item.mime || 'application/octet-stream',
          lastModified: Number(item.lastModified) || Date.now(),
        });
        if (item.path) {
          try { Object.defineProperty(f, 'path', { value: String(item.path), configurable: true, enumerable: true }); } catch {}
        }
        out.push(f);
      }
      return out;
    } catch (e) {
      diag('fallback pick ' + scrubErr(e));
      return [];
    }
  };

  const pickFiles = () => {
    const token = str(window.__olazPendingPickToken || '');
    window.__olazPendingPickToken = '';
    const meta = readPendingMetaSync(token);
    if (meta.length) {
      const q = (window.__olazPendingPhotoPaths = window.__olazPendingPhotoPaths || []);
      const exts = photoExts();
      for (const item of meta) {
        if (item && item.path && exts.includes(extOf(item.name))) {
          q.push({ path: String(item.path), name: String(item.name || ''), size: Number(item.size) || 0, ts: Date.now() });
        }
      }
      while (q.length > 30) q.shift();
    }
    if (meta.length && meta.every((m) => Number(m.size) >= 0 && Number(m.size) <= INLINE_FILE_LIMIT)) {
      return fallbackPendingFiles(token, meta);
    }
    const input = document.createElement('input');
    input.type = 'file';
    input.multiple = true;
    input.tabIndex = -1;
    input.style.cssText = 'position:fixed;left:-10000px;top:0;width:1px;height:1px;opacity:0;pointer-events:none';
    (document.body || document.documentElement).appendChild(input);
    const picked = new Promise((resolve) => {
      let done = false;
      const finish = (files) => {
        if (done) return;
        done = true;
        const list = Array.isArray(files) ? files : Array.from(input.files || []);
        if (meta.length) {
          for (const f of list) {
            if (!f.path) {
              const matched = meta.find((m) => m && m.name === f.name);
              if (matched && matched.path) {
                try { Object.defineProperty(f, 'path', { value: String(matched.path), configurable: true, enumerable: true }); } catch {}
              }
            }
          }
        }
        input.remove();
        resolve(list);
      };
      input.addEventListener('change', () => finish());
      input.addEventListener('cancel', () => {
        fallbackPendingFiles(token, meta).then((list) => finish(list));
      });
      setTimeout(() => {
        if (done) return;
        const current = Array.from(input.files || []);
        if (current.length) { finish(current); return; }
        fallbackPendingFiles(token, meta).then((list) => finish(list));
      }, 300);
    });
    try { input.click(); } catch (e) { diag('pick ' + scrubErr(e)); }
    return picked;
  };

  const extOf = (name) => { const s = str(name); const i = s.lastIndexOf('.'); return i < 0 ? '' : s.slice(i + 1).toLowerCase(); };
  const photoExts = () => { const list = cfg().supportPhoto; return Array.isArray(list) && list.length ? list.map((x) => String(x).toLowerCase()) : ['jpg', 'png', 'gif', 'jpeg', 'webp']; };
  const maxFiles = () => Number(cfg().maxNumberOfFile) || 50;
  const locked = (convId) => isGroupId(convId) && safe(() => !!(M.verify && M.verify.verifySetting({ field: 'lockSendMsg', convId })), false);
  const boxOrStatus = async (convId, needsOpen) => {
    let box = await core.boxFor(convId, needsOpen);
    if (typeof box === 'string' && box === 'not-open') {
      try { if (chat && typeof chat.open === 'function') await chat.open(convId); } catch {}
      box = await core.boxFor(convId, false);
    }
    return typeof box === 'string' ? { status: box } : box;
  };
  const SRC = () => M.sendSrc || { Photo: { CLICK_ICON_SEND_PHOTO: 301, SEND_FROM_SCREENSHOT: 309 }, File: { CLICK_ICON_SEND_FILE: 401 } };

  // `_onUploadFileClick` after its dialog: a name the upload refuses (executables) goes as "<name>.zip" with the EEXC sub type when
  // the remote config allows it, then `_uploadFile` (count limit, `_uploadDragFile` per file with the official checks and toasts).
  const uploadAsFiles = (box, files) => {
    const u = M.utils, eexc = M.consts && M.consts.MSG_SUBTYPE_FILE_EEXC;
    const list = files.map((f) => {
      if (!u || safe(() => u.isValidFileName(f.name), true) || !safe(() => u.isEnableUpEecx(), false)) return f;
      const named = new File([f], f.name + '.zip', { type: f.type, lastModified: f.lastModified });
      if (eexc !== undefined) named.subType = eexc;
      return named;
    });
    safe(() => { box.cc.mouseOverChatInput = false; }, null);
    box.cc._uploadFile({ target: { files: list, value: '' }, conversation: Object.assign({}, box.info) });
  };

  const sendFiles = (convId) => {
    const picked = pickFiles();
    convId = String(convId);
    return withScope(convId, async () => {
      const files = await picked;
      if (!files.length) return { status: 'cancelled' };
      const box = await boxOrStatus(convId, false);
      if (box.status) return box;
      if (locked(convId)) return { status: 'locked', text: LOCKED_TEXT };
      uploadAsFiles(box, files);
      diag(`files ${files.length}`);
      return { status: 'done' };
    });
  };

  // Photos the official photo button takes (`supportPhoto`) go its way; videos and anything else go as files, as on Zalo PC.
  const sendMedia = (convId, caption) => {
    const picked = pickFiles();
    convId = String(convId);
    const title = str(caption).trim();
    return withScope(convId, async () => {
      const files = await picked;
      if (!files.length) return { status: 'cancelled' };
      const box = await boxOrStatus(convId, false);
      if (box.status) return box;
      if (locked(convId)) return { status: 'locked', text: LOCKED_TEXT };
      if (files.length > maxFiles()) { box.cc._notifySendTooManyFile(); return { status: 'invalid' }; }
      const exts = photoExts();
      const photos = files.filter((f) => exts.includes(extOf(f.name)));
      const others = files.filter((f) => !photos.includes(f));
      safe(() => { box.cc.mouseOverChatInput = false; }, null);
      if (photos.length === 1 && !others.length && title) {
        const targetConv = Object.assign({}, box.info);
        const opts = { isPasted: false, isUploaded: true, withoutPreview: true, targetConv, title, sendSource: SRC().Photo.CLICK_ICON_SEND_PHOTO };
        try {
          await box.cc._uploadDragPhoto(photos[0], opts);
        } catch (e) {
          if (!e || !e.code) throw e;
          safe(() => M.overlimit && M.overlimit.b({ [e.code]: [photos[0]] }, box.cc.windowId, box.cc._sendOverlimitPhoto.bind(box.cc, targetConv)), null);
        }
      } else {
        if (photos.length) await box.cc._uploadImg({ target: { files: photos, value: '' } }, Object.assign({}, box.info), SRC().Photo.CLICK_ICON_SEND_PHOTO, false);
        if (others.length) uploadAsFiles(box, others);
      }
      diag(`media photos=${photos.length} files=${others.length}`);
      return { status: 'done' };
    });
  };

  // One screenshot (the PNG Swift wrote from the clipboard) into `target`, as `onCaptureResponseAccept` / `_onCaptureResponseSend2Me` do.
  const sendShotTo = async (box, file, fromMe) => {
    safe(() => { box.cc.mouseOverChatInput = false; }, null);
    const opts = { isPasted: false, isUploaded: true, withoutPreview: true, targetConv: Object.assign({}, box.info), sendSource: SRC().Photo.SEND_FROM_SCREENSHOT };
    if (fromMe) opts.isFromScreenshot = true;
    try {
      await box.cc._uploadDragPhoto(file, opts);
    } catch (e) {
      if (!e || !e.code) throw e;
      // The processor refused the photo: the official notice, then the shot goes as a file.
      safe(() => M.overlimit && M.overlimit.a({ [e.code]: [file] }, box.cc.windowId), null);
      await box.cc._uploadDragFile(file, { isPasted: false, isUploaded: true, withoutPreview: true, targetConv: Object.assign({}, box.info), isFromScreenshot: !!fromMe });
    }
  };
  const sendShot = (convId, toMe) => {
    const picked = pickFiles();
    convId = String(convId);
    return withScope(convId, async () => {
      const file = (await picked)[0];
      if (!file) return { status: 'cancelled' };
      const target = toMe ? str(cfg().sendToMeId) : convId;
      if (!target) return { status: 'error' };
      if (!toMe && locked(target)) return { status: 'locked', text: LOCKED_TEXT };
      const box = await boxOrStatus(target, false);
      if (box.status) return box;
      await sendShotTo(box, file, toMe);
      if (toMe) toast(lang('STR_SEND2ME_SHARE_SUCCESS', [lang('KEY_NAME_SEND2ME')]) || 'Đã gửi vào Cloud của tôi');
      return { status: 'done' };
    });
  };
  // "Chia sẻ": the shot to each chosen conversation (`handleForwardScreenCap` callback: `sendPhotoMessage(blob, {targetConv})`).
  const shareShot = (convIds) => {
    const picked = pickFiles();
    const ids = (Array.isArray(convIds) ? convIds : []).map(String).filter(Boolean);
    return withScope(ids[0] || '', async () => {
      const file = (await picked)[0];
      if (!file) return { status: 'cancelled' };
      let sent = 0;
      for (const id of ids) {
        if (locked(id)) { toast(LOCKED_TEXT); continue; }
        const box = await boxOrStatus(id, false);
        if (box.status) continue;
        try {
          await box.cc.sendPhotoMessage(file, { targetConv: Object.assign({}, box.info), sendSource: SRC().Photo.SEND_FROM_SCREENSHOT });
          sent++;
        } catch (e) { diag('share shot ' + scrubErr(e)); }
      }
      return sent ? { status: 'done', sent } : { status: 'error' };
    });
  };

  // ---- Danh thiếp: my own card, as the SHARE_CONTACT modal builds one ----
  const meProfile = () => safe(() => S.friends.getProfileMeSync(), null);
  const myPhone = (me) => (me && me.phoneNumber ? str(safe(() => M.phone.getPhoneNumberPro(String(me.phoneNumber)), '')) : '');
  const myCard = async () => {
    if (!(await core.ready())) return null;
    scan();
    const me = meProfile();
    const uid = str(me && me.userId) || meNow();
    if (!uid) return null;
    return {
      uid, name: str(me && me.zaloName) || str(me && me.displayName) || myName(),
      avatar: str(me && me.avatar) || myAvatar(), phone: myPhone(me),
      withPhone: safe(() => M.remember.getRememberSendWithPhoneNumber() !== false, true),
    };
  };
  const sendMyCard = (convId, withPhone) => {
    convId = String(convId);
    return withScope(convId, async () => {
      const box = await boxOrStatus(convId, false);
      if (box.status) return box;
      if (locked(convId)) return { status: 'locked', text: LOCKED_TEXT };
      scan();
      const me = meProfile();
      const uid = str(me && me.userId) || meNow();
      if (!uid) return { status: 'not-ready' };
      let qr = {};
      try { qr = (M.qr && await Promise.race([M.qr([uid]), sleep(8000).then(() => ({}))])) || {}; } catch {}
      const desc = { qrCodeUrl: qr[uid] };   // an unknown QR is left out, as the official JSON.stringify drops undefined
      const wants = withPhone == null ? safe(() => M.remember.getRememberSendWithPhoneNumber() !== false, true) : !!withPhone;
      const phone = wants ? myPhone(me) : '';
      if (phone) desc.phone = phone;
      const msg = {
        message: { action: 'recommened.user', params: uid, thumb: str(me && me.avatar) || myAvatar(),
          title: str(me && me.zaloName) || str(me && me.displayName) || myName(), description: JSON.stringify(desc) },
        msgType: core.MSG.CONTACT,
      };
      if (box.info.refMessageId) msg.refMessageId = box.info.refMessageId;
      let ok = null;
      const run = Promise.resolve().then(() => box.cc._shareMessage_new([msg], [convId], (_uids, success) => {
        ok = Array.isArray(success) && success.some((x) => x && String(x.toUid) === convId);
      }));
      const r = await Promise.race([run.then(() => 'done', (e) => { diag('card ' + scrubErr(e)); return 'error'; }), sleep(30000).then(() => 'timeout')]);
      if (r === 'timeout') return { status: 'pending', text: PENDING_TEXT };   // the pending card is already in the chat
      return r === 'done' && ok === true ? { status: 'done' } : { status: 'error' };   // a failed send already shows as a failed bubble
    });
  };

  // ---- Nhắc hẹn (legacy compose modal; `reminder.enabled` is off live, so the v2 flow is not used) ----
  const RMD = {
    empty: 'Vui lòng nhập nội dung nhắc hẹn', future: 'Vui lòng chọn thời gian tương lai', past: 'Vui lòng chọn ngày giờ trong tương lai',
    long: 'Bạn đã nhập quá số kí tự cho phép', block: 'Yêu cầu thực hiện không thành công vì bạn hoặc người này đã chặn nhau',
    blockOA: 'Yêu cầu thực hiện không thành công vì bạn đã chặn OA này', notFriend: 'Yêu cầu thực hiện không thành công vì hai bạn chưa kết bạn trên Zalo',
    perm: 'Bạn không có quyền thực hiện thao tác này.', net: 'Không có mạng, vui lòng kiểm tra lại kết nối và thử lại', fail: 'Tạo nhắc hẹn không thành công.',
    admin: 'Chỉ trưởng/phó nhóm được phép tạo ghi chú, nhắc hẹn', adminComm: 'Chỉ trưởng/phó cộng đồng được phép tạo ghi chú, nhắc hẹn',
    group: 'Nhóm không còn tồn tại hoặc bạn không còn là thành viên.',
  };
  const RMD_COLOR = -16245706;   // #081C36, `convertHexColorToNumber` of the modal's default colour
  const RMD_BYTES = 3700;
  const titleLimit = () => { const n = Number(cfg().limitTitleTextChar); return n > 0 ? n : 3000; };
  const myUid = () => str(meNow());
  const groupOf = (convId) => safe(() => S.groups.getGroupByIdSync(convId), null);
  // Chat-bar "…" gate (`Re` + the OA filter) → {allowed, hidden?, text?}
  const reminderGate = (convId) => {
    const c = cfg();
    if (isGroupId(convId)) {
      const g = groupOf(convId);
      if (!g) return { allowed: false, text: RMD.group };
      if (safe(() => M.rmdUtils.isNoticeable(g, myUid()), false)) return { allowed: true };
      const key = str(safe(() => M.community.get('STE_ADMIN_CREATE_TOPIC', g), 'STE_ADMIN_CREATE_TOPIC'));
      return { allowed: false, text: key.startsWith('STE_COMMUNITY') ? RMD.adminComm : RMD.admin };
    }
    if (c.sendToMeId && String(c.sendToMeId) === convId) return { allowed: safe(() => M.rmdConsts.ON_FEATURE.ENABLE_SENDTOME_REMINDER === true, false) };
    const p = safe(() => S.friends.getProfileFriendByIdSync(convId), null);
    if (p && (safe(() => M.rmdUtils.isOAType(p), false) || p.oaInfo)) return { allowed: false, hidden: true };
    return { allowed: Number(c.enable_reminder_1_1) === 1 };
  };
  // Pin is the group modal's "ghim nhắc hẹn" (on by default) when `allowPin`; its checkbox shows only without group topics.
  const canPin = (convId) => {
    const g = groupOf(convId), st = g && g.setting, a = g && safe(() => M.rmdUtils.checkAuth(g, myUid()), null);
    return !!(st && a) && !(st.setTopicOnly === 1 && a.isAdmin !== true && a.groupOwner !== true);
  };
  const reminderInfo = async (convId) => {
    convId = String(convId);
    if (!(await core.ready())) return null;
    scan();
    if (!M.rmdUtils || !M.topics || !M.rmdConsts) return null;
    const isGroup = isGroupId(convId);
    const pin = isGroup && canPin(convId);
    return Object.assign(reminderGate(convId), {
      isGroup, canPin: pin, pinToggle: pin && !safe(() => cfg().group_topics.enable, false),
      titleMaxChars: titleLimit(), titleMaxBytes: RMD_BYTES,
    });
  };
  const reminderFailText = (e, convId) => {
    const code = e && (e.error_code !== undefined ? e.error_code : e.code);
    if (code === 'ERR_NO_NETWORK') return RMD.net;
    if (code === 166) return RMD.perm;
    if (code === 161) return RMD.group;
    if (code === -20017) return RMD.notFriend;
    if (code === -20018) return safe(() => M.oa.isOABlocked(convId), false) ? RMD.blockOA : RMD.block;
    return code !== undefined ? `${RMD.fail} (${code})` : RMD.fail;
  };
  // One create per conversation at a time; a request that has not answered after 20 s is 'pending' (never sent twice).
  const creating = new Map();
  const createReminder = async (convId, opts) => {
    convId = String(convId);
    if (creating.has(convId)) return { status: 'busy', text: BUSY_TEXT };
    const work = (async () => {
      if (!(await core.ready())) return { status: 'error', text: NOT_AVAILABLE };
      scan();
      if (!M.rmdUtils || !M.topics || !M.rmdConsts) return { status: 'error', text: NOT_AVAILABLE };
      const gate = reminderGate(convId);
      if (!gate.allowed) return { status: 'denied', text: gate.text || NOT_AVAILABLE };
      const raw = str(opts && opts.title), title = raw.trim(), repeat = Number(opts && opts.repeat) || 0;
      const t = new Date(Number(opts && opts.startTime));
      t.setSeconds(0, 0);
      const startTime = t.getTime();
      if (!title) return { status: 'invalid', text: RMD.empty };
      if (raw.length >= titleLimit() || safe(() => M.rmdUtils.getStringByteLength(title), 0) > RMD_BYTES) return { status: 'invalid', text: RMD.long };
      if (!(startTime > 0) || startTime < Date.now() - 60000) return { status: 'invalid', text: RMD.future };
      if (![0, 1, 2, 3].includes(repeat)) return { status: 'invalid', text: RMD.fail };
      const isGroup = isGroupId(convId), C = M.rmdConsts;
      if (!isGroup && safe(() => !!(M.verify && M.verify.verifySetting({ field: 'lockSendMsg', convId })), false))
        return { status: 'denied', text: safe(() => M.oa.isOABlocked(convId), false) ? RMD.blockOA : RMD.block };
      const p = isGroup
        ? M.topics.createGroupTopicv2(convId.slice(1), C.TEXT_TOPIC, RMD_COLOR, '⏰', startTime, -1, { title }, !!(opts && opts.needPin !== false) && canPin(convId), 0, repeat, C.CREATE_NOTICE_SRC_CHAT_BAR)
        : M.topics.createOneOneGroupTopic({ toUid: convId, type: C.TEXT_TOPIC, color: RMD_COLOR, emoji: '⏰', startTime, duration: -1, params: { title },
          needPin: false, repeat, creatorUid: myUid(), src: C.REMINDER_SRC_CHATBAR });
      try { await p; diag('reminder created'); return { status: 'done' }; } catch (e) {
        diag('reminder ' + scrubErr(e && (e.error_code !== undefined ? e.error_code : e.code) || e));
        return { status: 'error', text: reminderFailText(e, convId) };
      }
    })();
    creating.set(convId, work);
    const clear = () => { if (creating.get(convId) === work) creating.delete(convId); };
    work.then(clear, clear);
    const r = await Promise.race([work, sleep(20000).then(() => null)]);
    return r || { status: 'pending', text: PENDING_TEXT };
  };

  window.__zaloCompose = {
    sendMedia, sendFiles, sendShot, shareShot, sendMyCard, myCard, reminderInfo, createReminder,
    answer(token, ok) { return answer(token, !!ok); },
    // Diagnostics: the official modules not found (yet).
    missing() { scan(); return REQUIRED.filter((k) => !M[k]); },
  };
  // message-actions-adapter.js runs its official calls in the same scope (their toasts / confirms reach Swift the same way).
  Object.defineProperty(window.__zaloCompose, '__scope', { value: withScope });
  // Hooks go in early so a toast of the first action is not missed.
  const boot = setInterval(() => { if (hook()) clearInterval(boot); }, 2000);
  setTimeout(() => clearInterval(boot), 120000);
})();
