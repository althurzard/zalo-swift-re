// Olaz message actions adapter (index.html only): the message context menu's "Chia sẻ", "Thu hồi", "Xóa chỉ ở phía tôi", "Ghim tin nhắn"
// and "Đánh dấu tin nhắn", plus the conversation's pinned list, through the official services. Attaches to `window.__zaloChat`
// (chat-adapter.js `chat.__core`) and exposes `window.__zaloMsgActions`; chat-adapter.js merges `describe(m, convId)` into every
// ChatMessageJSON as `menu`.
//
// Where the official client keeps each piece (offsets in default-login-main-startup-shared-worker-znotification.*.js; "ms" = lazy chunk
// main-startup.*.js):
//   Menu      module "DOj/" `Oe` ~3858900 builds the right-click menu of a message (items: module "XOIG" ~9914000, ids: "s0Wb"). Predicates
//             are module "dm9D" (u = recalled / deleted / failed / undecryptable, O = sending, h = call log, E = OA list, G = not
//             replyable, S = sticker-set card, cb / db = zinstant / pinnable zinstant, P = starred, o = failed, r / s / F = photo group /
//             sticker group / single-sticker group, l = undecryptable, I / R = photo sticker / sticker).
//             forward  ~3862700  not G / h / E / S / cb, shareable ("ymth" a); disabled (STR_BLOCK_SHARING_ACTION_BLOCKED) under "Chặn chia
//                      sẻ" (module "czzM" ConversationPrivacy `isContentProtected`).
//             pin      `he` ~3858100  not My Cloud / an OA chat; groups: owner / deputy or `setting.setTopicOnly` off (`ue`); not a photo
//                      group, a call, G, E, or a zinstant without `canPin`; a sticker group only with one sticker.
//             star     `Ie` ~3858700  not recalled / deleted / zinstant / h / u / O; "Bỏ đánh dấu" when starred (photo group: any photo);
//                      "Đánh dấu" disabled under "Chặn chia sẻ".
//             recall   `pe` ~3858450  my own message (fromUid "0"), not u / O / h, not My Cloud, not a sticker group / zinstant (bubble
//                      zinstants allowed); a photo group when any photo qualifies.
//             delete   ~3866900  failed → "Xóa" (DeleteMessage), My Cloud → "Xóa" (DeleteEveryOne), otherwise "Xóa chỉ ở phía tôi"; all
//                      run the chat box `deleteMessage` (~9639051 `It`): my message → (confirm when `enable_popup_confim_del`) → controller
//                      `_deleteMessageOnlyMe`. A group admin's TOGGLE_CONFIRM_DEL choice ("Xóa cho cả nhóm") is not offered here.
//   Forward   item ~9923400: controller `_shareMessage(msg, null, null, SHARE_FROM_MESSAGE, {actualEntry: SHARE_FROM_MESSAGE_RIGHT_ACTION})`
//             opens the SHARE_MSG_COMPOSE picker; with targets `_shareMessage_new` (~4250300) awaits the forward module
//             (`forwardMessages(msgs, convIds, opts)`, ms ~1035936) and calls back with the conversations that got it. The picker is native
//             here (≤ `forward_conv_limit`, STR_MAX_MEM_SHARE_MSG_TOAST). Photo stickers ("vC+R" a) and private stickers ("pI5b" a) are
//             checked first, as the item's handler does.
//   Recall    item ~9924100 → controller `_recallMessage` ~4201500 (`recallMessages` for a sticker group): `recallMessageMaxTime` check
//             (STR_RECALL_MSG_TOAST_EXPIRED_TIME), `dThN.undoMessage(msgId, toUid, NMlV.next(), cliMsgId, isE2EE)`, then unstar when
//             starred; error 211 → STR_ERR_UNDO_211, other codes → STR_ERR_UNDO_UNSUCCESS (code). It does not return its promise, so the
//             same steps run here to learn the outcome.
//   Delete    controller `_deleteMessageOnlyMe` ~4194900 → module "m89U" `b` ~13743000: `smi1.deleteMsgs(conv, msgs)` (`deleteMsgsNotUndo`
//             with `undo_delete.enable` off), `m89U.a(msgsDel)` drops them from the store, and the internal snackbar "N tin nhắn đã xóa ·
//             Khôi phục" counts down to `expireAt` (performance clock): Khôi phục = `m89U.d(id)` (undoDeleteMsgs), close = `m89U.c(id)`
//             (startDeleteNow), timeout = nothing. The snackbar is native here, so `b` is replayed without it. My failed message also
//             leaves the conversation preview (PreviewDataManager `onDeleteMessage`), as `_deleteMessageOnlyMe` does.
//   Pin       item ~9923500: groups → topic built from the DB copy (`he` ~9921000, `XS0u.getMessage`) → board "jnJr".a.getInstance(conv)
//             `checkPinTopic` ~13373499 (allowance, then the "Cập nhật danh sách ghim" dialog once `group_topics.pin_limit` is reached, else
//             `callCreateOrPinTopic` → `createGroupTopicv2`); 1:1 → UI controller `createPinTopicFromMessage` (ms ~1082789) → "YYsv".j
//             `GetManager().createPinTopic(conv, topic)` (friends only; PINBOARD_OVER_MAXIMUM opens a limit dialog). The dialogs are
//             invisible here: replacing the oldest pin is confirmed natively (as poll-adapter.js does for polls) and the same calls run.
//   Unpin     group board `callUnpinTopic(conv, {id, type})`; 1:1 manager `unpinPinTopics(conv, [topic])` (the official confirm
//             STR_DELETE_UNPINNED_MSG_CONFIRM is asked natively before).
//   Star      item ~9928700: `XS0u.addStarMessages(msgs, now)` + `shouldSaveTsStarMsgSchemaChanged(now)` + ADD_STAR ("97kL") on the store
//             ("PoHQ".n); unstar ~9930600: `XS0u.unstaredMessages(msgs)` + DELETE_STAR + toast STR_MSG_UNSTARRED. A photo group stars every
//             photo that is not recalled / undecryptable; a single-sticker group its sticker.
//   Pins      group board topics (`topicStore`, one store shared by every board; changes are seen by wrapping its setters) and the 1:1
//             manager's `loadPinTopics(conv)` + "onchange" events.
//
// A photo of an album is its own message to the menu: the official album view opens the menu of the photo right-clicked (ms ~1378821
// `onContextMenu: e => showAction(e, photo)` → `showMessageAction(e, true, photo, …)` ~1366263 → `showContextMenu({message: photo})`
// ~1382367), so that photo alone is forwarded, recalled, deleted, starred or pinned — as chat-adapter.js draws each photo as its own row.
// Polls are pinned from their card (poll-adapter.js), not from here.
//
// WRITE ACTIONS (forward, recall, deleteForMe, undoDelete, commitDelete, star, pin, unpin) run only when Swift calls them from an explicit
// user click. Official toasts / confirms raised meanwhile reach Swift through the composer's scope (composer-adapter.js `__scope`).
//
// Swift → JS : forward(convId, msgId, targets) → {status, sent?, total?, text?} · recall(convId, msgId) · deleteForMe(convId, msgId, confirmed)
//              → {status, undo?:{id, count, ms}} · undoDelete(id) · commitDelete(id) · dropDelete(id) · star(convId, msgId, on) · isProtected(convId) ·
//              watchPins(convId|null) · pins(convId) → PinsJSON · pin(convId, msgId, confirmRef?) · unpin(convId, ref)
//              status: 'done' | 'confirm' {title, message, ok, cancel, ref?} | 'denied' | 'invalid' | 'not-ready' | 'not-open' | 'error' |
//              'pending' (started, no answer yet); `text` = the official wording when there is one
// JS → Swift : {page:'main', pins: PinsJSON}
//   PinsJSON: {convId, ready, canPin, items:[{ref ('type:id'), kind: 'message'|'note'|'link'|'poll'|'reminder', title, sender, thumb,
//              msgId, cliMsgId}]}   (newest pin first, as the official board keeps them)
//   describe → {forward: 'ok'|'blocked'|'', recall, delete: 'forMe'|'plain'|'', pin, star: 'star'|'unstar'|'blocked'|'', starred,
//              protected (Chặn chia sẻ: no copying either), pinned}
(() => {
  'use strict';
  if (window.__zaloMsgActions) return;
  if (location.pathname.split('/').pop() !== 'index.html') return;
  const chat = window.__zaloChat;
  const core = chat && chat.__core;
  if (!core) return;
  const { safe, str, scrubErr, isGroupId, meNow, nameOf, absUrl, parseJSON, waitFor, convOf } = core;
  const diag = (s) => core.diag('msg-actions: ' + s);
  const post = (pins) => { try { window.webkit.messageHandlers.zstate.postMessage({ page: 'main', pins }); } catch {} };
  const mod = (id) => { try { const m = window.__zaloRequire && window.__zaloRequire.c[id]; return m ? m.exports : null; } catch { return null; } };
  const fn = (o, k) => !!o && typeof o[k] === 'function';
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const withTimeout = (p, ms) => Promise.race([Promise.resolve(p), sleep(ms).then(() => { throw new Error('timeout'); })]);
  const isTimeout = (e) => !!e && e.message === 'timeout';
  const num = (v) => { const n = Number(v); return Number.isFinite(n) ? n : 0; };

  // ---- official modules (by id, checked by shape) ----
  const PRED_KEYS = ['u', 'O', 'h', 'E', 'G', 'S', 'cb', 'db', 'P', 'o', 'r', 's', 'F', 'l', 'I', 'R'];
  const pred = () => { const p = mod('dm9D'); return p && PRED_KEYS.every((k) => fn(p, k)) ? p : null; };
  const consts = () => { const c = mod('1pet'); return c && c.MSG_TOPIC !== undefined && c.CONVERSATION_TYPE ? c : null; };
  // Modules looked up by id are used only when they have the expected shape (a Zalo update can renumber them). What the safety
  // checks read from them fails CLOSED when it is missing: delete asks for confirmation, a conversation counts as protected
  // ("Chặn chia sẻ": no forward / copy / star) — see `confOk`, `protectedOf`. Each miss is logged once.
  const missed = new Set();
  const miss = (what) => { if (!missed.has(what)) { missed.add(what); diag('module missing or changed: ' + what + ' (failing closed)'); } };
  const hasOwn = (o, k) => !!o && Object.prototype.hasOwnProperty.call(o, k);
  const isConf = (c) => !!c && typeof c === 'object' && hasOwn(c, 'sendToMeId') && hasOwn(c, 'stickerUrl');
  // The remote config (`NDmK`), else the one chat-adapter.js resolved by shape; null when neither is there.
  const confOk = () => {
    const c = safe(() => mod('NDmK').default, null);
    if (isConf(c)) return c;
    const s = safe(() => core.S.cfg, null);
    if (isConf(s)) return s;
    miss('config');
    return null;
  };
  const cfg = () => confOk() || {};
  const langMod = () => { const l = safe(() => mod('c51z').default, null); return fn(l, 'str') && fn(l, 'trans') ? l : (miss('lang'), null); };
  const lang = (key, args) => safe(() => { const l = langMod(); return l ? (args ? l.trans(key, args) : l.str(key)) : ''; }, '') || '';
  // "Chặn chia sẻ" of a conversation; true when the privacy module cannot answer.
  const protectedOf = (convId) => {
    const m = safe(() => mod('czzM').ConversationPrivacy.GetModule(), null);
    if (!fn(m, 'isContentProtected')) { miss('privacy'); return true; }
    try { return !!m.isContentProtected(convId); } catch (e) { miss('privacy'); return true; }
  };
  const timeNow = () => num(safe(() => mod('bUXd').default.getTimeNow(), 0)) || Date.now();
  // Official strings (lang_vi.json) for when the string table is not reachable.
  const TEXT = {
    STR_MESSAGE_NOT_FOUND: 'Tin nhắn gốc không còn tồn tại', STR_TOAST_ERROR: 'Có lỗi xảy ra', STR_UNDO_DELETE_MSGS_F: 'Không thể khôi phục',
    STR_PIN_GENERAL_ERROR: 'Yêu cầu thực hiện không thành công', STR_ONLY_PIN_MAX_CONTENT: 'Đã đạt giới hạn $0$ ghim.',
    STR_MSG_SHARE_SUCCESS: 'Đã chia sẻ tin nhắn', STR_MSG_SHARE_ERROR: 'Có lỗi khi chia sẻ tin nhắn',
    STR_POPUP_DELETE_MSG_TITLE: 'Xóa tin nhắn', STR_POPUP_DELETE_MSG_BT_DEL: 'Xóa tin nhắn', STR_POPUP_DELETE_MSG_BT_CLOSE: 'Đóng',
    STR_POPUP_DELETE_MSG_DES: 'Thao tác này chỉ xóa tin nhắn trên máy bạn. Để xoá nội dung trên máy người nhận, nhấn phải chuột vào tin nhắn và chọn "Thu hồi".',
    STR_RECALL_MSG_TOAST_EXPIRED_TIME: 'Bạn chỉ có thể thu hồi tin nhắn trong vòng $0$', STR_ERR_UNDO_211: 'Phiên bản Zalo bên người nhận chưa hỗ trợ thu hồi tin nhắn',
    STR_ERR_UNDO_UNSUCCESS: 'Thu hồi tin nhắn không thành công', STR_BLOCK_SHARING_ACTION_BLOCKED: 'Trò chuyện này đã bật Chặn chia sẻ',
    STR_UNABLE_TO_FORWARD_PHOTO_STICKER: 'Không thể chia sẻ sticker này', STR_MAX_MEM_SHARE_MSG_TOAST: 'Bạn chỉ có thể chia sẻ cho $0$ hội thoại khác',
    STR_MSG_UNSTARRED: 'Đã bỏ đánh dấu tin nhắn', STR_DELETE_MSGS_F: 'Không thể xóa tin nhắn', STR_TOAST_UNDO_MESSAGE: 'Tin nhắn đã được thu hồi',
    STR_ERROR_INFO_MSG_PIN_MESSAGE: 'Ghim tin nhắn không thành công.', STE_ADMIN_UPDATE_TOPIC: 'Chỉ trưởng/phó nhóm được phép ghim tin nhắn',
    STR_CONTENT_WILL_BE_REMOVED_FROM_PIN_TOPICS: 'Nội dung dưới đây sẽ bị bỏ khỏi bảng ghim', STR_CONFIRM_PIN: 'Cập nhật danh sách ghim',
    STR_CONFIRM: 'Xác nhận', STR_CANCEL: 'Hủy', STR_PIN_FRIEND_REACH_PIN_LIMIT: 'Bạn không thể ghim do $0$ đã đạt giới hạn trò chuyện 2 người được ghim.',
    STR_CHECK_NET: 'Vui lòng kiểm tra lại kết nối mạng của bạn.',
  };
  const fill = (s, args) => (args || []).reduce((acc, a, i) => acc.split('$' + i + '$').join(String(a)), s);
  const T = (key, args) => (lang(key, args) || fill(TEXT[key] || '', args)).replace(/\s+$/, '');
  const NOT_FOUND = () => ({ status: 'invalid', text: T('STR_MESSAGE_NOT_FOUND') });

  // ---- the conversation: chat type, "Chặn chia sẻ", pin allowance (memoised briefly: `describe` runs for every message of a flush) ----
  // Official `ue` (group pin allowance): I am the owner / a deputy (group `topMember`, with `setting` present), or `setting.setTopicOnly` is off.
  const groupPinAllowance = (g) => {
    if (!g || !g.setting || !Array.isArray(g.topMember) || !isGroupId(str(g.userId))) return false;
    const me = meNow();
    const staff = g.topMember.some((x) => x && x.id === me && (x.id == g.creatorId || x.isAdmin)); // eslint-disable-line eqeqeq
    return staff || !g.setting.setTopicOnly;
  };
  const ctxCache = new Map();
  const ctxOf = (convId) => {
    const hit = ctxCache.get(convId);
    if (hit && Date.now() - hit.at < 1000) return hit;
    const CT = safe(() => consts().CONVERSATION_TYPE, {}) || {};
    const type = safe(() => mod('jSEC').a(convId), CT.UNKNOWN);
    const isProtected = protectedOf(convId);
    const oa = type === CT.FRIEND && safe(() => !!mod('UiPd').default.isOA(convId), false);
    let pinChat = false;
    // Official `he` chat part: not unknown / My Cloud, not an OA, groups by allowance.
    if (type === CT.GROUP) pinChat = groupPinAllowance(safe(() => mod('Gm1y').default.getGroupByIdSync(convId), null));
    else if (type === CT.FRIEND) pinChat = !oa;
    const c = { at: Date.now(), type, cloud: type === CT.CLOUD, group: type === CT.GROUP, friend: type === CT.FRIEND && !oa, protected: isProtected, pinChat };
    ctxCache.set(convId, c);
    if (ctxCache.size > 40) ctxCache.delete(ctxCache.keys().next().value);
    return c;
  };

  // ---- message predicates (the official builder's, see the header) ----
  const zinstantBubble = (e) => safe(() => {
    const Z = mod('RoG4');
    if (!Z.h.isZInstant(e.msgType)) return false;
    const meta = Z.h.create(new Z.h.Adapters.MessageEntity(e)).getZInstantMetadata();
    return !!meta && meta.layoutType == Z.a.LAYOUT_TYPE.BUBBLE; // eslint-disable-line eqeqeq
  }, false);
  const recallable = (P, C, e, cloud) => {
    if (!e || String(e.fromUid) !== '0') return false;
    if (P.u(e) || P.O(e) || P.h(e) || cloud) return false;
    return ![C.MSG_DEL_EVERYONE, C.MSG_UNDO, C.MSG_STICKER_GROUP, C.MSG_ZINSTANT, C.MSG_ZINSTANT_V2].includes(e.msgType) || zinstantBubble(e);
  };
  const starable = (P, C, t) => !!t && ![C.MSG_DEL_EVERYONE, C.MSG_UNDO, C.MSG_ZINSTANT, C.MSG_ZINSTANT_V2, C.MSG_ZINSTANT_OLD].includes(t.msgType)
    && !P.h(t) && !P.u(t) && !P.O(t);
  const forwardable = (P, t) => !!t && !P.G(t) && !P.h(t) && !P.E(t) && !P.S(t) && !P.cb(t) && safe(() => !!mod('ymth').a(t), false);
  const pinnableMessage = (P, C, e) => {
    if (P.r(e)) return false;
    if (P.s(e)) {
      if (!Array.isArray(e.message) || e.message.length > 1) return false;
      const t = e.message[0];
      if (!t || P.u(t)) return false;
    }
    if (e.msgType === C.MSG_POLL) return false; // pinned from the poll card (poll-adapter.js)
    return !(P.h(e) || P.G(e) || P.E(e) || (P.cb(e) && !P.db(e)));
  };

  // ---- pins of the conversations on screen ----
  const pinCache = new Map();          // convId → official topic objects (newest first)
  const topicRef = (t) => String(t.type) + ':' + String(t.id);
  const paramsOf = (t) => (t && t.params && typeof t.params === 'object' ? t.params : parseJSON(t && t.params));
  const validId = (v) => v !== undefined && v !== null && String(v) !== '' && String(v) !== '0';
  // Official `_hasNewPinAlready`: same server id, else same client id from the same sender.
  const topicIsMessage = (C, t, m) => {
    if (!t || t.type !== C.MSG_TOPIC || !m) return false;
    const p = paramsOf(t);
    if (validId(p.global_msg_id) && validId(m.msgId)) return String(p.global_msg_id) === String(m.msgId);
    const from = String(m.fromUid) === '0' ? meNow() : String(m.fromUid);
    return validId(p.client_msg_id) && String(p.client_msg_id) === String(m.cliMsgId) && String(p.senderUid || '') === from;
  };
  const isPinned = (C, convId, m) => (pinCache.get(convId) || []).some((t) => topicIsMessage(C, t, m));

  // ---- describe: the menu of one message (chat-adapter.js `menu`; an album photo comes as its own message) ----
  const describe = (m, convId) => {
    const P = pred(), C = consts();
    if (!P || !C || !m || typeof m !== 'object') return null;
    const raw = m;
    convId = String(convId);
    const ctx = ctxOf(convId);
    const out = { forward: '', recall: false, delete: '', pin: false, star: '', starred: false, protected: ctx.protected, pinned: false };
    try {
      const list = Array.isArray(raw.message) && !P.E(raw) ? raw.message : null;
      if (forwardable(P, raw)) out.forward = ctx.protected ? 'blocked' : 'ok';
      out.pin = ctx.pinChat && pinnableMessage(P, C, raw);
      if (list) {
        if (list.every((x) => starable(P, C, x)) && (!P.s(raw) || list.length === 1)) {
          out.starred = list.some((x) => P.P(x));
          out.star = out.starred ? 'unstar' : ctx.protected ? 'blocked' : 'star';
        }
      } else if (starable(P, C, raw)) {
        out.starred = !!P.P(raw);
        out.star = out.starred ? 'unstar' : ctx.protected ? 'blocked' : 'star';
      }
      out.recall = list ? list.some((x) => recallable(P, C, x, ctx.cloud)) : recallable(P, C, raw, ctx.cloud);
      out.delete = P.o(raw) || ctx.cloud ? 'plain' : 'forMe';
      out.pinned = out.pin && isPinned(C, convId, P.s(raw) ? raw.message[0] : raw);
    } catch (e) { diag('describe ' + scrubErr(e)); }
    return out;
  };

  // ---- the official message of a row ----
  // chat-adapter.js keys rows by the same rule (`mapOne`): own = cliMsgId, others = server msgId (cliMsgId when that is a fake id). Only that
  // id is matched: a client id alone is not unique across senders. An album photo is the store's photo merged over its group (as
  // chat-adapter.js maps it), keyed by its own row id or `<group row id>#<index>`.
  const isFakeId = (id) => !id || String(id).includes('_') || String(id) === '0';
  const rowIdOf = (m) => {
    const from = String(m.fromUid ?? m.uidFrom ?? '');
    const mine = from === '0' || (!!meNow() && from === meNow());
    const cli = String(m.cliMsgId ?? ''), server = String(m.msgId ?? '');
    const validCli = cli && cli !== '0' && cli !== 'undefined';
    return mine ? (validCli ? cli : server) : (!isFakeId(server) ? server : cli);
  };
  const albumPhoto = (C, group, child) => Object.assign({}, group, child, {
    msgType: child.msgType || C.MSG_PHOTO, fromUid: child.fromUid ?? group.fromUid, status: child.status ?? group.status,
  });
  const findRaw = (C, convId, id) => {
    const conv = convOf(convId);
    const want = String(id || '');
    if (!conv || !want) return null;
    const [base, index] = want.includes('#') ? want.split('#') : [null, null];
    for (const m of conv.messages || []) {
      if (!m) continue;
      if (m.msgType === C.MSG_PHOTO_GROUP && Array.isArray(m.message)) {
        const groupId = rowIdOf(m);
        for (let i = 0; i < m.message.length; i++) {
          const child = m.message[i];
          if (!child) continue;
          const photo = albumPhoto(C, m, child);
          if ((base !== null && base === groupId && Number(index) === i) || (rowIdOf(photo) === want && want !== groupId)) return photo;
        }
        continue;
      }
      if (rowIdOf(m) === want) return m;
    }
    return null;
  };
  // Resolves services and the row's official message; a string = the status to answer with.
  const subject = async (convId, msgId) => {
    if (!(await core.ready())) return 'not-ready';
    const P = pred(), C = consts();
    if (!P || !C) return 'not-ready';
    const raw = findRaw(C, convId, msgId);
    return raw ? { P, C, raw, menu: describe(raw, convId) || {} } : 'not-found';
  };
  const answerFor = (s) => (s === 'not-found' ? NOT_FOUND() : { status: s });

  // Official toasts / confirms raised by these calls reach Swift through the composer's scope.
  const scoped = (convId, work) => {
    const sc = window.__zaloCompose && window.__zaloCompose.__scope;
    if (typeof sc === 'function') return sc(String(convId), work);
    return (async () => { try { return await work(); } catch (e) { diag('action ' + scrubErr(e)); return { status: 'error' }; } finally { core.refresh(); } })();
  };

  // ---- Chia sẻ ----
  const forward = (convId, msgId, targets) => scoped(convId, async () => {
    convId = String(convId);
    const s = await subject(convId, msgId);
    if (typeof s === 'string') return answerFor(s);
    const { P, C, raw, menu } = s;
    if (menu.forward === 'blocked') return { status: 'denied', text: T('STR_BLOCK_SHARING_ACTION_BLOCKED') };
    if (menu.forward !== 'ok') return { status: 'invalid', text: T('STR_MSG_SHARE_ERROR') };
    const ids = [...new Set((Array.isArray(targets) ? targets : []).map((x) => String(x)).filter(Boolean))];
    const limit = num(cfg().forward_conv_limit) || 100;
    if (!ids.length) return { status: 'invalid' };
    if (ids.length > limit) return { status: 'invalid', text: T('STR_MAX_MEM_SHARE_MSG_TOAST', [String(limit)]) };
    if (P.I(raw) && !(await Promise.resolve(safe(() => mod('vC+R').a(raw), true)).catch(() => true))) return { status: 'denied', text: T('STR_UNABLE_TO_FORWARD_PHOTO_STICKER') };
    if (P.R(raw)) {
      const r = await Promise.resolve(safe(() => mod('pI5b').a(raw), null)).catch(() => null);
      if (r && r.ok === false) return { status: 'denied', text: T('STR_UNABLE_TO_FORWARD_PHOTO_STICKER') };
    }
    const box = await core.boxFor(convId, false);
    if (typeof box === 'string') return { status: box };
    let sent = null;
    try {
      await withTimeout(box.cc._shareMessage(raw, ids, (uids) => { sent = Array.isArray(uids) ? uids.map(String) : []; }, C.SHARE_FROM_MESSAGE,
        { actualEntry: C.SHARE_FROM_MESSAGE_RIGHT_ACTION }), 60000);
    } catch (e) {
      if (isTimeout(e)) return { status: 'pending' };
      diag('forward ' + scrubErr(e && (e.error_code !== undefined ? e.error_code : e)));
      return { status: 'error', text: T('STR_MSG_SHARE_ERROR') };
    }
    if (!sent || !sent.length) return { status: 'error', text: T('STR_MSG_SHARE_ERROR') };
    const partial = sent.length < ids.length;
    return { status: 'done', sent: sent.length, total: ids.length,
      text: partial ? `Đã chia sẻ tin nhắn tới ${sent.length}/${ids.length} hội thoại` : T('STR_MSG_SHARE_SUCCESS') };
  });

  // ---- Thu hồi ----
  const recall = (convId, msgId) => scoped(convId, async () => {
    convId = String(convId);
    const s = await subject(convId, msgId);
    if (typeof s === 'string') return answerFor(s);
    const { P, C, raw, menu } = s;
    if (!menu.recall) return { status: 'invalid', text: T('STR_ERR_UNDO_UNSUCCESS') };
    const cloud = ctxOf(convId).cloud;
    const items = (Array.isArray(raw.message) ? raw.message : [raw]).filter((x) => recallable(P, C, x, cloud));
    const max = num(cfg().recallMessageMaxTime);
    if (max > 0 && items.some((x) => timeNow() - num(x.sendDttm) >= max)) {
      const span = str(safe(() => mod('smi1').a.getStringTime(max / 1000), '')).trim();
      return { status: 'denied', text: T('STR_RECALL_MSG_TOAST_EXPIRED_TIME', [span]) };
    }
    const sender = safe(() => mod('dThN').default, null), ids = safe(() => mod('NMlV').a, null), storage = safe(() => mod('XS0u').default, null);
    if (!fn(sender, 'undoMessage') || !fn(ids, 'next')) return { status: 'not-ready' };
    for (const x of items) {
      try {
        const e2ee = safe(() => mod('sg3c').f(x), -1) === C.MSG_E2EE;
        await withTimeout(sender.undoMessage(x.msgId, x.toUid, ids.next(), x.cliMsgId, e2ee), 30000);
        if (x.staredDttm && fn(storage, 'unstaredMessages')) Promise.resolve(storage.unstaredMessages([x])).catch(() => {});
      } catch (e) {
        if (isTimeout(e)) return { status: 'pending' };
        const code = e && e.error_code;
        diag('recall ' + scrubErr(code !== undefined ? code : e));
        if (code === undefined && e && e.code === 'ERR_NO_NETWORK') return { status: 'error', text: T('STR_CHECK_NET') };
        if (code === undefined) return { status: 'error', text: T('STR_ERR_UNDO_UNSUCCESS') };
        return { status: 'error', text: Number(code) === 211 ? T('STR_ERR_UNDO_211') : T('STR_ERR_UNDO_UNSUCCESS') + ' (' + code + ')' };
      }
    }
    return { status: 'done' };
  });

  // ---- Xóa chỉ ở phía tôi ----
  const undoIds = new Map();           // id as given to Swift → official delete id
  const cleanPreview = (C, e) => {
    if (!e || String(e.fromUid) !== '0' || e.status !== C.MSG_FAIL) return;
    safe(() => mod('jDHv').ModuleContainer.resolve(mod('yzMR').PreviewDataManager)
      .onDeleteMessage('ui', { toUid: e.toUid, msgId: e.msgId, fromUid: '0', cliMsgId: e.cliMsgId }), null);
  };
  const deleteForMe = (convId, msgId, confirmed) => scoped(convId, async () => {
    convId = String(convId);
    const s = await subject(convId, msgId);
    if (typeof s === 'string') return answerFor(s);
    const { P, C, raw, menu } = s;
    if (!menu.delete) return { status: 'invalid', text: T('STR_DELETE_MSGS_F') };
    // A single-sticker group is deleted through its sticker, as the official item does.
    const target = P.F(raw) && raw.message[0] ? raw.message[0] : raw;
    const mine = String(target.fromUid) === '0' || String(target.fromUid) === meNow();
    // Unknown config: the confirmation is asked (fail closed).
    const conf = confOk();
    if (!confirmed && mine && (!conf || conf.enable_popup_confim_del)) {
      return { status: 'confirm', title: T('STR_POPUP_DELETE_MSG_TITLE'), message: T('STR_POPUP_DELETE_MSG_DES'),
        ok: T('STR_POPUP_DELETE_MSG_BT_DEL'), cancel: T('STR_POPUP_DELETE_MSG_BT_CLOSE') };
    }
    const del = safe(() => mod('smi1').a, null), flow = mod('m89U');
    if (!fn(del, 'deleteMsgs') || !fn(flow, 'a')) return { status: 'not-ready' };
    const msgs = [target];
    safe(() => mod('Yxx+').default.disableGroupPhotoSkeleton(target), null);
    try {
      const undo = cfg().undo_delete;
      if (!(undo && undo.enable)) {
        flow.a(await withTimeout(del.deleteMsgsNotUndo(convId, msgs, false), 30000));
        cleanPreview(C, target);
        return { status: 'done' };
      }
      const o = await withTimeout(del.deleteMsgs(convId, msgs), 30000);
      if (o && o.ok) {
        const { id, msgsDel, canUndoMsgs = [], expireAt = 0 } = o.value || {};
        flow.a(msgsDel);
        cleanPreview(C, target);
        if (!canUndoMsgs.length || id === undefined || id === null) return { status: 'done' };
        undoIds.set(String(id), id);
        if (undoIds.size > 20) undoIds.delete(undoIds.keys().next().value);
        return { status: 'done', undo: { id: String(id), count: canUndoMsgs.length, ms: Math.max(0, Math.round(num(expireAt) - performance.now())) } };
      }
      if (o && o.error && o.error.name === 'CreateBackupFailed') {
        flow.a(o.error.msgsDel || []);
        cleanPreview(C, target);
        return { status: 'done' };
      }
      diag('delete ' + scrubErr(o && o.error && o.error.name));
      return { status: 'error', text: T('STR_DELETE_MSGS_F') };
    } catch (e) {
      if (isTimeout(e)) return { status: 'pending' };
      diag('delete ' + scrubErr(e));
      return { status: 'error', text: T('STR_DELETE_MSGS_F') };
    }
  });
  // "Khôi phục" of the snackbar.
  const undoDelete = async (id) => {
    const key = undoIds.get(String(id));
    if (key === undefined) return { status: 'invalid', text: T('STR_UNDO_DELETE_MSGS_F') };
    undoIds.delete(String(id));
    try {
      const ok = await withTimeout(Promise.resolve(mod('m89U').d(key)), 20000);
      return ok ? { status: 'done' } : { status: 'error', text: T('STR_UNDO_DELETE_MSGS_F') };
    } catch (e) {
      diag('undo delete ' + scrubErr(e));
      return isTimeout(e) ? { status: 'pending' } : { status: 'error', text: T('STR_UNDO_DELETE_MSGS_F') };
    } finally { core.refresh(); }
  };
  // The snackbar's close button: the official client deletes for good right away.
  const commitDelete = (id) => {
    const key = undoIds.get(String(id));
    if (key === undefined) return false;
    undoIds.delete(String(id));
    safe(() => mod('m89U').c(key), null);
    return true;
  };
  // The snackbar timed out: nothing more happens officially.
  const dropDelete = (id) => undoIds.delete(String(id));

  // ---- Đánh dấu tin nhắn ----
  const star = (convId, msgId, on) => scoped(convId, async () => {
    convId = String(convId);
    const s = await subject(convId, msgId);
    if (typeof s === 'string') return answerFor(s);
    const { P, C, raw, menu } = s;
    let items;
    if (raw.msgType === C.MSG_PHOTO_GROUP) items = raw.message.filter((x) => x && x.msgType !== C.MSG_UNDO && !P.l(x));
    else if (P.s(raw) && Array.isArray(raw.message) && raw.message.length === 1) items = [raw.message[0]];
    else items = [raw];
    const storage = safe(() => mod('XS0u').default, null), store = safe(() => mod('PoHQ').n, null), A = safe(() => mod('97kL').MessageActions, null);
    if (!fn(storage, 'addStarMessages') || !fn(store, 'dispatch') || !A) return { status: 'not-ready' };
    try {
      if (on) {
        if (menu.star === 'blocked') return { status: 'denied', text: T('STR_BLOCK_SHARING_ACTION_BLOCKED') };
        if (menu.star === 'unstar') return { status: 'done' };
        if (menu.star !== 'star') return { status: 'invalid', text: T('STR_TOAST_ERROR') };
        const now = timeNow();
        await withTimeout(storage.addStarMessages(items, now), 15000);
        safe(() => storage.shouldSaveTsStarMsgSchemaChanged(now), null);
        store.dispatch({ type: A.ADD_STAR, payload: { updateMsgs: items, staredDttm: now, conversationId: convId, fromChild: false } });
        return { status: 'done' };
      }
      if (menu.star !== 'unstar') return { status: 'done' };
      await withTimeout(storage.unstaredMessages(items), 15000);
      store.dispatch({ type: A.DELETE_STAR, payload: { updateMsgs: items, conversationId: convId } });
      return { status: 'done', text: T('STR_MSG_UNSTARRED') };
    } catch (e) {
      diag('star ' + scrubErr(e));
      return isTimeout(e) ? { status: 'pending' } : { status: 'error', text: T('STR_TOAST_ERROR') };
    }
  });

  // ---- pins: reading ----
  const ONE_ON_ONE_PIN_LIMIT = 3;      // official `openPinLimitModal` (ms ~1086842: limitNumber 3)
  const groupTopics = () => cfg().group_topics || {};
  const groupBoard = (convId) => {
    const q = safe(() => mod('jnJr').a, null);
    const b = fn(q, 'getInstance') ? safe(() => q.getInstance(convId), null) : null;
    return b && b.topicStore && fn(b.topicStore, 'getTopics') && fn(b.topicStore, 'hasGroup')
      && ['loadTopics', 'callCreateOrPinTopic', 'callUnpinTopic', 'unpinMultiTopics'].every((k) => fn(b, k)) ? b : null;
  };
  const pinManager = () => {
    const j = safe(() => mod('YYsv').j, null);
    const m = fn(j, 'GetManager') ? safe(() => j.GetManager(), null) : null;
    return m && ['loadPinTopics', 'createPinTopic', 'unpinPinTopics', 'addEventListener'].every((k) => fn(m, k))
      && safe(() => m.isEnablePinTopicOneOnOneFeature(), false) ? m : null;
  };
  const topicList = (board, convId) => { const l = safe(() => board.topicStore.getTopics(convId), []); return Array.isArray(l) ? l.filter((t) => t && typeof t === 'object') : []; };
  const boardLimit = (board) => Math.max(0, num(board && board.pinLimit) || num(groupTopics().pin_limit));
  // Board topics are read like the official client does when a group opens (`loadTopics`: DB, server when stale); bounded, retried later.
  const topicLoads = new Map();
  const ensureTopics = async (board, convId) => {
    const has = () => safe(() => board.topicStore.hasGroup(convId), false) === true;
    if (has()) return true;
    if (!topicLoads.has(convId)) {
      const p = (async () => {
        try { await withTimeout(board.loadTopics(convId), 8000); } catch (e) { diag('topics ' + scrubErr(e)); }
        await waitFor(has, 8000);
      })();
      topicLoads.set(convId, p);
      p.finally(() => setTimeout(() => { if (topicLoads.get(convId) === p) topicLoads.delete(convId); }, has() ? 0 : 15000));
    }
    await topicLoads.get(convId);
    return has();
  };
  // Pin text, as the official board labels a message topic by its client type (`msg_type`).
  const CLI_LABEL = { 31: '[Tin nhắn thoại]', 32: '[Hình ảnh]', 36: '[Sticker]', 37: '[Vẽ hình]', 43: '[Vị trí]', 44: '[Video]', 46: '[File]', 49: '[GIF]' };
  const messageTopicText = (p) => {
    const title = str(p.title).trim();
    const type = num(p.msg_type);
    if (type === 38) {
      const act = str(p.extra && p.extra.action);
      const label = act === 'recommened.link' ? '[Link]' : act === 'recommened.stickerset' ? '[Bộ sticker]' : '[Danh thiếp]';
      return title ? label + ' ' + title : label;
    }
    if (CLI_LABEL[type]) return title ? CLI_LABEL[type] + ' ' + title : CLI_LABEL[type];
    if (title) return title;
    const custom = p.extra && typeof p.extra === 'object' ? p.extra : null;
    return str(custom && custom.msg && (custom.msg.vi || custom.msg.en)) || '[Tin nhắn Media]';
  };
  const pinJSON = (C, t) => {
    const p = paramsOf(t);
    const kind = t.type === C.MSG_TOPIC ? 'message' : t.type === C.POLL_TOPIC ? 'poll' : t.type === C.REMINDER_TOPIC ? 'reminder' : t.type === C.LINK_TOPIC ? 'link' : 'note';
    let title;
    if (kind === 'message') title = messageTopicText(p);
    else if (kind === 'poll') title = str(p.question) || str(p.title);
    else if (kind === 'link') title = str(p.linkCaption) || str(p.title) || str(p.href);
    else title = str(p.title) || str(p.text);
    const uid = String(p.senderUid ?? t.creatorId ?? '');
    const sender = uid && uid === meNow() ? 'Bạn' : (uid && nameOf(uid)) || str(p.senderName);
    return { ref: topicRef(t), kind, title: title.trim().slice(0, 300), sender, thumb: absUrl(p.thumb),
      msgId: validId(p.global_msg_id) ? String(p.global_msg_id) : '', cliMsgId: validId(p.client_msg_id) ? String(p.client_msg_id) : '' };
  };
  // Reads overlap (store events, an action's own refresh); only the newest one may replace what is known (`stale` answers are dropped).
  const pinReads = new Map();          // convId → sequence of the newest read
  const readPins = async (convId) => {
    const seq = (pinReads.get(convId) || 0) + 1;
    pinReads.set(convId, seq);
    const off = { convId, ready: false, canPin: false, items: [] };
    if (!(await core.ready())) return off;
    const C = consts();
    if (!C) return off;
    const ctx = ctxOf(convId);
    let topics = null;
    if (ctx.group) {
      const board = groupTopics().enable ? groupBoard(convId) : null;
      hookTopicStore(board);
      if (board && await ensureTopics(board, convId)) topics = topicList(board, convId);
    } else if (ctx.friend) {
      const mgr = pinManager();
      hookManager(mgr);
      if (mgr) {
        try {
          const r = await withTimeout(mgr.loadPinTopics(convId), 10000);
          topics = r && Array.isArray(r.topics) ? r.topics.filter((t) => t && typeof t === 'object') : [];
        } catch (e) { diag('pins ' + scrubErr(e && (e.code !== undefined ? e.code : e))); }
      }
    }
    if (pinReads.get(convId) !== seq) return Object.assign(off, { stale: true });
    if (!topics) return off;
    pinCache.set(convId, topics);
    if (pinCache.size > 20) pinCache.delete(pinCache.keys().next().value);
    return { convId, ready: true, canPin: ctx.pinChat, items: topics.map((t) => pinJSON(C, t)) };
  };

  // ---- pins: watching the conversation on screen ----
  let watched = null, pinTimer = null;
  const lastPinSig = new Map();
  const emitPins = async (convId) => {
    const p = await readPins(convId);
    if (watched !== convId || p.stale) return;
    const sig = JSON.stringify(p);
    if (lastPinSig.get(convId) === sig) return;
    lastPinSig.set(convId, sig);
    post(p);
    core.refresh(); // the `pinned` flags of the loaded messages
  };
  const schedulePins = (convId) => {
    if (!convId || convId !== watched) return;
    clearTimeout(pinTimer);
    pinTimer = setTimeout(() => { emitPins(convId).catch((e) => diag('pins ' + scrubErr(e))); }, 300);
  };
  // One topic store is shared by every group board: its setters run for new / updated / removed pins (own and from sync).
  let hookedStore = null;
  const hookTopicStore = (board) => {
    const store = board && board.topicStore;
    if (!store || hookedStore === store) return;
    hookedStore = store;
    for (const k of ['setTopic', 'setTopics', 'removeTopic', 'resetGroup']) {
      const orig = store[k];
      if (typeof orig !== 'function' || orig.__olaz) continue;
      const wrapped = function () { const r = orig.apply(this, arguments); try { if (watched && isGroupId(watched)) schedulePins(watched); } catch {} return r; };
      wrapped.__olaz = true;
      store[k] = wrapped;
    }
  };
  let hookedManager = null;
  const hookManager = (mgr) => {
    if (!mgr || hookedManager === mgr) return;
    hookedManager = mgr;
    safe(() => mgr.addEventListener('onchange', (cid) => { if (String(cid) === watched) schedulePins(watched); }), null);
  };
  const watchPins = (convId) => {
    watched = convId ? String(convId) : null;
    clearTimeout(pinTimer);
    if (!watched) return true;
    lastPinSig.delete(watched);
    emitPins(watched).catch((e) => diag('pins ' + scrubErr(e)));
    return true;
  };

  // ---- pins: Ghim tin nhắn / Bỏ ghim ----
  // The topic the official item builds (`he` for groups, from the DB copy; `createPinTopicFromMessage` for 1:1, with its JXL handling).
  const buildTopic = (C, m, inGroup) => {
    const conf = cfg();
    const color = safe(() => conf.settings.group.topic_colors[0], undefined);
    let from = String(m.fromUid ?? '');
    if (!from || from === '0') from = meNow();
    const p = { client_msg_id: m.cliMsgId, global_msg_id: m.msgId, senderUid: from, senderName: str(m.dName) };
    const o = m.message && typeof m.message === 'object' && !Array.isArray(m.message) ? m.message : {};
    const thumbOf = () => o.thumbUrl || o.normalUrl || o.oriUrl;
    const J = inGroup ? null : ((j) => (['g', 'd', 'k', 'o', 'l', 'm'].every((k) => fn(j, k)) ? j : null))(mod('Q8nW'));
    const jxlPin = () => !!safe(() => conf.jxl && conf.jxl.enable_pin_jxl, false);
    switch (m.msgType) {
      case C.MSG_CONTACT: {
        const act = str(o.action);
        if (['recommened.link', 'recommened.user', 'recommened.stickerset', 'recommened.vip'].includes(act)) {
          p.href = o.href; p.thumb = o.thumb; p.title = o.title; p.linkCaption = o.title;
          if (act === 'recommened.link' && o.params) {
            const e = parseJSON(o.params);
            if (!p.title && e.mediaTitle) p.title = e.mediaTitle;
            p.redirect_url = e.redirect_url || ''; p.streamUrl = e.streamUrl || ''; p.artist = e.artist || ''; p.stream_icon = e.stream_icon || ''; p.type = e.type || '';
          }
        }
        p.extra = { action: act };
        if (act === 'recommened.user') p.extra.dpn = p.title;
        else if (act === 'recommened.link' && o.params) p.extra.params = o.params;
        p.msg_type = C.CLI_MSG_TYPE_CONTACT;
        break;
      }
      case C.MSG_TEXT:
        if (typeof m.message === 'string') p.title = m.message; else if (o.title) p.title = o.title;
        p.msg_type = C.CLI_MSG_TYPE_TEXT;
        break;
      case C.MSG_DOODLE:
        p.thumb = thumbOf(); p.title = o.title; p.msg_type = C.CLI_MSG_TYPE_DOODLE;
        break;
      case C.MSG_PHOTO: {
        let thumb = thumbOf();
        const isJxl = !!J && !!thumb && safe(() => !!J.g(thumb), false);
        if (isJxl) {
          if (safe(() => !!J.d(thumb), false) || jxlPin()) thumb = safe(() => J.k(thumb), thumb);
          else { thumb = safe(() => J.o(thumb), thumb); p.convertible = 'jxl'; }
        }
        p.thumb = thumb; p.title = o.title; p.msg_type = C.CLI_MSG_TYPE_PHOTO;
        if (m.properties && m.properties.type === C.MSG_BUBBLE_LAYOUT_TYPE_NO_BORDER) {
          const extra = { msgBubbleLayoutType: C.MSG_BUBBLE_LAYOUT_TYPE_NO_BORDER, pStickerType: 0 };
          const raw = o.params;
          let t = null;
          if (typeof raw === 'string') { const v = parseJSON(raw); t = Object.keys(v).length ? v : null; } else if (raw && raw.webp) t = raw;
          if (t) {
            if (isJxl) {
              if (safe(() => !!J.d(o.thumbUrl || o.normalUrl || o.oriUrl), false) || jxlPin()) t = safe(() => J.l(t), t);
              else { t = safe(() => J.m(t), t); p.convertible = 'jxl'; }
            }
            extra.webpUrl = (t.webp && t.webp.url) || ''; extra.subType = 1; extra.pStickerType = t.pStickerType ?? 0;
          }
          p.extra = extra;
        }
        break;
      }
      case C.MSG_FILE:
        p.title = o.title; p.extra = o.params; p.msg_type = C.CLI_MSG_TYPE_FILE;
        break;
      case C.MSG_GIF:
        p.thumb = thumbOf(); p.msg_type = C.CLI_MSG_TYPE_GIF;
        break;
      case C.MSG_STICKER:
        p.extra = m.message; p.msg_type = C.CLI_MSG_TYPE_STICKER;
        break;
      case C.MSG_VOICE:
        p.msg_type = C.CLI_MSG_TYPE_VOICE;
        break;
      case C.MSG_LOCATION:
        p.msg_type = C.CLI_MSG_TYPE_LOCATION; p.title = o.title || o.desc;
        break;
      case C.MSG_VIDEO:
        p.msg_type = C.CLI_MSG_TYPE_VIDEO; p.thumb = thumbOf(); p.title = o.title;
        break;
      case C.MSG_ZINSTANT: case C.MSG_ZINSTANT_V2: case C.MSG_ZINSTANT_OLD: {
        const meta = safe(() => { const Z = mod('RoG4').h; return Z.create(new Z.Adapters.MessageEntity(m)).getZInstantMetadata(); }, null);
        p.msg_type = !inGroup && m.msgType === C.MSG_ZINSTANT_OLD ? C.MSG_ZINSTANT : m.msgType;
        if (meta && meta.customMsg) p.extra = Object.assign({}, meta.customMsg);
        break;
      }
      default:
        p.msg_type = m.msgType;
    }
    const emoji = safe(() => mod('z0WU').default.getUnicodeCorrMSGType(m), '');
    return inGroup
      ? { type: C.MSG_TOPIC, color, emoji, startTime: -1, duration: -1, params: p, pinAct: 1, isCreated: true }
      : { color, duration: -1, emoji, params: p, repeat: 0, startTime: -1, type: C.MSG_TOPIC };
  };
  // The official "Cập nhật danh sách ghim" dialog, asked natively: the oldest pin goes to make room.
  const confirmReplace = (C, oldest, limit) => {
    const item = pinJSON(C, oldest);
    const label = { message: 'Tin nhắn', poll: 'Bình chọn', reminder: 'Nhắc hẹn', note: 'Ghi chú', link: 'Liên kết' }[item.kind] || 'Ghim';
    return {
      status: 'confirm', ref: item.ref, title: T('STR_CONFIRM_PIN'),
      message: [limit > 0 ? T('STR_ONLY_PIN_MAX_CONTENT', [String(limit)]) : '', T('STR_CONTENT_WILL_BE_REMOVED_FROM_PIN_TOPICS') + ':', label + (item.title ? ': ' + item.title : '')].filter(Boolean).join('\n'),
      ok: T('STR_CONFIRM'), cancel: T('STR_CANCEL'),
    };
  };
  const pinFailText = (e, convId) => {
    const codes = safe(() => mod('YYsv').c, {}) || {};
    if (e && e.code === codes.FULL_THREAD_PIN_TOPIC && !e.message) return T('STR_PIN_FRIEND_REACH_PIN_LIMIT', [nameOf(convId) || '']);
    if (e && typeof e.message === 'string' && /^STR?_/.test(e.message)) return T(e.message) || T('STR_PIN_GENERAL_ERROR');
    return T('STR_ERROR_INFO_MSG_PIN_MESSAGE');
  };
  const pinInGroup = async (C, convId, msg, confirmRef) => {
    const board = groupTopics().enable ? groupBoard(convId) : null;
    if (!board || !(await ensureTopics(board, convId))) return { status: 'error', text: T('STR_ERROR_INFO_MSG_PIN_MESSAGE') };
    hookTopicStore(board);
    const db = await Promise.resolve(safe(() => mod('XS0u').default.getMessage(msg.msgId, msg.toUid), null)).catch(() => null);
    if (!db) return { status: 'error', text: T('STR_MESSAGE_NOT_FOUND') };
    if (db.msgType === C.MSG_UNDO) return { status: 'denied', text: T('STR_TOAST_UNDO_MESSAGE') };
    const topics = topicList(board, convId);
    if (topics.some((t) => topicIsMessage(C, t, db))) return { status: 'done' };
    const limit = boardLimit(board);
    let oldest = null;
    if (groupTopics().enable_pin_limit && limit > 0 && topics.length >= limit) {
      // The official dialog lets the user choose several pins when more than one has to go: not offered here.
      if (topics.length - limit + 1 > 1) return { status: 'denied', text: T('STR_ONLY_PIN_MAX_CONTENT', [String(limit)]) };
      oldest = topics[topics.length - 1];
      if (str(confirmRef) !== topicRef(oldest)) return confirmReplace(C, oldest, limit);
    }
    if (oldest) {
      // The official confirm pins right after `unpinMultiTopics` resolves (the board itself changes only when the sync event lands). It
      // may not settle on a server error: then the board decides — gone = go on; a definite error = that error; no answer = unknown.
      const gone = () => !topicList(board, convId).some((t) => topicRef(t) === topicRef(oldest));
      let failed = null;
      try { await withTimeout(board.unpinMultiTopics(convId, [oldest]), 20000); } catch (e) { failed = e; }
      if (failed && !gone() && !(await waitFor(gone, 4000))) return isTimeout(failed) ? { status: 'pending' } : { status: 'error', text: T('STR_PIN_GENERAL_ERROR') };
    }
    const topic = buildTopic(C, db, true);
    const sent = await new Promise((resolve) => {
      let settled = false;
      const done = (v) => { if (!settled) { settled = true; resolve(v); } };
      const entry = safe(() => mod('YYsv').b.CONTEXT_MENU, 1);
      try { board.callCreateOrPinTopic(convId, topic, null, () => done({ ok: true }), (e) => done({ ok: false, e }), entry); } catch (e) { done({ ok: false, e }); }
      setTimeout(() => done({ ok: false, late: true }), 20000);
    });
    const there = () => topicList(board, convId).some((t) => topicIsMessage(C, t, db));
    if (sent.ok || await waitFor(there, sent.late ? 6000 : 2500)) { schedulePins(convId); return { status: 'done' }; }
    if (sent.e) diag('pin ' + scrubErr(sent.e.error_code !== undefined ? sent.e.error_code : sent.e));
    return sent.late ? { status: 'pending' } : { status: 'error', text: T('STR_ERROR_INFO_MSG_PIN_MESSAGE') };
  };
  const pinOneOnOne = async (C, convId, msg, confirmRef) => {
    const mgr = pinManager();
    if (!mgr) return { status: 'error', text: T('STR_ERROR_INFO_MSG_PIN_MESSAGE') };
    hookManager(mgr);
    const codes = safe(() => mod('YYsv').c, {}) || {};
    // A full board makes the manager raise "onexceed", whose listener opens the official PIN_LIMIT_MODAL (limit 3, ms ~1086842) in the
    // hidden page: the limit is checked here first so the replace question is asked natively instead.
    let topics = [];
    try {
      const r = await withTimeout(mgr.loadPinTopics(convId), 10000);
      topics = r && Array.isArray(r.topics) ? r.topics.filter((t) => t && typeof t === 'object') : [];
    } catch (e) { diag('pin 1:1 topics ' + scrubErr(e && (e.code !== undefined ? e.code : e))); }
    pinCache.set(convId, topics);
    if (!confirmRef && topics.length >= ONE_ON_ONE_PIN_LIMIT) return confirmReplace(C, topics[topics.length - 1], ONE_ON_ONE_PIN_LIMIT);
    if (confirmRef) {
      // The user agreed to drop this pin to make room.
      const oldest = topics.find((t) => topicRef(t) === String(confirmRef));
      if (oldest) {
        try { await withTimeout(mgr.unpinPinTopics(convId, [oldest]), 20000); } catch (e) {
          if (isTimeout(e)) return { status: 'pending' };
          return { status: 'error', text: pinFailText(e, convId) };
        }
      }
    }
    try {
      await withTimeout(mgr.createPinTopic(convId, buildTopic(C, msg, false)), 30000);
      schedulePins(convId);
      return { status: 'done' };
    } catch (e) {
      if (isTimeout(e)) return { status: 'pending' };
      diag('pin 1:1 ' + scrubErr(e && (e.code !== undefined ? e.code : e)));
      if (e && e.code === codes.PINBOARD_OVER_MAXIMUM) {
        closePinLimitModal();
        const full = e.data && e.data.cache && Array.isArray(e.data.cache.topics) ? e.data.cache.topics.filter((t) => t && typeof t === 'object') : [];
        const oldest = full[full.length - 1];
        if (oldest && !confirmRef) { pinCache.set(convId, full); return confirmReplace(C, oldest, full.length); }
        return { status: 'denied', text: T('STR_ONLY_PIN_MAX_CONTENT', [String(full.length || ONE_ON_ONE_PIN_LIMIT)]) };
      }
      return { status: 'error', text: pinFailText(e, convId) };
    }
  };
  // The official 1:1 limit dialog, should the manager still have opened it (the board filled up meanwhile).
  const closePinLimitModal = () => safe(() => {
    const name = mod('1pet').ModalIdentitiesDefine.PIN_LIMIT_MODAL;
    const modals = mod('h0sc').ModalManagerV2;
    if (name && fn(modals, 'closeModal')) modals.closeModal({ windowId: safe(() => mod('3xbP').c, '1'), name });
  }, null);
  const pin = (convId, msgId, confirmRef) => scoped(convId, async () => {
    convId = String(convId);
    const s = await subject(convId, msgId);
    if (typeof s === 'string') return answerFor(s);
    const { P, C, raw, menu } = s;
    if (!menu.pin) return { status: 'denied', text: ctxOf(convId).group ? T('STE_ADMIN_UPDATE_TOPIC') : T('STR_ERROR_INFO_MSG_PIN_MESSAGE') };
    if (menu.pinned) return { status: 'done' };
    const msg = P.s(raw) ? raw.message[0] : raw;   // a single-sticker group pins its sticker
    return ctxOf(convId).group ? pinInGroup(C, convId, msg, confirmRef) : pinOneOnOne(C, convId, msg, confirmRef);
  });
  const unpin = (convId, ref) => scoped(convId, async () => {
    convId = String(convId);
    if (!(await core.ready())) return { status: 'not-ready' };
    const ctx = ctxOf(convId);
    if (!ctx.pinChat) return { status: 'denied', text: ctx.group ? T('STE_ADMIN_UPDATE_TOPIC') : T('STR_PIN_GENERAL_ERROR') };
    const topic = (pinCache.get(convId) || []).find((t) => topicRef(t) === String(ref));
    if (!topic) { schedulePins(convId); return { status: 'done' }; }
    try {
      if (ctx.group) {
        const board = groupBoard(convId);
        if (!board) return { status: 'error', text: T('STR_PIN_GENERAL_ERROR') };
        const gone = () => !topicList(board, convId).some((t) => topicRef(t) === String(ref));
        try { await withTimeout(board.callUnpinTopic(convId, { id: topic.id, type: topic.type }), 20000); } catch (e) {
          if (!(await waitFor(gone, isTimeout(e) ? 6000 : 2000))) return isTimeout(e) ? { status: 'pending' } : { status: 'error', text: T('STR_PIN_GENERAL_ERROR') };
        }
      } else {
        const mgr = pinManager();
        if (!mgr) return { status: 'error', text: T('STR_PIN_GENERAL_ERROR') };
        await withTimeout(mgr.unpinPinTopics(convId, [topic]), 20000);
      }
    } catch (e) {
      diag('unpin ' + scrubErr(e && (e.code !== undefined ? e.code : e)));
      return isTimeout(e) ? { status: 'pending' } : { status: 'error', text: pinFailText(e, convId) };
    }
    schedulePins(convId);
    return { status: 'done' };
  });

  // "Chặn chia sẻ" read now (not from the memo `describe` uses): native Copy asks before writing the pasteboard.
  const isProtected = async (convId) => {
    convId = String(convId);
    if (!(await core.ready())) return true;   // unknown → protected (fail closed)
    ctxCache.delete(convId);
    return !!ctxOf(convId).protected;
  };

  // New session: nothing read for the previous account is kept.
  const reset = () => { pinCache.clear(); lastPinSig.clear(); pinReads.clear(); topicLoads.clear(); undoIds.clear(); ctxCache.clear(); watched = null; return true; };

  window.__zaloMsgActions = {
    describe, forward, recall, deleteForMe, undoDelete, commitDelete, dropDelete, star, isProtected,
    watchPins, pins: (convId) => readPins(String(convId)), pin, unpin, reset,
  };
})();
