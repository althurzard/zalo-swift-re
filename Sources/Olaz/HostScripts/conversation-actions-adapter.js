// Olaz conversation-actions adapter (index.html only): the official conversation context menu
// ("Ghim / Bỏ ghim hội thoại", "Chuyển sang mục Khác / Ưu tiên", "Đánh dấu đã đọc / chưa đọc", "Ẩn / Bỏ ẩn trò chuyện",
// "Xóa hội thoại") and the hidden-chat PIN. Posts {page:'main', convActions:{…}} via `zstate`; Swift calls
// `window.__zaloConvActions` and awaits the promises (same shape as card-actions-adapter.js: every action answers
// {ok, text, …} with the official toast text).
//
// Menu class `ae` (module "z/gZ", lazy bundle ~16274997–16296500; presets X: `Thread` = sidebar row, `ChatBox` = chat header,
// which has no archive / mark-read / delete items). Everything below calls the service the official item calls:
//
//   pin / unpin     `_pinMe` ~16284000 / `_unpinMe`: DI singleton PinDataManager (main-startup ~571720): `pin([id])`, `unpin([id])`, `isPinned`,
//                   `getTotalPinnedConversation(tab)` / `getLimitPinnedConversation(tab)`; tab = archived chat (enable_archived_chat) ? 1 : 0.
//                   Full tab → modal POP_PINNED_CONVERSATION (module "ymNP" ~16254500): `pinBoard` lists the pins, `pinReplacing` runs the modal's
//                   confirm (`unpin(listUnpin)` then `pin([id])`). Toasts STR_PIN_SUCESS / STR_UNPIN_SUCCESS. Eligibility = render() ~16290700.
//   archive         `_moveArchivedChat` / `_removeArchivedChat` ~16287800: archived-chat service (module "FEfs" ~4463000) `moveToArchivedChat(id, cb)` /
//                   `removeFromArchivedChat(id, cb)` (cb only fires on success), then DI ArchivedChatManager `onUpdateListArchivedChat(id)`;
//                   moving to "Khác" also unpins. Toasts STR_TOAST_MOVE_ARCHIVED_CHAT / STR_TOAST_MOVE_FOCUS.
//   delete          `_deleteConversation` → ConvListController.deleteConversation(id, needConfirm, isLeave) (main-startup ~301521) whose confirm
//                   (delete-manager ~17194898: STR_CONV_DEL_CONFIRM_L_1/_L_2, STR_CONFIRM_YES danger) is rebuilt natively; `delete` then runs what its
//                   OK runs: delete-manager `deleteConversation(id, false, undefined, isLeave)` + `TAG_CONV` label clear. A left / kicked group
//                   (`getLeaveType`) deletes with the force flag, like the official `_deleteConversation(e, true)`.
//   mark read       `markAsRead` ~16275977 dispatches MARK_AS_READ; the handler (chat-box controller `readMessageOfConvListByID` ~4183430, which does
//                   not use `this`) is `UnreadDataManager.onClearUnreadConversations(list)` + the reaction manager's `clearUnreadIfExist(item)`.
//   mark unread     `markUnread` ~16275400 → mark-unread manager (module "PGx3" ~7197367) `markUnread(conv)`; errors: 277 → STR_MARK_UNREAD_LIMIT.
//   hide / unhide   `_hideConversation` ~16278000 + modal HIDDEN_CHAT (module ~12600465): hidden-chat manager (class K ~4046000, singleton found by
//                   `isKeyPIN`/`changePIN`): `updateStateItemHiddenChat(id, bool)`, `changePIN(pin)`, `resetPIN()`, `isKeyPIN(pin)` (md5 of the
//                   4 digits against the stored hash — the PIN only ever goes into those calls and is never logged or kept here),
//                   `getUidsHiddenChat()` (sidebar search: a query that is the PIN lists the hidden chats, main-startup ~364562).
//
// Swift → JS : pin(id) unpin(id) pinBoard(id) pinReplacing(unpinIds, id) · archive(id) unarchive(id) · deleteConversation(id)
//              markRead(id) markUnread(id) · hide(id, pin) hideWithNewPin(id, pin) unhide(id, pin|null) · checkPin(pin) hiddenSearch(query)
//              setPin(pin, changed) resetPin()
// JS → Swift (`zstate`): {page:'main', convActions:{…}}. Two shapes: `{hidden:{enabled, hasPin, ids}}` as soon as the hidden-chat manager
//              resolves (so hidden chats are never shown before their state is known), and the full snapshot
//              `{flags:{id:bits}, left:{id:'kick'|'disband'}, hidden:{…}, markUnread, late?}`. `late` = the outcome of an archive / delete that
//              answered "pending" (slow server) when it finally completes: {seq, ok, text, neutral?, removedId?}.
// Publishing is event-driven (PinDataManager ChangePinConv, ArchivedChatManager, UnreadDataManager, bus UPDATE_HIDDEN_CHAT …), debounced,
// with a slow fallback timer; identical snapshots are never re-posted.
(() => {
  'use strict';
  if (!/index\.html$/.test(location.pathname)) return;
  if (window.__zaloConvActions) return;
  const post = (state) => { try { window.webkit.messageHandlers.zstate.postMessage(state); } catch {} };
  const diag = (s) => { try { window.webkit.messageHandlers.zlog.postMessage('[convactions] ' + s); } catch {} };
  const safe = (fn, d) => { try { const v = fn(); return v === undefined ? d : v; } catch { return d; } };
  const own = (o, k) => Object.prototype.hasOwnProperty.call(o, k);
  // Lazy-loading module wrappers are catch-all Proxies; only accept real APIs (same probe as notification-adapter).
  const real = (ex) => { try { return !!ex && ex.__olaz_probe__ === undefined; } catch { return false; } };

  // Flag bits of `flags[id]` (published only when non-zero); keep in sync with ConversationActionFlags in ZaloEngine+ConversationActions.swift.
  const F = { PINNED: 1, ARCHIVED: 2, HIDDEN: 4, CANNOT_PIN: 8, CANNOT_ARCHIVE: 16, CANNOT_MUTE: 32, CANNOT_DELETE: 64, NO_PIN_MENU: 128, CANNOT_HIDE: 256, UNREAD_MARK: 512 };
  const GROUP_PREFIX = 'g';
  const STRANGER_BOX = 'stranger_box';
  const TEXT = {
    pinOk: 'Ghim hội thoại thành công',                    // STR_PIN_SUCESS
    unpinOk: 'Bỏ ghim hội thoại thành công',               // STR_UNPIN_SUCCESS
    pinFail: 'Ghim hội thoại không thành công. Vui lòng thử lại.',   // STR_ERR_PIN_CONVERSATION
    unpinFail: 'Bỏ ghim hội thoại không thành công. Vui lòng thử lại.',
    toOther: 'Đã chuyển sang mục Khác',                    // STR_TOAST_MOVE_ARCHIVED_CHAT
    toFocus: 'Đã chuyển sang Tin nhắn',                       // STR_TOAST_MOVE_FOCUS, worded for Olaz's "Tin nhắn" list
    generic: 'Đã có lỗi xảy ra, vui lòng thử lại',         // STR_ERROR_OCCURED_FOLDER_VIEW
    markLimit: 'Số lượng hội thoại có thể đánh dấu chưa đọc đã vượt giới hạn',   // STR_MARK_UNREAD_LIMIT
    notReady: 'Ứng dụng chưa sẵn sàng, hãy thử lại sau giây lát.',
    busy: 'Thao tác trước đó vẫn đang được xử lý.',
    noReply: 'Chưa nhận được phản hồi. Hãy kiểm tra lại danh sách hội thoại trước khi thử lại.',
    hiddenOk: (name) => 'Trò chuyện "' + name + '" đã được ẩn thành công',     // STR_TOAST_HIDDEN_SUCCESS
    hideFail: (name) => 'Ẩn trò chuyện với ' + name + ' không thành công',     // STR_HIDDEN_CHAT_TOAST_HIDE_FAIL
    unhideOk: 'Bỏ ẩn trò chuyện thành công',               // STR_TOAST_POPUP_HIDDEN_UNHIDE_SUCCESS
    unhideFail: 'Bỏ ẩn trò chuyện KHÔNG thành công',       // STR_TOAST_POPUP_HIDDEN_UNHIDE_FAIL
    pinWrong: 'Mã PIN không đúng. Vui lòng thử lại.',      // STR_ERROR_POPUP_HIDDEN_ENTER_PIN_INCORRECT
    pinChangeOk: 'Đổi mã PIN thành công',                  // STR_TOAST_POPUP_HIDDEN_CHANGE_PIN_SUCCESS
    pinResetOk: 'Đã xóa thành công mã PIN và các trò chuyện ẩn',   // STR_TOAST_POPUP_HIDDEN_REMOVE_PIN_SUCCESS
    noNetwork: 'Không có kết nối. Vui lòng thử lại sau',   // STR_ERROR_POPUP_HIDDEN_NO_NETWORK
    pinFailCode: (code) => 'Có lỗi trong quá trình thay đổi mã PIN. Vui lòng thử lại (' + code + ')',   // STR_ERROR_POPUP_HIDDEN_CONFIRM_PIN_FAIL
  };

  // ---- official services ----
  const X = { actions: null, pin: null, archMgr: null, convInfo: null, preview: null, unread: null, io: null, friends: null, groups: null,
    cfg: null, archive: null, hidden: null, storage: null, delMgr: null, mark: null, react: null, pinOA: null, bus: null };
  let lastResolve = 0, scans = 0, loadingModules = false;
  const startedAt = Date.now();
  let warnedHidden = false;
  const REQUIRED = ['pin', 'archMgr', 'convInfo', 'preview', 'unread', 'friends', 'cfg', 'archive', 'hidden', 'storage'];
  const ready = () => REQUIRED.every((k) => X[k]);
  const resolve = () => {
    const req = window.__zaloRequire;
    if (!req || typeof window.__zaloDI !== 'function' || typeof window.__zaloEachExport !== 'function') return ready();
    if (ready() && X.groups && X.mark && X.react && X.delMgr && X.bus && X.actions) return true;
    // Services that never match must not keep a full DI / module scan running every second: 1 s for the first 60 scans, then 5 s while
    // the hidden-chat manager (which gates the whole snapshot) is still missing, then 30 s. An explicit action rescans at once (`need`).
    if (Date.now() - lastResolve < (scans <= 60 ? 1000 : !X.hidden && scans <= 120 ? 5000 : 30000)) return ready();
    lastResolve = Date.now(); scans++;
    safe(() => { for (const reg of window.__zaloDI(req)) {
      const i = reg && reg.instance;
      if (!i || typeof i !== 'object' || !real(i)) continue;
      try {
        if (!X.pin && typeof i.getLimitPinnedConversation === 'function' && typeof i.getTotalPinnedConversation === 'function' && typeof i.pin === 'function') X.pin = i;
        if (!X.archMgr && typeof i.onUpdateListArchivedChat === 'function' && typeof i.onOffArchivedChat === 'function') X.archMgr = i;
        if (!X.convInfo && typeof i.getLeaveType === 'function' && typeof i.getConvByIdSync === 'function' && i.data instanceof Map) X.convInfo = i;
        if (!X.preview && typeof i.getPreviewByIDSync === 'function') X.preview = i;
        if (!X.unread && typeof i.getUnreadByConvIdSync === 'function' && typeof i.onClearUnreadConversations === 'function') X.unread = i;
        if (!X.io && typeof i.getFriendManagerModule === 'function') X.io = i;
      } catch {}
    } }, null);
    safe(() => window.__zaloEachExport(req, (ex) => {
      if (!ex || (typeof ex !== 'object' && typeof ex !== 'function') || ex === window.$capp || !real(ex)) return;
      try {
        for (const o of [ex, ex.default, ex.a]) {
          if (!o || (typeof o !== 'object' && typeof o !== 'function') || !real(o)) continue;
          if (!X.archive && typeof o.moveToArchivedChat === 'function' && typeof o.isArchivedChat === 'function' && Array.isArray(o.listArchivedChat)) X.archive = o;
          if (!X.hidden && typeof o.isKeyPIN === 'function' && typeof o.changePIN === 'function' && typeof o.isThreadHidden === 'function') X.hidden = o;
          if (!X.storage && typeof o.removeCollapseBannerMuted === 'function' && typeof o.getConvUXVersion === 'function') X.storage = o;
          if (!X.delMgr && typeof o.deleteConversation === 'function' && Function.prototype.toString.call(o.deleteConversation).includes('delete-manager')) X.delMgr = o;
          if (!X.cfg && o.pin_setting && own(o, 'sendToMeId')) X.cfg = o;
          if (!X.friends && typeof o.getProfileFriendByIdSync === 'function' && typeof o.isMeBAAccount === 'function') X.friends = o;
          // Reaction manager (`ie.a` of readMessageOfConvListByID): clearUnreadIfExist(item).
          if (!X.react && typeof o.clearUnreadIfExist === 'function' && typeof o.sendClearUnread === 'function') X.react = o;
          // Action-type tables: numeric ids (`GeneralActions = i({…})`, bundle ~3106699), not the key names.
          if (!X.actions && o.GeneralActions && typeof o.GeneralActions === 'object' && real(o.GeneralActions) && typeof o.GeneralActions.UPDATE_HIDDEN_CHAT === 'number'
            && o.ConversationListActions && typeof o.ConversationListActions.DEL_ALL_CONVERSATION_HIDDEN === 'number') X.actions = o;
          // Event bus (module "Ydol"): subscribe(fn(type, payload)).
          if (!X.bus && typeof o.subscribe === 'function' && typeof o.send === 'function' && typeof o.unsubscribe === 'function' && typeof o.emit === 'function') X.bus = o;
          if (!X.pinOA && typeof o.GetConfig === 'function') { const g = safe(() => o.GetConfig(), null); if (g && typeof g.isEnabledPinOA === 'function') X.pinOA = g; }
        }
        // mark-unread module: `d` = markUnread(conv).
        if (!X.mark && typeof ex.d === 'function' && typeof ex.a === 'function' && typeof ex.c === 'function' && typeof ex.e === 'function') {
          const s = Function.prototype.toString.call(ex.d);
          if (s.length < 160 && s.includes('.markUnread(')) X.mark = ex;
        }
      } catch {}
    }), null);
    if (!X.hidden && !warnedHidden && Date.now() - startedAt > 20000) { warnedHidden = true; diag('hidden manager not found'); }
    if (!X.groups && X.io && !loadingModules) {
      loadingModules = true;
      Promise.resolve(X.io.getGroupManagerModule()).then((g) => { X.groups = (g && g.default) || g; }).catch(() => { loadingModules = false; });
    }
    return ready();
  };

  const selfId = () => String((X.cfg && X.cfg.sendToMeId) || '');
  const isGroupId = (id) => String(id).startsWith(GROUP_PREFIX);
  const nameOf = (id) => String(safe(() => (isGroupId(id) ? X.groups.getDName(id) : X.friends.getDName(id)), '') || '');

  // ---- per-conversation facts (render() of the menu, ~16289500) ----
  const context = () => {
    const archiveOn = !!safe(() => X.archive.isEnableArchivedChat(), false);
    // O(m) over the archived list: the same match `isArchivedChat` makes (group entries carry the id without its "g"; hidden chats never count).
    const archived = new Set();
    if (archiveOn) {
      for (const e of safe(() => X.archive.listArchivedChat, []) || []) {
        const id = e && (Number(e.type) === 1 ? GROUP_PREFIX + e.id : String(e.id));
        if (id && !safe(() => X.hidden.isThreadHidden(id), false)) archived.add(id);
      }
    }
    return {
      archiveOn, archived, self: selfId(),
      uxV3: String(safe(() => X.storage.getConvUXVersion(), '')) === '3',
      pinOther: !!safe(() => X.pin.isEnablePinOtherTab(), false),
      baAccount: !!safe(() => X.friends.isMeBAAccount(), false),
      pinOAOn: !!safe(() => X.pinOA && X.pinOA.isEnabledPinOA(), false),
      systemicOA: safe(() => X.cfg.profile.common.systemic_oa_ids, []) || [],
    };
  };
  const flagsFor = (id, rec, ctx) => {
    let bits = 0;
    const group = isGroupId(id), self = id === ctx.self;
    const hidden = !!safe(() => X.hidden.isThreadHidden(id), false);
    const archived = ctx.archived.has(id);
    const profile = group ? {} : (safe(() => X.friends.getProfileFriendByIdSync(id), null) || {});
    const isFr = !!profile.isFr, isOA = !group && Number(profile.type) >= 1;
    if (safe(() => X.pin.isPinned(id), false)) bits |= F.PINNED;
    if (archived) bits |= F.ARCHIVED;
    if (hidden) bits |= F.HIDDEN;
    // Pin: `lastMessage` is the conversation preview's message (menu enrichment in showConvActionMenu).
    const last = !!safe(() => { const p = X.preview.getPreviewByIDSync(id); return p && p.message; }, false);
    let canPin = false;
    if (self) canPin = true;
    else if (last) {
      canPin = group || isFr || isOA;
      if (isOA && (!ctx.pinOAOn || (profile.oaInfo && profile.oaInfo.group_msg === 1))) canPin = false;
    }
    if (!canPin || hidden) bits |= F.CANNOT_PIN;
    if (archived && !ctx.pinOther) bits |= F.NO_PIN_MENU;
    // Archive: stranger-box conversations can't be moved (isInStrangerBox ~16288300); CONV_OT_STATE.none = 0.
    const outside = rec && rec.outside && rec.outside !== 0;
    const inStrangerBox = !outside && !(isOA || group || (rec && rec.respondedByMe) || isFr);
    if (!(ctx.uxV3 && ctx.archiveOn && !hidden && (group || !inStrangerBox || ctx.baAccount || archived))) bits |= F.CANNOT_ARCHIVE;
    // Mute: not for My Cloud, nor for systemic OAs (K.c(globalId)).
    if (self || (profile.globalId && ctx.systemicOA.includes(profile.globalId))) bits |= F.CANNOT_MUTE;
    if (self) bits |= F.CANNOT_DELETE;                               // CONVERSATION_TYPE.CLOUD
    if (isOA || self) bits |= F.CANNOT_HIDE;
    if (safe(() => { const u = X.unread.getUnreadByConvIdSync(id); return u && u.unreadMark; }, false)) bits |= F.UNREAD_MARK;
    return bits;
  };

  // ---- snapshot ----
  let lastKey = '', lateSeq = 0, late = null;
  const EPOCH = Date.now();   // per page: a reloaded page restarts `late.seq`, Swift accepts a new epoch
  const hiddenSnapshot = () => {
    const enabled = !!safe(() => X.hidden.enableHiddenChat(), false);
    return { enabled, hasPin: !!safe(() => X.hidden.getPIN(), false), ids: enabled ? (safe(() => X.hidden.getUidsHiddenChat(), []) || []).map(String) : [] };
  };
  // The hidden-chat state is only trustworthy once the manager's store exists (it needs the user id: before that `getUidsHiddenChat()` is null and
  // `getPIN()` ""), the remote config is decided (`enable_hidden_chat` -1 = not yet) and, when the feature is on, the list has been loaded from the
  // server (`_handleSucess` ran) or an earlier session saved the config (`init()` then skips the fetch and the persisted ids are authoritative).
  let hiddenFetched = false, hiddenFetchTries = 0, hiddenFetchNext = 0, patchedHidden = false;
  const hiddenStored = () => {
    try { for (let i = 0; i < localStorage.length; i++) { const k = localStorage.key(i); if (k && k.endsWith('data_config_hidden_chat')) return true; } } catch {}
    return false;
  };
  const hiddenLoaded = () => {
    if (!X.hidden) return false;
    if (!patchedHidden && typeof X.hidden._handleSucess === 'function') {
      patchedHidden = true;
      const original = X.hidden._handleSucess;
      X.hidden._handleSucess = function (...args) { try { return original.apply(this, args); } finally { hiddenFetched = true; schedule(100); } };
    }
    if (!Array.isArray(safe(() => X.hidden.getUidsHiddenChat(), null))) return false;     // no store yet
    const raw = safe(() => X.cfg && X.cfg.enable_hidden_chat, undefined);
    if (raw === undefined || raw === -1) return false;                                   // config not received
    if (!raw) return true;                                                               // feature off
    if (hiddenFetched || hiddenStored()) return true;
    // Feature on but the list was never fetched on this Mac: ask for it (official `forceGetListHiddenChat`, a read). A fetch that failed
    // (no `_handleSucess` yet) is asked again with backoff: 10 s, 20 s, 40 s … capped at 5 min.
    if (Date.now() >= hiddenFetchNext && typeof X.hidden.forceGetListHiddenChat === 'function') {
      hiddenFetchTries++;
      hiddenFetchNext = Date.now() + Math.min(300000, 10000 * 2 ** Math.min(hiddenFetchTries - 1, 5));
      if (hiddenFetchTries > 1) diag('hidden list fetch retry ' + hiddenFetchTries);
      Promise.resolve(safe(() => X.hidden.forceGetListHiddenChat(), null))
        .catch((e) => diag('hidden list fetch failed: ' + (e && e.message ? 'error' : typeof e)));
    }
    return false;
  };
  const snapshot = () => {
    const ctx = context();
    const flags = {}, left = {};
    for (const [rawId, rec] of X.convInfo.data) {
      const id = String(rawId);
      const bits = flagsFor(id, rec, ctx);
      if (bits) flags[id] = bits;
      const leave = safe(() => X.convInfo.getLeaveType(rec), undefined);
      if (leave) left[id] = String(leave);
    }
    return { epoch: EPOCH, flags, left, hidden: hiddenSnapshot(), markUnread: !!safe(() => X.cfg.mark_unread.enable, false), late };
  };
  const publish = () => {
    resolve();
    hookEvents();
    if (!hiddenLoaded()) return;             // unknown stays unknown: Swift keeps everything locked
    let snap;
    try { snap = ready() ? snapshot() : { epoch: EPOCH, hidden: hiddenSnapshot() }; }
    catch (e) {
      diag('snapshot failed: ' + (e && e.name ? e.name : typeof e));
      // A broken full snapshot must not leave the app waiting on the hidden state.
      try { snap = { epoch: EPOCH, hidden: hiddenSnapshot() }; } catch { return; }
    }
    const key = JSON.stringify(snap);
    if (key === lastKey) return;
    lastKey = key;
    post({ page: 'main', convActions: snap });
    if (snap.late) late = null;              // posted once; a Swift reset must not replay it
  };
  // Official change notifications drive the snapshot (debounced); the timer is only a slow safety net.
  // Hidden / pin / archive changes go out quickly; unread and preview traffic (a burst of messages) is coalesced into one O(n) snapshot per ~1.2 s.
  let pending = null, pendingDue = 0;
  const schedule = (ms) => {
    const delay = typeof ms === 'number' ? ms : 150, due = Date.now() + delay;
    if (pending && pendingDue <= due) return;
    if (pending) clearTimeout(pending);
    pendingDue = due;
    pending = setTimeout(() => { pending = null; publish(); }, delay);
  };
  const scheduleSlow = () => schedule(1200);
  const hooked = {};
  const hookEvents = () => {
    const on = (key, mgr, names, slow) => {
      if (hooked[key] || !mgr || typeof mgr.addEventListener !== 'function') return;
      hooked[key] = true;
      for (const n of names) safe(() => mgr.addEventListener(n, slow ? scheduleSlow : () => schedule(150)), null);
    };
    on('pin', X.pin, ['ChangePinConv']);
    on('arch', X.archMgr, ['UpdateListArchivedChat', 'OnOffArchivedChat']);
    on('unread', X.unread, ['ChangeUnreadCount', 'ReadConv'], true);
    on('conv', X.convInfo, ['DeleteConv', 'LeaveGroup']);
    on('preview', X.preview, ['PreviewChanged'], true);
    // Event bus: the action types are numbers (resolved from the actions table), so a hidden-chat change from this or another device lands fast.
    if (!hooked.bus && X.bus && X.actions) {
      hooked.bus = true;
      const g = X.actions.GeneralActions, c = X.actions.ConversationListActions;
      const types = new Set([g.UPDATE_HIDDEN_CHAT, g.UPDATE_ARCHIVED_CHAT, g.UPDATE_SETTING_HIDDEN_CHAT, c.DEL_ALL_CONVERSATION_HIDDEN]);
      safe(() => X.bus.subscribe((type) => { if (types.has(type)) schedule(100); }), null);
    }
  };
  setInterval(publish, 8000);
  setInterval(() => { if (!lastKey || !ready()) publish(); }, 1000);   // until the services resolve and the hidden state is loaded
  setTimeout(publish, 500);
  const publishSoon = () => schedule(150);

  // ---- actions ----
  const inflight = new Map();   // "action|id" → start time; one run per conversation + action
  const PENDING = { pending: true };
  // One run per key. With `deadline` the caller gets {pending} when the work is slow; the slot then stays taken until the work really settles
  // (a retry could queue twice) and its outcome is reported through `onLate`.
  const guarded = async (key, fn, opts = {}) => {
    if (inflight.has(key)) return { ok: false, busy: true, text: TEXT.busy };
    inflight.set(key, Date.now());
    const work = Promise.resolve().then(fn).catch((e) => { diag(key.split('|')[0] + ' failed: ' + (e && e.message ? 'error' : typeof e)); return { ok: false, text: TEXT.generic }; });
    if (!opts.deadline) { try { return await work; } finally { inflight.delete(key); } }
    let timer;
    const first = await Promise.race([work, new Promise((r) => { timer = setTimeout(() => r(PENDING), opts.deadline); })]);
    if (first === PENDING) {
      work.then((r) => { inflight.delete(key); if (opts.onLate) opts.onLate(r); });
      return { ok: false, pending: true, text: TEXT.noReply };
    }
    clearTimeout(timer); inflight.delete(key);
    return first;
  };
  const reportLate = (r, removedId) => {
    if (!r || (!r.ok && r.text === TEXT.noReply)) return;
    late = { seq: ++lateSeq, ok: !!r.ok, text: r.text || '', neutral: !!r.neutral, removedId: r.ok && removedId ? removedId : '' };
    publish();
  };
  const fail = (text) => ({ ok: false, text: text || TEXT.generic });
  const notReady = () => fail(TEXT.notReady);
  const need = (...keys) => { if (!keys.every((k) => X[k])) lastResolve = 0; resolve(); return keys.every((k) => X[k]); };
  const str = (v) => String(v == null ? '' : v);
  // The services reject with the localized message string; "" = nothing to say (official `""!==e&&createError(e)`), anything else the generic text.
  const errString = (e, d) => (e === '' ? '' : typeof e === 'string' && e.trim() ? e : d);
  const recOf = (id) => safe(() => X.convInfo.getConvByIdSync(id), null);
  const flagsOf = (id) => { const ctx = context(); return flagsFor(id, recOf(id), ctx); };
  const tabOf = (id) => (safe(() => X.archive.isEnableArchivedChat() && X.archive.isArchivedChat(id), false) ? 1 : 0);
  // Menu enrichment (`showConvActionMenu`): the item the official handlers receive.
  const targetInfo = (id) => {
    const rec = recOf(id);
    if (!rec) return null;
    const t = Object.assign({}, rec);
    t.userId = id;
    const p = safe(() => X.preview.getPreviewByIDSync(id), null);
    const prof = isGroupId(id) ? {} : (safe(() => X.friends.getProfileFriendByIdSync(id), null) || {});
    const u = safe(() => X.unread.getUnreadByConvIdSync(id), null);
    t.lastMessage = p ? p.message : undefined; t.isFr = prof.isFr; t.type = prof.type;
    t.unreadMark = u ? u.unreadMark : undefined; t.smsUnreadCount = u ? u.smsUnreadCount : undefined;
    t.lastSeenReactId = u ? u.lastSeenReactId : undefined;
    return t;
  };

  const pinCall = async (id, unpin) => {
    try {
      const r = unpin ? X.pin.unpin([id]) : X.pin.pin([id]);
      if (r && typeof r.then === 'function') await r;
      publishSoon();
      return { ok: true, text: unpin ? TEXT.unpinOk : TEXT.pinOk };
    } catch (e) { return { ok: false, text: errString(e, unpin ? TEXT.unpinFail : TEXT.pinFail) }; }
  };

  const api = {
    // After a Swift-side reset: post the current state again even though it did not change on this page.
    republish() { lastKey = ''; publish(); },

    // ---- pin ----
    pin(id) {
      id = str(id);
      return guarded('pin|' + id, async () => {
        if (!need('pin', 'archive', 'preview', 'friends', 'hidden', 'cfg')) return notReady();
        const bits = flagsOf(id);
        if (bits & F.PINNED) return { ok: true, text: TEXT.pinOk };
        if ((bits & F.CANNOT_PIN) || (bits & F.NO_PIN_MENU)) return fail(TEXT.pinFail);
        const tab = tabOf(id), limit = X.pin.getLimitPinnedConversation(tab);
        // Full tab → the official client opens POP_PINNED_CONVERSATION instead of pinning.
        if (X.pin.getTotalPinnedConversation(tab) >= limit) return { ok: false, full: true, tab, limit, text: '' };
        return pinCall(id, false);
      });
    },
    unpin(id) {
      id = str(id);
      return guarded('unpin|' + id, async () => {
        if (!need('pin')) return notReady();
        return pinCall(id, true);
      });
    },
    // Contents of the full-board modal (`loadListPin` / `_getDescription`): pins of the tab, how many must go.
    pinBoard(id) {
      id = str(id);
      if (!need('pin', 'archive')) return null;
      const tab = tabOf(id), limit = X.pin.getLimitPinnedConversation(tab), total = X.pin.getTotalPinnedConversation(tab);
      const items = X.pin.getAllPinnedConversations(tab).filter((p) => safe(() => X.pin.isPinned(p.id), false))
        .sort((a, b) => (b.priority || 0) - (a.priority || 0)).map((p) => String(p.id));
      return { tab, limit, total, need: Math.max(total - limit + 1, 0), items };
    },
    // Modal confirm (`_retry`): unpin the chosen ones, then pin; refused unless that frees a slot.
    pinReplacing(unpinIds, id) {
      id = str(id);
      return guarded('pin|' + id, async () => {
        if (!need('pin', 'archive')) return notReady();
        const tab = tabOf(id), limit = X.pin.getLimitPinnedConversation(tab);
        const ids = (unpinIds || []).map(str);
        const board = X.pin.getAllPinnedConversations(tab).map((p) => String(p.id));
        if (!ids.length || !ids.every((x) => board.includes(x)) || board.length - ids.length >= limit) return fail(TEXT.pinFail);
        try {
          const u = X.pin.unpin(ids);
          if (u && typeof u.then === 'function') await u;
        } catch (e) { publishSoon(); return { ok: false, text: errString(e, TEXT.unpinFail) }; }
        return pinCall(id, false);
      });
    },

    // ---- archive ("Khác" / "Ưu tiên") ----
    archive(id) { return moveArchive(str(id), true); },
    unarchive(id) { return moveArchive(str(id), false); },

    // ---- delete ----
    deleteConversation(id) {
      id = str(id);
      return guarded('delete|' + id, async () => {
        if (!need('convInfo', 'delMgr', 'cfg', 'hidden', 'friends')) return notReady();
        if (id === STRANGER_BOX || (flagsOf(id) & F.CANNOT_DELETE)) return fail(TEXT.generic);
        const force = !!safe(() => X.convInfo.getLeaveType(recOf(id)), false);   // left / kicked group
        try {
          const r = await X.delMgr.deleteConversation(id, false, undefined, force);
          const label = r && r.delConversationId;
          if (label) { try { window.__zaloStore.dispatch({ type: 128, payload: { data: [{ userId: label, label: null }] } }); } catch {} }
          publishSoon();
          return { ok: true, text: '' };
        } catch (e) { return fail(TEXT.generic); }
      }, { deadline: 45000, onLate: (r) => reportLate(r, id) });
    },

    // ---- read / unread (menu `markReadStatus`: not for hidden chats nor My Cloud) ----
    markRead(id) {
      id = str(id);
      return guarded('markRead|' + id, async () => {
        if (!need('convInfo', 'preview', 'unread', 'friends', 'hidden', 'cfg') || !X.react) return notReady();
        if (id === selfId() || (flagsOf(id) & F.HIDDEN)) return fail(TEXT.generic);
        const info = targetInfo(id);
        if (!info) return fail(TEXT.generic);
        // Body of the chat-box controller's `readMessageOfConvListByID(list)`, what MARK_AS_READ ends in.
        X.unread.onClearUnreadConversations([info]);
        X.react.clearUnreadIfExist(info);
        publishSoon();
        return { ok: true, text: '' };
      });
    },
    markUnread(id) {
      id = str(id);
      return guarded('markUnread|' + id, async () => {
        if (!need('convInfo', 'preview', 'unread', 'friends', 'hidden', 'cfg') || !X.mark) return notReady();
        if (!safe(() => X.cfg.mark_unread.enable, false) || id === selfId() || (flagsOf(id) & F.HIDDEN)) return fail(TEXT.generic);
        const info = targetInfo(id);
        if (!info) return fail(TEXT.generic);
        try { await X.mark.d(info); }
        catch (e) { return fail(e && e.error_code === 277 ? TEXT.markLimit : TEXT.generic); }
        publishSoon();
        return { ok: true, text: '' };
      });
    },

    // ---- hidden chats ----
    // The PIN is only handed to the official calls. `badPin` = wrong PIN (re-enter), `pinExists` = a PIN is already set (the caller's view was stale).
    checkPin(pin) {
      if (!need('hidden')) return notReady();
      return { ok: !!safe(() => X.hidden.isKeyPIN(str(pin)), false), text: TEXT.pinWrong };
    },
    hide(id, pin) {
      id = str(id);
      return guarded('hide|' + id, async () => {
        if (!need('hidden', 'friends', 'cfg')) return notReady();
        if (!canHide(id)) return fail(TEXT.generic);
        if (!X.hidden.getPIN()) return fail(TEXT.generic);
        if (!X.hidden.isKeyPIN(str(pin))) return { ok: false, badPin: true, text: TEXT.pinWrong };
        return hideConv(id);
      });
    },
    // First-time flow: set the PIN (`changePIN`), then hide (CONFIRM_PIN → `_reqHideConv`). Never overwrites an existing PIN.
    hideWithNewPin(id, pin) {
      id = str(id);
      return guarded('hide|' + id, async () => {
        if (!need('hidden', 'friends', 'cfg')) return notReady();
        if (!canHide(id)) return fail(TEXT.generic);
        if (X.hidden.getPIN()) return { ok: false, pinExists: true, text: '' };
        const set = await changePin(str(pin));
        if (!set.ok) return set;
        return hideConv(id);
      });
    },
    unhide(id, pin) {
      id = str(id);
      return guarded('unhide|' + id, async () => {
        if (!need('hidden', 'friends', 'cfg')) return notReady();
        if (!(flagsOf(id) & F.HIDDEN)) return fail(TEXT.unhideFail);
        if (pin != null && !X.hidden.isKeyPIN(str(pin))) return { ok: false, badPin: true, text: TEXT.pinWrong };
        try { await X.hidden.updateStateItemHiddenChat(id, false); }
        catch (e) { return fail(TEXT.unhideFail); }
        publishSoon();
        return { ok: true, text: TEXT.unhideOk };
      });
    },
    // Sidebar search: the PIN as the query lists the hidden chats (null = not the PIN).
    hiddenSearch(query) {
      if (!need('hidden')) return null;
      const q = str(query);
      if (q.length !== 4 || !safe(() => X.hidden.isKeyPIN(q), false)) return null;
      return { ids: (safe(() => X.hidden.getUidsHiddenChat(), []) || []).map(String) };
    },
    // First PIN (settings) and the last step of "Đổi mã PIN" (the old PIN was verified with `checkPin`): `changePIN(pin)`.
    setPin(pin, changed) {
      return guarded('pinSet|', async () => {
        if (!need('hidden')) return notReady();
        if (!changed && X.hidden.getPIN()) return { ok: false, pinExists: true, text: '' };
        const r = await changePin(str(pin));
        if (r.ok) { if (changed) r.text = TEXT.pinChangeOk; publishSoon(); }
        return r;
      });
    },
    // Deletes the PIN and every hidden chat (official STR_DES_POPUP_HIDDEN_REMOVE_PIN warns about it).
    resetPin() {
      return guarded('pinSet|', async () => {
        if (!need('hidden')) return notReady();
        try { await X.hidden.resetPIN(); }
        catch (e) { return fail(pinErrorText(e)); }
        publishSoon();
        return { ok: true, text: TEXT.pinResetOk };
      });
    },
  };

  const pinErrorText = (e) => {
    if (e && e.error_code) return TEXT.pinFailCode(e.error_code);
    if (e && e.code === 'ERR_NO_NETWORK') return TEXT.noNetwork;
    return TEXT.generic;
  };
  const changePin = async (pin) => {
    if (!/^\d{4}$/.test(pin)) return fail(TEXT.pinWrong);
    try { await X.hidden.changePIN(pin); } catch (e) { return fail(pinErrorText(e)); }
    return { ok: true, text: '' };
  };
  // Menu `hideConversation` item: the feature is on, not an OA / My Cloud, not hidden yet.
  const canHide = (id) => !!safe(() => X.hidden.enableHiddenChat(), false) && !(flagsOf(id) & (F.CANNOT_HIDE | F.HIDDEN));
  const hideConv = async (id) => {
    const name = nameOf(id);
    try { await X.hidden.updateStateItemHiddenChat(id, true); }
    catch (e) { return fail(TEXT.hideFail(name || '')); }
    publishSoon();
    return { ok: true, text: TEXT.hiddenOk(name) };
  };

  // `moveToArchivedChat` / `removeFromArchivedChat` only call back on success; the slot stays taken until then.
  function moveArchive(id, toOther) {
    return guarded((toOther ? 'archive|' : 'unarchive|') + id, () => {
      if (!need('archive', 'archMgr', 'pin', 'storage', 'hidden', 'preview', 'friends', 'convInfo')) return notReady();
      const bits = flagsOf(id);
      if (bits & F.CANNOT_ARCHIVE) return fail(TEXT.generic);
      const text = toOther ? TEXT.toOther : TEXT.toFocus;
      if (!!(bits & F.ARCHIVED) === toOther) return { ok: true, neutral: true, text };
      return new Promise((resolveWork) => {
        const cb = () => {
          if (toOther) { try { if (X.pin.isPinned(id)) Promise.resolve(X.pin.unpin([id])).catch(() => {}); } catch {} }
          try { X.archMgr.onUpdateListArchivedChat(id); } catch {}
          publishSoon();
          resolveWork({ ok: true, neutral: true, text });   // official createMessage: a neutral notice, not a success toast
        };
        try { (toOther ? X.archive.moveToArchivedChat : X.archive.removeFromArchivedChat).call(X.archive, id, cb); }
        catch (e) { resolveWork(fail(TEXT.generic)); return; }
        setTimeout(() => resolveWork(fail(TEXT.noReply)), 120000);   // no callback at all: free the slot
      });
    }, { deadline: 30000, onLate: (r) => reportLate(r, '') });
  }

  window.__zaloConvActions = api;
})();
