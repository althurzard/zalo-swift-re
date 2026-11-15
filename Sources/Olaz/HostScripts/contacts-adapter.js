// Olaz contacts adapter ("Danh bạ"), index.html only. Exposes `window.__zaloContacts` and posts
// {page:'main', contacts:{…}} via `zstate`. Everything goes through the official client's services:
//
//   friends        friend-manager module (`getFriendsSync`, `getDName`) — same list/filter the contact tab
//                  uses (`isFr`, `isValid`, not me, not the "cloud" pseudo-user).
//   groups         group-manager module (`getGroupsListSync`, `getTotalMember`).
//   received       friend-recommendation cache (`getRecommendedFriendsV2` / realtime `addRequest`),
//                  items with `dataInfo.recommType === 2` — what the official invitation page lists.
//   sent           recommendation service `getRequestedFriends()` (the invitation page's "Đã gửi").
//   accept/decline/cancel/send
//                  friend-request service (`acceptAddFriend`, `rejectRequestAddFriend`,
//                  `undoRequestAddFriend`, `requestAddFriend`) — the exact calls the invitation page and
//                  the add-friend dialog make, including their local cache updates.
//   find by phone  friend-manager `getInfoByPhone(e164, SRC_FIND_FRIEND_FORM)` with the add-friend form's
//                  phone normalisation, then the official friend-request status + default "say hi" text.
//
// Swift → JS : refresh() search(phone, iso?) resetSearch() sendRequest(id, message) → Promise<{ok, text}> accept(id)
//              decline(id) cancel(id)
//
// JS → Swift : partial snapshots, each key replaces that section:
//   friends:  [{id, name, zaloName, avatar, lastActive (ms, 0 unknown), online}]
//   groups:   [{id, name, avatar, members, type}]
//   received: [{id, name, avatar, message, time (ms)}]
//   sent:     [{id, name, avatar, message, time (ms)}]
//   pendingRequestCount: Int           (received requests)
//   loading:  {requests: Bool}
//   search:   {seq, status:'idle'|'searching'|'found'|'error', error?, user?:{id, name, zaloName, avatar,
//              bio, isFriend, requested, requesting, defaultMessage, maxMessage}}
//   notice:   {seq, ok, text}          (result of an accept/decline/cancel/send action)
(() => {
  'use strict';
  const NAME = window.__zaloContactsTestName || '__zaloContacts';
  if (window[NAME]) return;
  if (location.pathname.split('/').pop() !== 'index.html') return;

  // `__zaloContactsTestSink` (set only by a dev harness together with a test global name) captures posts.
  const post = (contacts) => {
    if (window.__zaloContactsTestName && typeof window.__zaloContactsTestSink === 'function') { window.__zaloContactsTestSink(contacts); return; }
    try { window.webkit.messageHandlers.zstate.postMessage({ page: 'main', contacts }); } catch {}
  };
  const diag = (s) => { try { window.webkit.messageHandlers.zlog.postMessage('[contacts] ' + s); } catch {} };
  const safe = (fn, d) => { try { const v = fn(); return v === undefined ? d : v; } catch { return d; } };
  const str = (v) => (typeof v === 'string' ? v : '');
  const num = (v) => { const n = Number(v); return Number.isFinite(n) ? n : 0; };
  const errText = (e) => {
    if (!e) return '';
    if (typeof e === 'string') return e;
    return str(e.error_message) || str(e.message) || (e.error_code ? 'Mã lỗi ' + e.error_code : '');
  };

  // ---- services, found by shape in the official module cache / DI container ----
  const S = {};
  let io = null, lastResolve = 0, resolveTries = 0;
  const own = (o, k) => Object.prototype.hasOwnProperty.call(o, k);
  const resolve = () => {
    const req = window.__zaloRequire;
    if (!req || !window.__zaloStore || typeof window.__zaloDI !== 'function' || typeof window.__zaloEachExport !== 'function') return false;
    const ready = () => S.friends && S.groups && S.frSvc && S.recoCache && S.reco;
    if (ready()) return true;
    if (Date.now() - lastResolve < 500 || resolveTries >= 120) return false;
    lastResolve = Date.now(); resolveTries++;
    if (!io) {
      for (const reg of window.__zaloDI(req)) {
        const i = reg.instance;
        try { if (i && typeof i === 'object' && typeof i.getFriendManagerModule === 'function') { io = i; break; } } catch {}
      }
      if (io) {
        Promise.all([io.getFriendManagerModule(), io.getGroupManagerModule()]).then(([f, g]) => {
          S.friends = f.default || f; S.groups = g.default || g; kick();
        }).catch((e) => { io = null; diag('friend/group modules: ' + e); });
      }
    }
    window.__zaloEachExport(req, (ex) => {
      if (!ex || (typeof ex !== 'object' && typeof ex !== 'function')) return;
      try {
        // The host answers unknown preload globals with catch-all placeholders; real modules don't.
        if (ex.__olaz_not_a_member__ !== undefined) return;
        if (!S.frSvc && typeof ex.requestAddFriend === 'function' && typeof ex.acceptAddFriend === 'function' && typeof ex.undoRequestAddFriend === 'function' && own(ex, 'friendRequestSources')) S.frSvc = ex;
        if (!S.recoCache && typeof ex.getRecommendedFriendsV2 === 'function' && typeof ex.removeSuggest === 'function') S.recoCache = ex;
        if (!S.reco && typeof ex.getRequestedFriends === 'function' && typeof ex.getRecommendedFriends === 'function') S.reco = ex;
        if (!S.storage && typeof ex.getSayHiV2 === 'function' && typeof ex.setStrangerCache === 'function') S.storage = ex;
        if (!S.utils && typeof ex.getE164PhoneNumber === 'function' && typeof ex.getMessageErrorForGetUserByPhone === 'function') S.utils = ex;
        if (!S.consts && ex.MAX_CHAR_SAY_HI !== undefined && ex.FRIEND_REQUEST_SRC_FIND_FRIEND_FORM !== undefined) S.consts = ex;
        if (!S.cfg && own(ex, 'sendToMeId') && own(ex, 'online_configs')) S.cfg = ex;
        if (!S.cfg && own(ex, 'sendToMeId')) S.cfgLite = ex;
        if (!S.lastActive && typeof ex._cacheLastActionTime === 'object' && typeof ex.getLastActionTime === 'function') S.lastActive = ex;
        if (!S.lang && ex.default && typeof ex.default.str === 'function' && typeof ex.default.trans === 'function' && typeof ex.default.currentLanguage === 'function') S.lang = ex.default;
      } catch {}
    });
    return !!ready();
  };
  const SRC_FIND = () => num((S.consts && S.consts.FRIEND_REQUEST_SRC_FIND_FRIEND_FORM) ?? 40);
  const MAX_MSG = () => num((S.consts && S.consts.MAX_CHAR_SAY_HI) || 150);
  const sendToMeId = () => str((S.cfg || S.cfgLite || {}).sendToMeId);
  const me = () => safe(() => window.__zaloStore.getState().user, {}) || {};
  const langStr = (key) => safe(() => S.lang.str(key), '') || '';

  // ---- friends / groups ----
  // `online_configs` may be a host placeholder for preload globals: accept real numbers only (default 3 min).
  const activeWindow = () => { const v = safe(() => S.cfg.online_configs.user_active_time, 0); return typeof v === 'number' && v > 0 ? v : 180000; };
  const mapFriends = () => {
    const list = safe(() => S.friends.getFriendsSync(), null);
    if (!Array.isArray(list)) return null;
    const meId = str(me().userId), cloud = sendToMeId(), now = Date.now(), win = activeWindow();
    const out = [];
    for (const x of list) {
      if (!x || !x.userId || !x.isFr || x.isValid === 0 || x.isValid === false) continue;
      if (x.userId === meId || x.userId === cloud) continue;
      const cached = safe(() => S.lastActive._cacheLastActionTime[x.userId], null) || {};
      const seen = Math.max(num(x.lastOnlineTime), num(cached.lastOnlineTime), num(x.lastActionTime), num(cached.lastActionTime));
      const name = safe(() => S.friends.getDName(x.userId), '') || str(x.displayName) || str(x.zaloName);
      out.push({
        id: String(x.userId), name, zaloName: str(x.zaloName),
        avatar: safe(() => S.friends.getAvatar(x.userId), '') || str(x.avatar),
        lastActive: seen ? Math.floor(seen / 60000) * 60000 : 0,
        online: !!seen && now - seen <= win,
      });
    }
    return out;
  };
  const mapGroups = () => {
    const list = safe(() => S.groups.getGroupsListSync(), null);
    if (!Array.isArray(list)) return null;
    const out = [];
    for (const g of list) {
      if (!g || !g.userId) continue;
      const id = String(g.userId);
      out.push({
        id, name: safe(() => S.groups.getDName(id), '') || str(g.displayName),
        avatar: safe(() => S.groups.getAvatarGroup(id), '') || str(g.avatar),
        members: num(safe(() => S.groups.getTotalMember(id), 0)) || num(g.totalMember),
        type: num(g.type),
      });
    }
    return out;
  };

  // ---- friend requests ----
  const RECEIVE = 2;                                     // recommType of a received friend request
  const profileOf = (id) => safe(() => S.friends.getProfileFriendByIdSync(id), null) || {};
  const nameOfUser = (u) => str(u.displayName) || str(u.zaloName) || safe(() => S.friends.getDName(u.userId), '') || '';
  const receivedNow = () => {
    const obj = safe(() => S.recoCache.recommFrObj, null);
    if (!obj) return null;
    const out = [];
    for (const k of Object.keys(obj)) {
      const it = obj[k], d = it && it.dataInfo;
      if (!d || d.recommType !== RECEIVE || !d.userId) continue;
      out.push({
        id: String(d.userId), name: nameOfUser(d), avatar: str(d.avatar),
        message: str(d.recommInfo && d.recommInfo.message), time: num(d.recommTime || d.friendRequestFetchTime),
      });
    }
    return out.sort((a, b) => b.time - a.time);
  };
  let sent = [];                                         // refreshed from the server
  const mapSent = (obj) => {
    const out = [];
    for (const k of Object.keys(obj || {})) {
      const u = obj[k];
      if (!u || !u.userId) continue;
      out.push({ id: String(u.userId), name: nameOfUser(u), avatar: str(u.avatar), message: str(u.fReqInfo && u.fReqInfo.message), time: num(u.fReqInfo && u.fReqInfo.time) });
    }
    return out.sort((a, b) => b.time - a.time);
  };
  let refreshing = null, lastFull = 0;
  // `force`: re-fetch both lists from the server (as opening the invitation page does).
  const refreshRequests = (force) => {
    if (!resolve()) return Promise.resolve();
    if (refreshing) return refreshing;
    post({ loading: { requests: true } });
    refreshing = (async () => {
      try {
        await S.recoCache.getRecommendedFriendsV2(!!force, false);
        const s = await S.reco.getRequestedFriends();
        sent = mapSent(s);
        lastFull = Date.now();
      } catch (e) { diag('refresh requests failed: ' + errText(e)); }
      finally { refreshing = null; post({ loading: { requests: false } }); publish(); }
    })();
    return refreshing;
  };

  // ---- publishing ----
  const last = {};
  const emit = (key, value) => {
    if (value === null || value === undefined) return;
    const k = JSON.stringify(value);
    if (last[key] === k) return;
    last[key] = k;
    post({ [key]: value });
  };
  // The friend list (thousands of rows) goes out at once when a friend's data changes (added / removed / renamed / new avatar);
  // when only presence moved (`online` flips, `lastActive` minute advances) at most every PRESENCE_MS. The row shape is unchanged
  // (Swift reads `online` as sent).
  const PRESENCE_MS = 30000;
  let friendsData = '', friendsPresence = '', friendsAt = 0;
  const emitFriends = (list) => {
    if (!list) return;
    const data = JSON.stringify(list.map((f) => [f.id, f.name, f.zaloName, f.avatar]));
    const presence = JSON.stringify(list.map((f) => [f.lastActive, f.online]));
    if (data === friendsData && (presence === friendsPresence || Date.now() - friendsAt < PRESENCE_MS)) return;
    friendsData = data; friendsPresence = presence; friendsAt = Date.now();
    post({ friends: list });
  };
  const publish = () => {
    if (!resolve()) return;
    const step = (name, fn) => { try { fn(); } catch (e) { diag('publish ' + name + ' failed: ' + (e && e.name ? e.name : typeof e)); } };
    step('friends', () => emitFriends(mapFriends()));
    step('groups', () => emit('groups', mapGroups()));
    step('received', () => { const received = receivedNow(); if (received) { emit('received', received); emit('pendingRequestCount', received.length); } });
    step('sent', () => emit('sent', sent));
  };
  let started = false;
  const kick = () => {
    if (started || !resolve()) return;
    started = true;
    refreshRequests(false);
    setInterval(() => { try { publish(); } catch (e) { diag('publish failed: ' + e); } }, 3000);
    // Safety net behind the realtime friend-request events: a full server refresh every 3 minutes.
    setInterval(() => { refreshRequests(true); }, 180000);
    publish();
  };
  const starter = setInterval(() => { kick(); if (started) clearInterval(starter); }, 500);

  // ---- find by phone ----
  let searchSeq = 0;
  let lastFound = {};                                    // profile card on screen, to mark it requested after a send
  const postSearch = (extra) => {
    if (extra.status === 'found') lastFound = extra.user;
    post({ search: Object.assign({ seq: searchSeq }, extra) });
  };
  const e164Of = (input, iso) => {
    const raw = String(input || '').trim();
    let digits = raw.split('').filter((c) => (c >= '0' && c <= '9') || c === '+').join('');
    if (!digits.replace('+', '')) return '';
    let cc = '84', country = iso || 'VN';
    if (digits.startsWith('+')) {
      const p = safe(() => S.utils.getPhoneNumber(digits), null);
      if (p && safe(() => p.isPossibleNumber(), false)) { cc = String(p.getCountryCode()); country = p.getISOCountryCode(); digits = p.getPhone(); }
      else digits = digits.slice(1);
    }
    // Same order as the official form: libphonenumber E.164 first, then country code + national number.
    const e164 = safe(() => S.utils.getE164PhoneNumber(digits, country), '');
    if (e164) return e164;
    let national = digits.split('').filter((c) => c >= '0' && c <= '9').join('');
    if (national.startsWith('0')) national = national.slice(1);
    return cc + national;
  };
  const search = async (phone, iso) => {
    const seq = ++searchSeq;
    if (!resolve()) { postSearch({ status: 'error', error: 'Chưa sẵn sàng, vui lòng thử lại sau giây lát.' }); return; }
    const target = e164Of(phone, iso);
    if (!target) { postSearch({ status: 'error', error: 'Vui lòng nhập số điện thoại.' }); return; }
    postSearch({ status: 'searching' });
    try {
      const e = await S.friends.getInfoByPhone(target, SRC_FIND());
      if (seq !== searchSeq) return;
      if (!e || e.error_code) { postSearch({ status: 'error', error: errText(e) || 'Không tìm thấy người dùng.' }); return; }
      const id = String(e.userId || e.uid || '');
      if (!id) { postSearch({ status: 'error', error: 'Không tìm thấy người dùng.' }); return; }
      const isFriend = !!(await Promise.resolve(safe(() => S.friends.isFriend(id), false)));
      let requested = false, requesting = false;
      if (!isFriend) {
        safe(() => S.frSvc.setFriendRequestSource(id, SRC_FIND()), null);
        try {
          const st = await S.frSvc.getStatusFriendRequest(id, true, true);
          if (st) { requested = num(st.isRequested) === 1 || st.isRequested === true; requesting = num(st.isRequesting) === 1 || st.isRequesting === true; }
        } catch {}
        if (seq !== searchSeq) return;
      }
      const defaultMessage = safe(() => S.storage.getSayHiV2(str(me().displayName), MAX_MSG(), SRC_FIND()), '') || '';
      postSearch({
        status: 'found',
        user: {
          id, name: str(e.displayName) || str(e.display_name) || str(e.dName) || str(e.zaloName) || str(e.zalo_name),
          zaloName: str(e.zaloName) || str(e.zalo_name), avatar: str(e.avatar), bio: str(e.status),
          isFriend, requested, requesting, defaultMessage, maxMessage: MAX_MSG(),
          isSelf: id === str(me().userId),
        },
      });
    } catch (err) {
      if (seq !== searchSeq) return;
      const code = err && Number(err.error_code);
      let text = errText(err);
      if (code === 312 || code === 313) text = text || langStr(safe(() => S.utils.getMessageErrorForGetUserByPhone(code), ''));
      else text = langStr(safe(() => S.utils.getMessageErrorForGetUserByPhone(code), '')) || text;
      postSearch({ status: 'error', error: text || 'Không tìm thấy người dùng.' });
    }
  };

  // ---- write actions (all official paths; results come back as `notice`) ----
  let noticeSeq = 0;
  const notice = (ok, text) => post({ notice: { seq: ++noticeSeq, ok, text } });
  const removeLocal = (id) => { safe(() => S.recoCache.removeSuggest(id), null); };
  // → {ok, text}: the same result that is posted as the `notice` (callers that wait for it use the return value).
  const requesting = new Set();   // uids with a friend request in flight (`sendRequest`)
  const act = async (fn, okText, failText, after) => {
    if (!resolve()) { const text = 'Chưa sẵn sàng, vui lòng thử lại.'; notice(false, text); return { ok: false, text }; }
    let result;
    try { await fn(); notice(true, okText); result = { ok: true, text: okText }; if (after) after(); }
    catch (e) { diag('action failed: ' + (e && (e.error_code || e.code) || e)); const text = errText(e) || failText; notice(false, text); result = { ok: false, text }; }
    // Re-read both lists from the server so the screen matches the account.
    lastFull = 0; refreshRequests(true);   // not awaited: the caller gets its result now
    return result;
  };

  window[NAME] = {
    refresh() { kick(); refreshRequests(true); },
    search(phone, iso) { search(phone, iso); },
    resetSearch() { searchSeq++; postSearch({ status: 'idle' }); },
    accept(id) {
      act(() => S.frSvc.acceptAddFriend(String(id)), 'Đã chấp nhận lời mời kết bạn.', 'Không thể chấp nhận lời mời.', () => removeLocal(String(id)));
    },
    decline(id) {
      act(() => S.frSvc.rejectRequestAddFriend(String(id)), 'Đã từ chối lời mời kết bạn.', 'Không thể từ chối lời mời.', () => removeLocal(String(id)));
    },
    cancel(id) {
      act(() => S.frSvc.undoRequestAddFriend(String(id)), 'Đã thu hồi lời mời kết bạn.', 'Không thể thu hồi lời mời.');
    },
    sendRequest(id, message) {
      const uid = String(id), text = String(message || '').slice(0, MAX_MSG());
      // One request per person at a time. The call itself is never cancelled; when it has not answered in ~60 s the caller is told it is still
      // pending and a retry is refused until the original settles (so one click can never become two requests).
      if (requesting.has(uid)) return Promise.resolve({ ok: false, pending: true, text: 'Lời mời kết bạn đang được gửi. Hãy chờ giây lát rồi kiểm tra mục “Đã gửi”.' });
      const run = act(async () => {
        if (!text.trim()) throw { error_message: 'Vui lòng nhập lời nhắn.' };
        if (!safe(() => S.frSvc.getFriendRequestSource(uid), null)) safe(() => S.frSvc.setFriendRequestSource(uid, SRC_FIND()), null);
        await S.frSvc.requestAddFriend(uid, text, S.frSvc.getFriendRequestSource(uid));
        safe(() => S.storage.setStrangerCache(uid, 1), null);
      }, 'Đã gửi lời mời kết bạn.', 'Không thể gửi lời mời kết bạn.', () => {
        // Reflect the new state in the open profile card.
        if (lastFound && lastFound.id === uid) postSearch({ status: 'found', user: Object.assign({}, lastFound, { requested: true }) });
      });
      requesting.add(uid);
      const done = () => requesting.delete(uid);
      run.then(done, done);
      const late = new Promise((resolve) => setTimeout(() => resolve({ ok: false, pending: true, text: 'Chưa nhận được phản hồi. Hãy kiểm tra mục “Đã gửi” trong Lời mời kết bạn trước khi thử lại.' }), 60000));
      return Promise.race([run, late]);
    },
  };
  diag('adapter installed (' + NAME + ')');
})();
