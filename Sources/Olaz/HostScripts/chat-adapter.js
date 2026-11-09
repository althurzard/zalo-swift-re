// Olaz chat adapter: exposes `window.__zaloChat` (see ChatModels.swift) on the
// main page (index.html) only. Everything goes through the official client:
//
//   open          opener service (`openConversation`) + message-loader manager
//                 (`getLastMessagesForConversation`), the same calls the chat view makes.
//   loadMore      chat-box controller `_loadMoreMessages()` (loader `loadTopMessagesForConversation`).
//   sendText      chat-box controller `_processSendMessage(MSG_TEXT, …)` — the composer's own send
//                 path: pending local message, E2EE, retries, store update. Replies go through
//                 `_replyMessage` (quote banner) first.
//   mentions      send: `_processSendMessage(MSG_TEXT, text, mentions, …)` takes the official mention list
//                 [{pos, len, uid, type}] (pos = index of '@' in the text, len = "@Name".length,
//                 type 0 = user / 1 = all with uid "-1"; same shape as the composer's
//                 `ZTagNameHelper.getRealListMention()`). Suggestions: the official
//                 `ZTagNameHelper.getListSuggestMention` over `getFullInfoGroupById(...).topMember`
//                 (its own filter, ordering, "All" permission rules).
//   markRead      chat-box controller `readMessageOfConv`  (UnreadDataManager).
//   reactors      reaction cache `getMessageReactions` → `{uid:{rType:count}}` (uid '0' = me); names/avatars from the
//                 profile service's mini info (`getProfileFriendByIds` for strangers, as module "7itQ" does).
//   react         reaction sender `sendReaction` + reaction cache (`generateReactMsg`/`onReceiveReactions`).
//   realtime      Redux store subscription; incoming messages arrive through the official sync.
//   typing        wraps the official typing manager's `addItemTyping`.
//
// Swift → JS : open(convId) close(convId) loadMore(convId) sendText(convId, text, quoteMsgId?, mentions?) → 'sent'|'not-open'|'not-ready'|'error'
//              markRead(convId) react(convId, msgId, emoji)
//              resolveMedia(convId, msgId, 'photo'|'videoThumb'|'video') → Promise<{state:'ok', path, source, quality}
//                | {state:'expired'} | {state:'unavailable', reason} | {state:'unsupported'}>
//                ('video': the decrypted local copy the official inline player plays)
//                (a message that is not loaded in the chat box but was listed by the media store — media-store-adapter.js — is resolved from the store's item)
//              mentionCandidates(convId, query, mentionedUids) → Promise<[{id, name, avatar, isAll}]>
//              reactors(convId, msgId) → Promise<{tabs:[{type, key, emoji, image, total}],
//                users:[{uid, name, avatar, isMe, total, icons:[{type, key, emoji, image, count}]}]} | null>
//                (the "Biểu cảm" popup: tabs by total desc then rType, users by total desc / me first / first reaction
//                type; null = unknown, not "nobody reacted". Icons: `key` = official icon text, `image` = pc-dist path of
//                its emoji PNG ('' when none), `emoji` = Unicode for the known six else the text)
//
// JS → Swift (`zstate`):
//   {page:'main', chat:{convId, messages:[ChatMessageJSON], removed:[id], hasMore, reset}}
//   {page:'main', typing:{convId, name}}
//
// reset=true: `messages` is the full list (oldest first); otherwise only added/changed messages
// (merge by id) and `removed` ids.
//
// ChatMessageJSON:
//   { id, conversationId, senderId, senderName, senderAvatar (url|''), isMine, text,
//     date (ms), status ('sending'|'sent'|'delivered'|'seen'|'failed'),
//     kind: {type:'text'}
//         | {type:'photo', url, width, height} | {type:'sticker', url} | {type:'gif', url}
//         | {type:'video', thumbnail, url, duration(s)} | {type:'voice', url, duration(s)}
//         | {type:'file', name, size, url}
//         | {type:'link', title, url, thumbnail, description, source}      (recommened.link, LINK_CLIENT)
//         | {type:'contactCard', name, uid, avatar, phone, qr, oaLink, isOA}  (recommened.user / .vip)
//         | {type:'location', title, address, hasCoordinates, latitude, longitude, thumbnail}
//         | {type:'call', video, missed, duration(s), title, detail}        (recommened.misscall|calling|receivecall|calltime, CALL 601)
//         | {type:'ecard', style:'banner'|'friend'|'birthday'|'reminder', image, thumb, title, description, actions:[label],
//                          avatars:[url], reminderTitle, reminderStart(ms), reminderRepeat}   (ECARD 25; its buttons are the message-level `buttons`, see below)
//         | {type:'oaMessage', parts:[{header, title, description, thumb, url}]}   (OA 21 chat.list.action, ARTICLE 0)
//         | {type:'poll', question, header, anonymous, pollId, conversationId}   (POLL 26; header = info line; options / votes: poll-adapter.js)
//         | {type:'stickerSet', title, thumb}                               (recommened.stickerset, STICKER_SET 602)
//         | {type:'zinstant', title, text, thumb}                           (ZINSTANT 52/53/27: customMsg text of the metadata)
//         | {type:'notice', symbol (SF Symbol), text}                       (INFO_CHAT, TODO(_DONE), VANISH, SYNCING*) centered notice
//         | {type:'placeholder', symbol, text}                              (E2EE_DECRYPT_FAILED / E2EE_PENDING_DATA) bubble
//         | {type:'system'}                                                 (INFO, GROUP_NOTI, ERROR_INFO, FRIEND_SENT_REQUEST, SUGGEST_IN_CHAT, KICK/DISBAND_GROUP)
//         | {type:'recalled'} | {type:'unsupported', rawType},
//     buttons: [{ref, label, enabled, help}], stickers: bool       (only when the card has some; added by card-actions-adapter.js `describe`:
//         e-card actions, info-message links, "GỌI LẠI" of a call log; `stickers` = the card offers its suggested stickers.
//         Run with `performAction(convId, msgId, ref)` — see card-actions-adapter.js for the official handlers.)
//         Cards the official client draws nothing for (ECARD type "7", notices without text), and the onboarding e-card, are not emitted.
//     quote: {senderName, text} | null,
//     reactions: [{type, key, emoji, image, count, includesMe, names (≤3, cached; me first as "Bạn"), people (distinct reactors)}],
//     mentions: [{uid, pos, len, isAll}]   // official message.mentions (pos/len are UTF-16 offsets into text)
//     isE2EE,
//     menu: {forward, recall, delete, pin, star, starred, protected, pinned} | null   (message-actions-adapter.js `describe`) }
//   * id: my own messages use the client message id (stable from pending to sent); others use
//     the server msgId. send/react/quote accept either form.
//   * text: caption / body; non-text kinds without a caption carry the official preview text (`getPlainText`,
//     lang_vi.json) such as "[Hình ảnh]", "[Danh thiếp] <tên>", "[Thiệp]", "[Bình chọn] <câu hỏi>".
//   * quote.text follows the official quote banner (`cliMsgType` + `attach`).
//   * Field shapes of each card are documented next to its builder in "message mapping" below (bundle offsets given).
//   * A grouped photo message (several photos) is expanded into one photo message per photo.
(() => {
  'use strict';
  if (window.__zaloChat) return;
  if (location.pathname.split('/').pop() !== 'index.html') return;

  const post = (state) => { try { window.webkit.messageHandlers.zstate.postMessage(state); } catch {} };
  const diag = (s) => { try { window.webkit.messageHandlers.zlog.postMessage('[chat] ' + s); } catch {} };
  const own = (o, k) => Object.prototype.hasOwnProperty.call(o, k);
  const safe = (fn, d) => { try { const v = fn(); return v === undefined ? d : v; } catch { return d; } };
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

  const MSG = { TEXT: 1, PHOTO: 2, VOICE: 3, STICKER: 4, DOODLE: 5, CONTACT: 6, GIF: 7, PHOTO_2: 11, STICKER_2: 13, LOCATION: 17, VIDEO: 18, FILE: 19, UNDO: 20, OA: 21, ECARD: 25, POLL: 26, INFO: -4, GROUP_NOTI: -6, DEL_EVERYONE: -27, PHOTO_GROUP: 2503, STICKER_GROUP: 2502 };
  const ST = { LOCAL: 10, SENT: 1, DELIVERED: 2, SEEN: 3, READ: 4, AFTER_READ: 5, FAIL: -2, CANCEL: -7 };
  // Reaction codes from the official config (`reactionMsgInfo`).
  const REACTIONS = [[0, ':>', '😆'], [20, ':-h', '😡'], [2, ':-((', '😢'], [3, '/-strong', '👍'], [32, ':o', '😮'], [5, '/-heart', '❤️']];
  // Reaction icons are images in the official client: `getHtmlFromText(iconText)` → `renderUnicodeEmoji` looks the
  // text up in `emojiRC` ("column row", also by lower-case) and draws `emoji/emoji-<size>/row-R-column-C.png`.
  // rType → iconText comes from `reactCache.getIconMap()`; a type without text (or longer than the official
  // `reaction_v2.r_icon_max_length`, default 30) has no icon and is hidden from chips / tabs (its count still totals).
  const KNOWN_EMOJI = new Map(REACTIONS.map((r) => [String(r[0]), r[2]]));
  const EMOJI_BY_CODE = new Map(REACTIONS.map((r) => [r[1], r[2]]));
  const EMOJI_DIR = 'emoji/emoji-32';
  const iconMaxLen = () => {
    for (const cfg of [S.cfg, S.emojiCfg]) { const n = Number(safe(() => cfg.reaction_v2.r_icon_max_length, 0)); if (n > 0) return n; }
    return 30;
  };
  const iconTextOf = (t) => {
    let text = safe(() => S.reactCache.getIconMap()[t], '');
    if (typeof text !== 'string' || !text) { const r = REACTIONS.find((x) => String(x[0]) === String(t)); text = r ? r[1] : ''; }
    return text && text.length <= iconMaxLen() ? text : '';
  };
  const iconImage = (key) => {
    scanModules();
    const rc = S.emojiCfg && S.emojiCfg.emojiRC;
    const cell = rc && (rc[key] || rc[key.toLowerCase()]);
    const [col, row] = typeof cell === 'string' ? cell.split(' ') : [];
    return col && row ? `${EMOJI_DIR}/row-${row}-column-${col}.png` : '';
  };
  // → {type, key (official icon text), emoji (Unicode for the known six, else the text), image (pc-dist path or '')} | null
  const iconInfo = (t) => {
    const key = iconTextOf(t);
    if (!key) return null;
    return { type: String(t), key, emoji: KNOWN_EMOJI.get(String(t)) || EMOJI_BY_CODE.get(key) || key, image: iconImage(key) };
  };
  const scrubErr = (e) => String((e && (e.name + ':' + e.message)) || e).replace(/https?:\/\/\S+/g, '<url>').replace(/\d{5,}/g, '<id>').slice(0, 80);

  // ---- services (resolved lazily from the official DI container / module cache) ----
  const S = { friends: null, groups: null, modulesLoading: false };
  let lastResolve = 0, resolveAttempts = 0;
  const resolveServices = () => {
    const req = window.__zaloRequire;
    if (!req || !window.__zaloStore || typeof window.__zaloDI !== 'function') return false;
    const complete = () => S.chat && S.opener && S.loader && S.typing && S.reactCache && S.reactSender && S.cfg && S.friends;
    if (complete()) return true;
    if (Date.now() - lastResolve < 400 || resolveAttempts >= 40) return false;
    lastResolve = Date.now(); resolveAttempts++;
    for (const reg of window.__zaloDI(req)) {
      const i = reg.instance;
      if (!i || typeof i !== 'object') continue;
      try {
        if (!S.chat && typeof i.broadCastMessage === 'function' && i.chatboxController) S.chat = i;
        if (!S.opener && typeof i.openConversation === 'function' && typeof i.conversationWillOpen === 'function') S.opener = i;
        if (!S.io && typeof i.getFriendManagerModule === 'function') S.io = i;
      } catch {}
    }
    window.__zaloEachExport(req, (ex) => {
      if (!ex || typeof ex !== 'object') return;
      try {
        if (!S.loader && ex.cacheMessageLoader instanceof Map && typeof ex.getLastMessagesForConversation === 'function') S.loader = ex;
        if (!S.typing && own(ex, 'mapIdTyping') && typeof ex.addItemTyping === 'function') S.typing = ex;
        if (!S.reactCache && typeof ex.generateReactMsg === 'function' && own(ex, 'updateReactionListener') && typeof ex.addUpdateReactListener === 'function') S.reactCache = ex;
        if (!S.reactSender && Array.isArray(ex.sendQueue) && typeof ex.sendReaction === 'function' && own(ex, 'sendQueue')) S.reactSender = ex;
        if (!S.cfg && own(ex, 'stickerUrl') && own(ex, 'sendToMeId')) S.cfg = ex;
      } catch {}
    });
    if (S.io && !S.friends && !S.modulesLoading) {
      S.modulesLoading = true;
      Promise.all([S.io.getFriendManagerModule(), S.io.getGroupManagerModule()]).then(([f, g]) => {
        S.friends = f.default || f; S.groups = g.default || g;
        track.nameRetries = 0; remapAll();
      }).catch((e) => { S.modulesLoading = false; diag('friend/group modules: ' + e); });
    }
    hookTyping();
    hookReactions();
    return !!complete();
  };
  const controller = () => (S.chat && S.chat.chatboxController) || null;
  // Official chat-box registry (`popupChatBoxMapping` + `wins`): the controller the main chat box keeps.
  // Misses are not rescanned for 3s (like `scanModules`); one odd export cannot abort the pass.
  let boxRegistry = null, lastBoxScan = 0;
  const chatBoxes = () => {
    if (boxRegistry) return boxRegistry;
    if (Date.now() - lastBoxScan < 3000 || typeof window.__zaloEachExport !== 'function' || !window.__zaloRequire) return null;
    lastBoxScan = Date.now();
    safe(() => window.__zaloEachExport(window.__zaloRequire, (ex) => {
      if (boxRegistry || !ex) return;
      for (let i = 0; i < 2 && !boxRegistry; i++) {
        try {
          const o = i ? ex.default : ex;
          if (o && typeof o === 'object' && o !== window.$capp && own(o, 'popupChatBoxMapping') && own(o, 'wins')
            && typeof o.removeMainChatBoxController === 'function' && typeof o.getChatBoxControllerByConvId === 'function') boxRegistry = o;
        } catch {}
      }
    }), null);
    return boxRegistry;
  };
  // What the chat box view's `_initChatController` hangs on the controller (the view's own refs; `zTagNameHelper`
  // lives on the view itself). A repaired controller gets them from the one it replaces (or the last seen).
  const BOX_FIELDS = ['genMessageServer', 'resetChatInputRef', '_chatInputbox', 'articleRef', '_importantBtn', '_mainChatBoxInputRef'];
  // (The constructor starts them as null, so copy where the new one has null and keep only non-null values.
  // `resetChatInputRef` only writes the view's input into the view's own — stale — controller; it is copied so a
  // call from the controller does not hit undefined.)
  let boxFields = null;
  const noteBoxFields = (cc) => {
    if (!cc || cc.isChild) return;
    boxFields = boxFields || {};
    for (const k of BOX_FIELDS) if (cc[k] != null) boxFields[k] = cc[k];
  };
  // The official chat box swaps its controller in `_conversationChanged` (componentWillReceiveProps). In the headless
  // page that React update can be skipped, leaving the previous conversation's controller in charge: sends then fail
  // "conversation not open" and load-more stops. Same steps as the chat box's own `_conversationChanged` /
  // `_initChatController` (child windows are never opened here, but the official guard is kept).
  // While `open(convId)` is in flight the official update may just be slow: only open() itself repairs then.
  const repairController = (convId, fromOpen) => {
    const cc = controller();
    if (cc && cc.convId === convId) return true;
    if (openingId === convId && !fromOpen) return false;
    const reg = chatBoxes();
    const selected = safe(() => S.opener.sidebar.getSelectedId(), null);
    if (!reg || !convOf(convId) || selected !== convId) return false;
    noteBoxFields(cc);
    try {
      const child = typeof reg.isOpenChildWindowByConvId === 'function' && reg.isOpenChildWindowByConvId(convId);
      if (!child && cc && cc.convId) reg.removeChatBoxControllerByConvId(cc.convId);
      if (!child) reg.removeMainChatBoxController(convId);
      const next = reg.getChatBoxControllerByConvId(convId);
      if (next && !next.isChild && boxFields) for (const k of Object.keys(boxFields)) if (next[k] == null) next[k] = boxFields[k];
    } catch (e) { diag('controller repair: ' + scrubErr(e)); return false; }
    const ok = !!(controller() && controller().convId === convId);
    diag('controller repair ' + (ok ? 'ok' : 'failed'));
    return ok;
  };
  const store = () => window.__zaloStore;
  const myId = () => safe(() => store().getState().user.userId, '') || '';
  let meId = '';                       // refreshed once per flush
  const meNow = () => meId || myId();
  const convOf = (id) => safe(() => store().getState().conversations.alls[id], null);
  const isGroupId = (id) => typeof id === 'string' && id.startsWith('g');
  const nameOf = (uid) => (!uid ? '' : safe(() => S.friends && S.friends.getDName(uid), '') || '');
  const avatarOf = (uid) => (!uid ? '' : safe(() => S.friends && S.friends.getAvatar(uid), '') || '');
  // Module-cache lookups for the reaction popup, done in one throttled pass (misses are not rescanned for 3s):
  //   S.profile      the official profile service (`UiPd.default`): `getMiniInfo(uid)` + `getProfileFriendByIds(uids, src)`
  //   S.profileFetch module "7itQ" export `b(uids)` → Promise<bool>: fetches mini info for uids lacking name/avatar,
  //                  sharing one promise per uid
  //   S.codes        SRC_GET_PROFILE;  S.emojiCfg  the config object that holds `emojiRC` (icon text → sprite cell)
  let lastScan = 0, warnedCodes = false;
  const scanModules = () => {
    if (S.profile && S.profileFetch && S.codes && S.emojiCfg) return;
    if (Date.now() - lastScan < 3000) return;
    lastScan = Date.now();
    if (typeof window.__zaloEachExport !== 'function' || !window.__zaloRequire) return;
    const fits = (o) => !!o && typeof o.getMiniInfo === 'function' && typeof o.getProfileFriendByIds === 'function';
    safe(() => window.__zaloEachExport(window.__zaloRequire, (ex) => {
      if (!ex || (typeof ex !== 'object' && typeof ex !== 'function')) return;
      try {
        if (!S.profile) { if (fits(ex.default)) S.profile = ex.default; else if (fits(ex)) S.profile = ex; }
        if (!S.profileFetch && typeof ex.b === 'function') { const src = String(ex.b); if (src.includes('getProfileFriendByIds') && src.includes('FETCH_MINI_INFO')) S.profileFetch = ex.b; }
        if (!S.codes && own(ex, 'SRC_GET_PROFILE') && ex.SRC_GET_PROFILE) S.codes = ex.SRC_GET_PROFILE;
        if (!S.emojiCfg) for (const o of [ex, ex.default]) { if (o && typeof o === 'object' && o.emojiRC && typeof o.emojiRC === 'object' && Object.keys(o.emojiRC).length) { S.emojiCfg = o; break; } }
      } catch {}
    }), null);
    if (!S.codes && !warnedCodes && ++scanMisses >= 3) { warnedCodes = true; diag('SRC_GET_PROFILE not found'); }
  };
  let scanMisses = 0;
  const profileService = () => {
    if (S.profile) return S.profile;
    if (S.friends && typeof S.friends.getMiniInfo === 'function' && typeof S.friends.getProfileFriendByIds === 'function') return (S.profile = S.friends);
    scanModules();
    return S.profile || null;
  };

  // ---- message mapping ----
  const parseJSON = (v) => { if (v && typeof v === 'object') return v; if (typeof v !== 'string' || !v) return {}; try { const r = JSON.parse(v); return r && typeof r === 'object' ? r : {}; } catch { return {}; } };
  const str = (v) => (typeof v === 'string' ? v : '');
  const num = (v) => { const n = Number(v); return Number.isFinite(n) ? Math.max(-Number.MAX_SAFE_INTEGER, Math.min(Number.MAX_SAFE_INTEGER, n)) : 0; };
  const seconds = (d) => { const n = num(d); return n > 600 ? Math.round(n / 1000) : Math.round(n); };
  const isFakeId = (id) => !id || String(id).includes('_') || String(id) === '0';
  // Official i18n strings (`lang_vi.json`) used by the official preview / card renderers. Kept verbatim; the app is Vietnamese.
  const FALLBACK = {
    photo: '[Hình ảnh]', sticker: '[Sticker]', gif: '[GIF]', video: '[Video]', voice: '[Tin nhắn thoại]', file: '[Tệp]', folder: '[Thư mục]',
    link: '[Link]', stickerSet: '[Bộ sticker]', contactCard: '[Danh thiếp]', location: '[Vị trí]', call: '[Cuộc gọi]', article: '[Bài viết]',
    doodle: '[Vẽ hình]', ecard: '[Thiệp]', poll: '[Bình chọn]', vanish: '[Tin nhắn đã tự xóa]', media: '[Tin nhắn Media]',
    system: '', recalled: '[Tin nhắn đã thu hồi]',
    unsupported: '[Tin nhắn chưa hỗ trợ ở phiên bản hiện tại]',
    decryptFailed: 'Giải mã tin nhắn không thành công.', e2eeWaiting: 'Đang chờ tin nhắn này',
    znsNotSupported: 'Tin nhắn chưa hỗ trợ hiển thị trên phiên bản hiện tại', syncing: '[Tin nhắn đang đồng bộ]', syncFailed: '[Tin nhắn chưa đồng bộ]',
    becameFriends: 'Bạn và $0$ đã trở thành bạn', birthdayToday: 'Hôm nay là sinh nhật của $0$', createdPoll: 'đã tạo bình chọn',
  };
  const stickerURL = (id) => ((S.cfg && S.cfg.stickerUrl) || 'https://api.zaloapp.com/api/emoticon/sticker/webpc?size=130&eid=') + id;

  // Message `msgType`s the bundle defines beyond the ones named in MSG (constants module "1pet", offset ~1663481).
  const MSG_MORE = { ARTICLE: 0, FOLDER: 23, ZINSTANT_OLD: 27, ZINSTANT: 52, ZINSTANT_V2: 53, ERROR_INFO: -5, VANISH: -28, E2EE_DECRYPT_FAILED: -29, E2EE_PENDING_DATA: -30, INFO_CHAT: -1909,
    CALL: 601, STICKER_SET: 602, LINK_CLIENT: 1805, FRIEND_SENT_REQUEST: 2504, SUGGEST_IN_CHAT: 2505, TODO: 2506, TODO_DONE: 2507, KICK_GROUP: 2508, DISBAND_GROUP: 2509, SYNCING: 2510, SYNCING_OUT_OF_RANGE: 2511 };
  // Quoted messages carry the client message type (`CLI_MSG_TYPE_*`) → the matching message type.
  const CLI_TO_MSG = { 1: MSG.TEXT, 31: MSG.VOICE, 32: MSG.PHOTO, 36: MSG.STICKER, 37: MSG.DOODLE, 38: MSG.CONTACT, 40: MSG.CONTACT, 43: MSG.LOCATION, 44: MSG.VIDEO, 45: MSG.UNDO, 46: MSG.FILE, 49: MSG.GIF, 52: MSG_MORE.ZINSTANT, 61: MSG_MORE.ZINSTANT_V2 };

  // Absolute http(s) URL for a thumb / href from a message ('' when it is not one); the official client strips protocols.
  const absUrl = (v) => {
    const u = str(v).trim();
    if (!u) return '';
    if (/^https?:\/\/[^\s/]/i.test(u)) return u;
    if (u.startsWith('//')) return /^\/\/[^\s/]/.test(u) ? 'https:' + u : '';
    // Scheme-less ("www.site.vn/x") → https; anything with another scheme (file:, smb:, javascript:, app schemes) is dropped.
    return /^[\w-]+(\.[\w-]+)+(:\d+)?([/?#]|$)/.test(u) ? 'https://' + u : '';
  };
  const domainOf = (u) => { const m = /^https?:\/\/([^/?#]+)/i.exec(str(u)); return m ? m[1].replace(/^www\./i, '') : ''; };
  const WEEKDAYS = ['Chủ nhật', 'Thứ hai', 'Thứ ba', 'Thứ tư', 'Thứ năm', 'Thứ sáu', 'Thứ bảy'];
  // Official info-message timestamp: "Thứ hai, 05 Tháng 10[/yyyy] lúc 09:30" (year only when not the current one).
  const viDate = (ts) => {
    const d = new Date(ts < 1e12 ? ts * 1000 : ts);
    if (Number.isNaN(d.getTime())) return '';
    const p2 = (n) => String(n).padStart(2, '0');
    const yr = d.getFullYear() === new Date().getFullYear() ? '' : '/' + d.getFullYear();
    return `${WEEKDAYS[d.getDay()]}, ${p2(d.getDate())} Tháng ${p2(d.getMonth() + 1)}${yr} lúc ${p2(d.getHours())}:${p2(d.getMinutes())}`;
  };
  // One `highLightsV2` entry of an info message (`_renderItemReplace`, offset ~143445): type 0 = a person, 1 = a time.
  const highlightText = (h) => {
    if (!h || typeof h !== 'object' || h.type === undefined || h.type === null) return '';
    const type = Number(h.type);
    if (type === 0) {
      const uid = String(h.uid ?? '');
      if (uid && isMeUid(uid)) return 'Bạn';
      return (!h.ignoreNickname && uid && cachedName(uid)) || str(h.dpn);
    }
    if (type === 1) return typeof h.ts === 'number' ? viDate(h.ts) : str(h.dpn);
    return '';
  };
  // `{msg:{vi,en}, highLightsV2:[…]}` → text with the "%N$s" placeholders filled (`getPreviewMsgInfoChat`, offset ~8294950).
  const infoText = (p) => {
    if (!p || typeof p !== 'object') return '';
    const msg = p.msg;
    let s = msg && typeof msg === 'object' ? str(msg.vi) || str(msg.en) : str(msg);
    if (!s) return '';
    (Array.isArray(p.highLightsV2) ? p.highLightsV2 : []).forEach((h, i) => { s = s.split(`%${i + 1}$s`).join(highlightText(h)); });
    return s.replace(/%\d+\$s/g, '').trim();
  };
  const nameDisplay = (uid, fallback) => (uid ? cachedName(String(uid)) : '') || fallback || '';

  // Call messages (`recommened.misscall|calling|receivecall|calltime`, module "r6Qt" offset ~17553477): params JSON
  // {reason, isCaller, calltype (1 = video), duration (s), isEnableCallback}; title / detail strings are the official ones.
  const clockText = (sec) => {
    const t = Math.max(0, Math.floor(sec) || 0), s = t % 60, mi = Math.floor(t / 60) % 60, h = Math.floor(t / 3600);
    return (h > 0 ? `${h} giờ ` : '') + `${mi} phút ${s} giây`;
  };
  const callInfo = (o) => {
    const action = str(o.action), p = parseJSON(o.params);
    const missed = /misscall$/.test(action);
    const caller = p.isCaller !== undefined && p.isCaller !== null ? !!p.isCaller : /calling$/.test(action);
    const video = Number(p.calltype) === 1;
    const reason = Number(p.reason) || 0; // 1 busy · 2 timeout (ringing) · 3 callee rejected · 4/5 caller cancelled
    const duration = num(p.duration ?? o.duration);
    const kindWord = video ? 'video' : 'thoại';
    let title;
    if (caller) {
      title = !missed ? `Cuộc gọi ${kindWord} đi`
        : (reason === 4 || reason === 5) ? 'Bạn đã hủy' : reason === 3 ? 'Người nhận từ chối' : reason === 1 ? 'Người nhận bận' : `Cuộc gọi ${kindWord} đi`;
    } else {
      title = !missed ? `Cuộc gọi ${kindWord} đến` : reason === 3 ? 'Bạn đã từ chối' : 'Bạn bị nhỡ';
    }
    let detail;
    if (!missed) detail = clockText(duration);
    else if (caller && (reason === 0 || reason === 2)) detail = clockText(0);
    else detail = `Cuộc gọi ${kindWord}`;
    const label = caller ? `Cuộc gọi ${kindWord} đi` : (reason === 3 || !missed) ? `Cuộc gọi ${kindWord} đến` : `Cuộc gọi ${kindWord} nhỡ`;
    return { kind: { type: 'call', video, missed, duration: Math.round(duration), title, detail }, text: `[${label}]` };
  };

  // Business card (CONTACT `recommened.user` / `recommened.vip`, module "F1+M" offset ~5102186 + "BP2E"): `params` = the contact's
  // user id, `title` = name at send time (the official card prefers the local friend name), `thumb` = avatar, `description` =
  // JSON {phone, qrCodeUrl, oaShortLink}.
  const contactCardOf = (o, action) => {
    const uid = typeof o.params === 'string' || typeof o.params === 'number' ? String(o.params).trim() : '';
    const d = parseJSON(o.description);
    const name = (uid && nameOf(uid)) || str(o.title);
    const isOA = action === 'recommened.vip';
    return {
      kind: {
        type: 'contactCard', name, uid, avatar: absUrl(o.thumb) || (uid ? avatarOf(uid) : ''),
        phone: str(d.phone), qr: absUrl(d.qrCodeUrl), oaLink: str(d.oaShortLink), isOA,
      },
      text: FALLBACK.contactCard + (name ? ' ' + name : ''),
    };
  };

  // Link card (`recommened.link`, module "SJ2v" offset ~8997823): params JSON {mediaTitle, src, width…}; card title =
  // mediaTitle || href, description shown unless the message text already starts with it, source = params.src || domain.
  const linkOf = (o) => {
    const p = parseJSON(o.params);
    const href = absUrl(o.href); // only http(s) is ever opened (the official `removeMaliciousScheme` / `validOpenUrl` guard)
    const desc = str(o.description);
    const title = str(o.title);
    const showDesc = desc && (!title || title.indexOf(desc.split('...')[0]) < 0);
    return {
      kind: { type: 'link', title: str(p.mediaTitle) || href, url: href, thumbnail: absUrl(o.thumb) || absUrl(p.thumb), description: showDesc ? desc : '', source: str(p.src) || domainOf(href) },
      text: title || (FALLBACK.link + ' ' + (href || str(o.href))),
    };
  };

  // Location (module "9hee"-adjacent class at offset ~1000700): normalized `message` {lat, lo, title, desc, thumb, href}; the official
  // card shows title, desc and a Google map of lat/lo (click → maps.google.com/maps?q=lat,lo).
  const locationOf = (o) => {
    const p = parseJSON(o.params);
    const lat = Number(o.lat ?? p.latitude), lon = Number(o.lo ?? p.longitude);
    const has = Number.isFinite(lat) && Number.isFinite(lon) && !(lat === 0 && lon === 0) && Math.abs(lat) <= 90 && Math.abs(lon) <= 180;
    const title = str(o.title), address = str(o.desc) || str(o.description);
    return {
      kind: { type: 'location', title, address, hasCoordinates: has, latitude: has ? lat : 0, longitude: has ? lon : 0, thumbnail: absUrl(o.thumb) },
      text: FALLBACK.location + (title || address ? ' ' + (title || address) : ''),
    };
  };

  // Reminder inside an e-card (`getDataReminder`, offset ~19984473): params.actions = [{actionId:'action.open.reminder', data: JSON}];
  // data {startTime (ms), msg (quoted title), params{title}, repeat 0 once / 1 daily / 2 weekly / 3 monthly}.
  const reminderOf = (o, p) => {
    const acts = p && Array.isArray(p.actions) ? p.actions : null;
    if (!acts || acts.length !== 1 || !acts[0] || acts[0].actionId !== 'action.open.reminder' || typeof acts[0].data !== 'string') return null;
    const d = parseJSON(acts[0].data);
    if (!Object.keys(d).length) return null;
    const dp = parseJSON(d.params);
    let title = typeof d.msg === 'string' && d.msg.length > 2 ? d.msg.slice(1, d.msg.length - 1) : '';
    title = title || str(dp.title);
    const repeat = ({ 1: 'Nhắc theo ngày', 2: 'Nhắc theo tuần', 3: 'Nhắc theo tháng' })[Number(d.repeat)] || '';
    return { title, start: num(d.startTime), repeat };
  };

  // E-card (ECARD 25; normalizer at offset ~934672; renderer: class at ~247500 "genLayout1/2", new-friend / birthday cards ~229000).
  // message {action, description, href (background), thumb (avatar), title, type, versionEcardNewFr, params (parsed) {actions:[{name,…}], previewTxt, layoutType}}.
  const ecardOf = (m, convId) => {
    const o = m.message && typeof m.message === 'object' ? m.message : {};
    const p = parseJSON(o.params);
    const type = o.type;
    const preview = str(p.previewTxt) || FALLBACK.ecard;
    if (type === '7' || type === 'client.onboarding') return null; // '7' = the official card draws nothing; 'client.onboarding' = the new-account onboarding flow card (its texts are i18n keys and its button starts the official tour), not shown here
    const ty = typeof type === 'string' && /^\d+$/.test(type) ? Number(type) : type; // ECARD_TYPE: 1 birthday · 2/3 friend accepted
    const base = { type: 'ecard', style: 'banner', image: absUrl(o.href), thumb: absUrl(o.thumb), title: str(o.title), description: str(o.description), actions: [], avatars: [], reminderTitle: '', reminderStart: 0, reminderRepeat: '' };
    const partner = isGroupId(convId) ? str(((Array.isArray(p.descInfo) && p.descInfo[0]) || {}).uid) : convId;
    if (ty === 2 || ty === 3) {
      const name = nameDisplay(partner, str(o.title));
      return { kind: Object.assign(base, { style: 'friend', title: name ? FALLBACK.becameFriends.replace('$0$', name.length > 20 ? name.slice(0, 20) + '...' : name) : '', description: '', avatars: [meNow() && avatarOf(meNow()) || myAvatar(), partner && avatarOf(partner)].filter(Boolean) }), text: preview };
    }
    const reminder = reminderOf(o, p);
    if (reminder) return { kind: Object.assign(base, { style: 'reminder', reminderTitle: reminder.title, reminderStart: reminder.start, reminderRepeat: reminder.repeat }), text: preview };
    const actions = (Array.isArray(p.actions) ? p.actions : []).map((a) => str(a && a.name)).filter(Boolean).slice(0, 2);
    if (ty === 1 && !base.title && !base.description) {
      const name = nameDisplay(partner, '');
      return { kind: Object.assign(base, { style: 'birthday', title: name ? FALLBACK.birthdayToday.replace('$0$', name.length > 20 ? name.slice(0, 20) + '...' : name) : '', avatars: [partner && avatarOf(partner)].filter(Boolean) }), text: preview };
    }
    return { kind: Object.assign(base, { actions }), text: preview };
  };

  // OA list message (OA 21, `chat.list.action`, module "9hee" offset ~3601526) and articles (ARTICLE 0): `message` is an array of parts
  // {type: 'l.a.header.only'|'l.a.header.full'|'l.a.child.full', title, description, thumb, action, href}.
  const partsOf = (list, article) => (Array.isArray(list) ? list : []).map((x) => {
    if (!x || typeof x !== 'object') return null;
    const header = article ? false : /^l\.a\.header\./.test(str(x.type));
    const act = str(x.action);
    const openable = !act || act === 'action.open.inapp';
    return { header, title: str(x.title), description: str(x.description), thumb: absUrl(x.thumb), url: openable ? absUrl(x.href) : '' };
  }).filter((x) => x && (x.title || x.thumb));
  const oaOf = (c, article) => {
    const parts = partsOf(c, article);
    const lead = Array.isArray(c) ? c.find((x) => x && /^l\.a\.header\.(only|full)$/.test(str(x.type))) : null;
    const title = article ? FALLBACK.article : str(lead && lead.title);
    if (!parts.length) return { kind: { type: 'text' }, text: article ? FALLBACK.article : FALLBACK.unsupported };
    return { kind: { type: 'oaMessage', parts }, text: title || (article ? FALLBACK.article : FALLBACK.unsupported) };
  };

  // Poll (POLL 26, list component "nr" offset ~324900): message.params JSON {question, pollId, isAnonymous, msg{vi,en}, uid}. One message per
  // poll event (create / vote / update / close / share); the info line is "<author> <msg without %1$s/%2$s>" (info component offset ~320900:
  // "Bạn" for mine, "Có thành viên" for anonymous events, else the sender's name). The options / votes live in the poll service:
  // poll-adapter.js (`window.__zaloPoll`) reads them by `pollId`; this card carries only the ids and the question.
  const pollOf = (c, m, convId) => {
    const o = c && typeof c === 'object' && !Array.isArray(c) ? c : {};
    const p = parseJSON(o.params);
    const question = str(o.title) || str(p.question);
    const rawMsg = p.msg && typeof p.msg === 'object' ? (str(p.msg.vi) || str(p.msg.en)) : '';
    const from = String(m.fromUid ?? m.uidFrom ?? '');
    const uid = str(p.uid) || from;
    let header = '';
    if (rawMsg) {
      const anonymousWho = !!p.isAnonymous && !rawMsg.includes('%1$s');
      const who = isMeUid(from) ? 'Bạn' : anonymousWho ? 'Có thành viên' : nameDisplay(from, '');
      const rest = rawMsg.replace('%1$s', '').replace('%2$s', '').replace('Có thành viên', '').replace(/\s+/g, ' ').trim();
      header = [who, rest].filter(Boolean).join(' ');
    } else if (uid && !p.isAnonymous) {
      header = (isMeUid(uid) ? 'Bạn' : nameDisplay(uid, '')) + ' ' + FALLBACK.createdPoll;
    }
    const pollId = typeof p.pollId === 'number' || typeof p.pollId === 'string' ? String(p.pollId) : '';
    return { kind: { type: 'poll', question, header, anonymous: !!p.isAnonymous, pollId, conversationId: convId }, text: FALLBACK.poll + (question ? ' ' + question : '') };
  };

  // ZInstant (ZNS) messages (52/27 v1, 53 v2): readers in lazy chunk 18 — v1 metadata = parsed `message.params`, v2 = parsed
  // `message.zinstant_msg`; `customMsg {msg{vi,en}, highLightsV2}` is the official text form (collapsed bubble / preview).
  // The full layout is drawn by the official zinstant engine (not available natively): title / text / thumb of the metadata are shown.
  const zinstantOf = (t, o) => {
    const meta = t === MSG_MORE.ZINSTANT_V2 ? parseJSON(o.zinstant_msg) : parseJSON(o.params);
    const custom = meta.customMsg && typeof meta.customMsg === 'object' ? meta.customMsg : {};
    const body = infoText(custom);
    const title = str(o.title);
    const description = str(o.description) || body;
    const thumb = absUrl(o.thumb);
    let text = title && body === title ? '' : description;
    // Nothing usable in the metadata: the official `STR_MESSAGE_ZNS_NOT_SUPPORT_DISPLAY`.
    if (!title && !text && !thumb) text = FALLBACK.znsNotSupported;
    return { kind: { type: 'zinstant', title, text, thumb }, text: body || title || FALLBACK.media };
  };

  // Hidden: cards the official client does not draw. mapAll drops them.
  const HIDDEN = { kind: null, text: '' };

  // Returns {kind, text} (kind null = draws nothing).
  const mapContent = (m, convId) => {
    const t = Number(m.msgType);
    const c = m.message;
    const o = c && typeof c === 'object' && !Array.isArray(c) ? c : {};
    const p = parseJSON(o.params);
    const caption = str(o.title) || str(o.description);
    const asText = typeof c === 'string' ? c : '';
    const notice = (symbol, text) => (text ? { kind: { type: 'notice', symbol, text }, text } : HIDDEN);
    switch (t) {
      case MSG.TEXT:
        if (o.action === 'recommened.link' && absUrl(o.href)) return linkOf(o);
        if (o.action === 'msginfo.actionlist') { const txt = infoText(p) || str(o.title); return notice('info.circle', txt); }
        return { kind: { type: 'text' }, text: asText || str(o.title) || str(o.msg) || str(o.description) };
      case MSG.PHOTO: case MSG.PHOTO_2:
        return { kind: { type: 'photo', url: o.normalUrl || o.hdUrl || o.oriUrl || o.thumbUrl || str(o.href) || str(o.thumb), width: num(p.width || o.width), height: num(p.height || o.height) }, text: str(o.title) || FALLBACK.photo };
      case MSG.DOODLE:
        return { kind: { type: 'photo', url: str(o.href) || str(o.thumb), width: num(p.width), height: num(p.height) }, text: FALLBACK.doodle };
      case MSG.STICKER: case MSG.STICKER_2: case MSG.STICKER_GROUP:
        return { kind: { type: 'sticker', url: o.id ? stickerURL(o.id) : '' }, text: FALLBACK.sticker };
      case MSG.GIF:
        return { kind: { type: 'gif', url: str(o.href) || str(o.thumb) }, text: FALLBACK.gif };
      case MSG.VIDEO:
        return { kind: { type: 'video', thumbnail: str(o.thumbUrl) || str(o.thumb), url: str(o.oriUrl) || str(o.href) || str(o.videoUrl), duration: seconds(p.duration || o.duration) }, text: FALLBACK.video };
      case MSG.VOICE:
        return { kind: { type: 'voice', url: str(o.href), duration: seconds(p.duration || o.duration) }, text: FALLBACK.voice };
      case MSG.FILE: case MSG_MORE.FOLDER:
        return { kind: { type: 'file', name: str(o.title), size: num(p.fileSize || o.fileSize), url: str(o.href) }, text: p.fType === 2 || t === MSG_MORE.FOLDER ? FALLBACK.folder : FALLBACK.file };
      case MSG.LOCATION:
        return locationOf(o);
      case MSG.UNDO: case MSG.DEL_EVERYONE:
        return { kind: { type: 'recalled' }, text: FALLBACK.recalled };
      case MSG.INFO: case MSG.GROUP_NOTI: case MSG_MORE.ERROR_INFO: case MSG_MORE.FRIEND_SENT_REQUEST: case MSG_MORE.SUGGEST_IN_CHAT:
      case MSG_MORE.KICK_GROUP: case MSG_MORE.DISBAND_GROUP: {
        const txt = asText || caption;
        return txt ? { kind: { type: 'system' }, text: txt } : HIDDEN;
      }
      case MSG_MORE.INFO_CHAT: {
        // getPreviewMsgInfoChat: params.msg[lang] with highlights, else message.title.
        const txt = infoText(p) || str(o.title) || FALLBACK.unsupported;
        return notice('info.circle', txt);
      }
      case MSG_MORE.TODO: case MSG_MORE.TODO_DONE: {
        // Normalizer (offset ~934672): `message` is the text (string) or {message, params:{…item}}; getPlainText returns either.
        // Without text, fall back to the item's own title (list-component shape `params.params` / `params.item`).
        const inner = o.params && typeof o.params === 'object' ? o.params : p;
        const item = [inner.params, inner.item, inner].find((x) => x && typeof x === 'object' && (x.title || x.content || x.name)) || {};
        const txt = asText || str(o.message) || str(item.title) || str(item.content) || str(item.name);
        return notice('checklist', txt || 'Công việc');
      }
      case MSG_MORE.VANISH:
        return notice('timer', FALLBACK.vanish);
      case MSG_MORE.SYNCING:
        return notice('arrow.triangle.2.circlepath', FALLBACK.syncing);
      case MSG_MORE.SYNCING_OUT_OF_RANGE:
        return notice('exclamationmark.arrow.triangle.2.circlepath', FALLBACK.syncFailed);
      case MSG_MORE.E2EE_DECRYPT_FAILED:
        return { kind: { type: 'placeholder', symbol: 'lock.trianglebadge.exclamationmark', text: FALLBACK.decryptFailed }, text: FALLBACK.decryptFailed };
      case MSG_MORE.E2EE_PENDING_DATA:
        return { kind: { type: 'placeholder', symbol: 'lock', text: FALLBACK.e2eeWaiting }, text: FALLBACK.e2eeWaiting };
      case MSG.ECARD:
        return ecardOf(m, convId) || HIDDEN;
      case MSG.POLL:
        return pollOf(c, m, convId);
      case MSG.OA:
        return oaOf(c, false);
      case MSG_MORE.ARTICLE:
        return oaOf(c, true);
      case MSG_MORE.ZINSTANT: case MSG_MORE.ZINSTANT_OLD: case MSG_MORE.ZINSTANT_V2:
        return zinstantOf(t, o);
      case MSG_MORE.CALL:
        return callInfo(o);
      case MSG_MORE.STICKER_SET:
        return { kind: { type: 'stickerSet', title: str(o.title) || str(o.description), thumb: absUrl(o.thumb) }, text: FALLBACK.stickerSet + (str(o.title) ? ' ' + str(o.title) : '') };
      case MSG_MORE.LINK_CLIENT:
        if (absUrl(o.href)) return linkOf(o);
        return { kind: { type: 'unsupported', rawType: str(m.originMsgType) || String(t) }, text: caption || FALLBACK.unsupported };
      case MSG.CONTACT: {
        // The official bubble switches on message.action (offset ~1104817).
        const action = str(o.action);
        if (/^recommened\.(misscall|calling|receivecall|calltime)$/.test(action)) return callInfo(o);
        if (action === 'recommened.link') return absUrl(o.href) ? linkOf(o) : { kind: { type: 'text' }, text: str(o.title) };
        if (action === 'recommened.stickerset') return { kind: { type: 'stickerSet', title: str(o.title) || str(o.description), thumb: absUrl(o.thumb) }, text: FALLBACK.stickerSet + (str(o.title) ? ' ' + str(o.title) : '') };
        if (action === 'recommened.user' || action === 'recommened.vip' || action === 'recommened.contact' || (typeof o.params === 'string' && o.params && !action)) return contactCardOf(o, action);
        if (absUrl(o.href)) return linkOf(o);
        return { kind: { type: 'unsupported', rawType: str(m.originMsgType) || String(t) }, text: caption || FALLBACK.unsupported };
      }
      default: {
        if (asText) return { kind: { type: 'text' }, text: asText };
        return { kind: { type: 'unsupported', rawType: str(m.originMsgType) || String(t) }, text: caption || FALLBACK.unsupported };
      }
    }
  };

  // Quote banner text, as the official quote component builds it (offset ~7753800): getPlainText over the quoted message's
  // type (`cliMsgType`, CLI_MSG_TYPE_*) and `attach` (JSON of its content); text quotes use `msg`.
  const quoteText = (q) => {
    const cli = Number(q.cliMsgType);
    const t = CLI_TO_MSG[cli] !== undefined ? CLI_TO_MSG[cli] : cli;
    const msg = typeof q.msg === 'string' ? q.msg : (q.msg && typeof q.msg === 'object' ? str(q.msg.title) : '');
    const a = typeof q.attach === 'string' ? parseJSON(q.attach) : (q.attach && typeof q.attach === 'object' ? q.attach : {});
    const title = str(a.title) || str(q.msg && q.msg.title) || (cli === 1 ? '' : msg);
    const tail = (label) => (title ? label + ' ' + title : label);
    switch (t) {
      case MSG.TEXT: return a.action === 'rtf' && a.title ? str(a.title) : msg;
      case MSG.PHOTO: case MSG.PHOTO_2: return tail(FALLBACK.photo);
      case MSG.STICKER: case MSG.STICKER_2: return FALLBACK.sticker;
      case MSG.DOODLE: return FALLBACK.doodle;
      case MSG.GIF: return FALLBACK.gif;
      case MSG.VOICE: return FALLBACK.voice;
      case MSG.VIDEO: return tail(FALLBACK.video);
      case MSG.FILE: return tail(a.fType === 2 ? FALLBACK.folder : '[File]');
      case MSG.LOCATION: return tail(FALLBACK.location);
      case MSG.UNDO: return 'Tin nhắn đã thu hồi';
      case MSG.CONTACT: {
        const act = str(a.action);
        if (act === 'recommened.link' || cli === 40) return tail(FALLBACK.link);
        if (/^recommened\.(misscall|calling|receivecall|calltime)$/.test(act)) return callInfo(a).text;
        if (act === 'recommened.stickerset') return tail(FALLBACK.stickerSet);
        const uid = typeof a.params === 'string' ? a.params : '';
        return FALLBACK.contactCard + ' ' + ((uid && nameOf(uid)) || str(a.title) || msg);
      }
      case MSG_MORE.ZINSTANT: case MSG_MORE.ZINSTANT_OLD: case MSG_MORE.ZINSTANT_V2: return infoText(parseJSON(a.params).customMsg) || FALLBACK.media;
      case MSG.ECARD: return str(parseJSON(a.params).previewTxt) || FALLBACK.ecard;
      case MSG.POLL: return FALLBACK.poll + ' ' + (title || str(parseJSON(a.params).question));
      default: return msg;
    }
  };

  const mapQuote = (m) => {
    let q = m.quote;
    if (!q) return null;
    if (typeof q === 'string') q = parseJSON(q);
    if (!q || typeof q !== 'object' || !Object.keys(q).length) return null;
    const owner = String(q.ownerId ?? q.uidFrom ?? '');
    const mine = owner === '0' || owner === meNow();
    let text = safe(() => quoteText(q), '') || '';
    if (!text) text = str(q.attach) ? FALLBACK.photo : FALLBACK.unsupported;
    return { senderName: str(q.fromD) || (mine ? myName() : nameOf(owner)) || '', text: text.slice(0, 200) };
  };

  // Official message.mentions: [{uid, pos, len, type}] (type 0 user / 1 all, uid '-1' = all).
  const mapMentions = (m, text) => {
    let list = m.mentions;
    if (typeof list === 'string') { try { list = JSON.parse(list); } catch { list = null; } }
    if (!Array.isArray(list) || !list.length) return [];
    const out = [];
    for (const x of list) {
      if (!x || x.uid === undefined || x.uid === null) continue;
      const pos = Number(x.pos), len = Number(x.len);
      if (!Number.isInteger(pos) || !Number.isInteger(len) || pos < 0 || len <= 1 || pos + len > text.length) continue;
      const uid = String(x.uid);
      out.push({ uid, pos, len, isAll: uid === '-1' || Number(x.type) === 1 });
    }
    return out;
  };

  const myName = () => safe(() => { const u = store().getState().user; return u.displayName || u.zaloName || ''; }, '');
  const myAvatar = () => safe(() => store().getState().user.avatar, '') || '';

  const mapStatus = (m, mine) => {
    if (!mine) return 'sent';
    const s = Number(m.status);
    if (s === ST.LOCAL || s <= -20) return 'sending';
    if (s === ST.FAIL || s === ST.CANCEL) return 'failed';
    if (s === ST.DELIVERED) return 'delivered';
    if (s === ST.SEEN || s === ST.READ || s === ST.AFTER_READ) return 'seen';
    return 'sent';
  };

  // Official count handling (module dG4g export `a`): parseInt, anything unparseable adds nothing.
  const countOf = (v) => { const n = typeof v === 'number' ? Math.floor(v) : parseInt(v, 10); return Number.isFinite(n) ? n : 0; };
  // `{ uid: { rType: count } }` (uid '0' = me) → Map<uid, Map<rType, count>> with me under my own uid.
  // Every type with a positive count is kept (totals include types that have no icon).
  const reactorTable = (rec) => {
    const table = new Map();
    if (!rec || !rec.reactions || typeof rec.reactions !== 'object') return table;
    for (const [rawUid, byType] of Object.entries(rec.reactions)) {
      if (!byType || typeof byType !== 'object') continue;
      const uid = rawUid === '0' ? (meNow() || '0') : rawUid;
      for (const [rType, count] of Object.entries(byType)) {
        const n = countOf(count);
        if (n <= 0 || Number(rType) < 0) continue;
        const row = table.get(uid) || new Map();
        row.set(rType, (row.get(rType) || 0) + n);
        table.set(uid, row);
      }
    }
    return table;
  };
  const isMeUid = (uid) => uid === '0' || (!!meNow() && uid === meNow());
  // Cheap, cache-only name lookup (no network): friends cache, then the profile service's mini info.
  const miniName = (uid) => {
    const mini = safe(() => profileService().getMiniInfo(uid), null);
    return str(mini && (mini.dName || mini.displayName || mini.zaloName || mini.zName));
  };
  const cachedName = (uid) => (isMeUid(uid) ? myName() : (nameOf(uid) || miniName(uid)));

  const mapReactions = (m) => {
    const table = reactorTable(reactionsById.get(String(m.msgId)));
    if (!table.size) return [];
    const byType = new Map();
    for (const [uid, row] of table) {
      for (const [t, n] of row) {
        const icon = iconInfo(t);
        if (!icon) continue; // no icon: counted in the popup totals, no chip
        const e = byType.get(t) || Object.assign({ count: 0, includesMe: false, uids: [] }, icon);
        e.count += n;
        if (isMeUid(uid)) e.includesMe = true;
        if (!e.uids.includes(uid)) e.uids.push(uid);
        byType.set(t, e);
      }
    }
    // `names` (≤3, me first as "Bạn" = STR_YOU_2) feeds the chip tooltip; `people` = distinct reactors.
    return [...byType.values()].map((e) => {
      const ordered = e.uids.slice().sort((a, b) => Number(isMeUid(b)) - Number(isMeUid(a)));
      const names = [];
      for (const uid of ordered) { const n = isMeUid(uid) ? 'Bạn' : cachedName(uid); if (n && names.length < 3) names.push(n); }
      return { type: e.type, key: e.key, emoji: e.emoji, image: e.image, count: e.count, includesMe: e.includesMe, names, people: e.uids.length };
    });
  };

  const mapOne = (m, convId, idOverride) => {
    const fromUid = String(m.fromUid ?? m.uidFrom ?? '');
    const mine = fromUid === '0' || (!!meNow() && fromUid === meNow());
    const cli = String(m.cliMsgId ?? '');
    const validCli = cli && cli !== '0' && cli !== 'undefined';
    const server = String(m.msgId ?? '');
    const id = idOverride || (mine ? (validCli ? cli : server) : (!isFakeId(server) ? server : cli));
    const sender = mine ? meNow() : fromUid;
    let content;
    try { content = mapContent(m, convId); } catch (e) {
      diag('mapContent ' + scrubErr(e));
      content = { kind: { type: 'unsupported', rawType: str(m.originMsgType) || String(m.msgType) }, text: FALLBACK.unsupported };
    }
    const { kind, text } = content;
    if (!kind) return null; // a card the official client draws nothing for
    let ts = num(m.sendDttm || m.serverTime || m.ts || m.localDttm);
    if (ts && ts < 1e12) ts *= 1000;
    // Card buttons (card-actions-adapter.js): {buttons:[{ref,label,enabled,help}], stickers:bool} merged into the message.
    const cardExtra = safe(() => (window.__zaloCardActions ? window.__zaloCardActions.describe(m, convId, kind) : null), null);
    // Context-menu actions (message-actions-adapter.js): forward / recall / delete / pin / star, with the starred and pinned state.
    const menu = safe(() => (window.__zaloMsgActions ? window.__zaloMsgActions.describe(m, convId) : null), null);
    return Object.assign({
      id, conversationId: convId, senderId: sender,
      senderName: mine ? myName() : (str(m.dName) || nameOf(fromUid)),
      senderAvatar: mine ? myAvatar() : avatarOf(fromUid),
      isMine: mine, kind, text, date: ts, status: mapStatus(m, mine),
      quote: safe(() => mapQuote(m), null), reactions: safe(() => mapReactions(m), []),
      mentions: safe(() => mapMentions(m, text), []),
      isE2EE: num(m.e2eeStatus) >= 3000 && num(m.e2eeStatus) < 4000,
      menu,
    }, cardExtra || {});
  };

  // Maps the official messages of a conversation to rows (one per album photo). The result of a message is memoised by its
  // official object: the Redux store replaces a message object when it changes, so a tick that only appends a message or
  // updates one leaves every other object as it was, and mapping (card / menu description, params parsing, JSON signature)
  // runs for the changed ones only. A store that updates a message in place is caught by `stamp` (the fields a status,
  // star, reaction-count or sync change touches, plus the identity of the content / quote / mentions). Anything mapped from
  // outside the message (names, avatars, pins, the conversation's own flags) comes with a `remapAll` flush (`all`: every
  // message is mapped again), and a changed reaction drops the memo of its message (`invalidate`).
  const mapMemo = new WeakMap();  // official message object → { stamp, rows: [{row, sig}] }
  const stampOf = (m) => {
    const list = Array.isArray(m.message) ? m.message : null;
    let s = `${m.msgId}|${m.cliMsgId}|${m.status}|${m.msgType}|${m.e2eeStatus}|${m.staredDttm}|${m.sendDttm}|${m.dName}|${m.ttl}|${m.fromUid}`;
    if (list) for (const c of list) s += c && typeof c === 'object' ? `|${c.msgId}|${c.cliMsgId}|${c.status}|${c.staredDttm}` : '|';
    return s;
  };
  const rowsOf = (m, convId) => {
    const rows = [];
    if (Number(m.msgType) === MSG.PHOTO_GROUP && Array.isArray(m.message)) {
      const parentId = mapOne(m, convId).id;
      m.message.forEach((child, i) => {
        if (!child) return;
        const c = Object.assign({}, m, child, { msgType: MSG.PHOTO, fromUid: child.fromUid ?? m.fromUid, status: child.status ?? m.status });
        const j = mapOne(c, convId);
        if (j.id === parentId || !(child.msgId || child.cliMsgId)) j.id = parentId + '#' + i;
        rows.push(j);
      });
    } else {
      const j = mapOne(m, convId);
      if (j) rows.push(j);
    }
    return rows.map((row) => ({ row, sig: JSON.stringify(row) }));
  };
  // → [{row, sig}] in message order; `all` maps every message afresh.
  const mapAll = (list, convId, all) => {
    const out = [];
    const seen = new Set();
    for (const m of list) {
      if (!m || typeof m !== 'object') continue;
      try {
        const stamp = stampOf(m);
        const hit = all ? null : mapMemo.get(m);
        let rows;
        if (hit && hit.stamp === stamp && hit.convId === convId && hit.contents === m.message && hit.quote === m.quote && hit.mentions === m.mentions) rows = hit.rows;
        else { rows = rowsOf(m, convId); mapMemo.set(m, { stamp, convId, contents: m.message, quote: m.quote, mentions: m.mentions, rows }); }
        for (const r of rows) { if (seen.has(r.row.id)) continue; seen.add(r.row.id); out.push(r); }
      } catch (e) { diag('mapOne ' + scrubErr(e)); } // one bad message must not stall the conversation
    }
    return out;
  };

  // ---- reactions cache (official reaction cache; keyed by server msgId) ----
  const reactionsById = new Map();
  const reactionFetched = new Set();
  const profileTried = new Set();     // reactor uids already handed to the profile fetch (no per-message network)
  let hookedReactions = false;
  // Past the cap both maps are dropped together, so the open conversation's chips are fetched again right away.
  const resetReactionCache = () => { reactionsById.clear(); reactionFetched.clear(); };
  // Reactor profiles for tooltips: each uid is tried once; the official fetch shares promises per uid.
  const warmReactors = (recs) => {
    const uids = [];
    for (const rec of recs) for (const uid of reactorTable(rec).keys()) if (!isMeUid(uid) && !profileTried.has(uid)) { profileTried.add(uid); uids.push(uid); }
    if (!uids.length) return;
    if (profileTried.size > 5000) profileTried.clear();
    ensureProfiles(uids).then((changed) => { if (changed) remapAll(); }).catch(() => {});
  };
  const hookReactions = () => {
    if (hookedReactions || !S.reactCache) return;
    hookedReactions = true;
    S.reactCache.addUpdateReactListener((rec) => {
      const r = (Array.isArray(rec) ? rec : [rec]).filter((x) => x && x.rMsgId);
      if (reactionsById.size > 5000) resetReactionCache();
      for (const x of r) reactionsById.set(String(x.rMsgId), x);
      warmReactors(r);
      // Only a reaction on a loaded message of the open conversation changes what Swift shows.
      const ids = r.map((x) => String(x.rMsgId)).filter((sid) => track.serverIds.has(sid));
      if (ids.length) { invalidate(ids); dirty = true; schedule(); }
    });
  };
  // A photo group is reacted per photo: the official reactions are keyed by each child's msgId.
  const reactionIdsOf = (m) => {
    const ids = [String(m && m.msgId || '')];
    if (m && Number(m.msgType) === MSG.PHOTO_GROUP && Array.isArray(m.message)) for (const c of m.message) if (c && c.msgId) ids.push(String(c.msgId));
    return ids;
  };
  const fetchReactions = (ids) => {
    const todo = ids.filter((id) => !isFakeId(id) && !reactionFetched.has(id));
    if (!todo.length || !S.reactCache) return;
    todo.forEach((id) => reactionFetched.add(id));
    Promise.resolve(S.reactCache.getMessageReactions(todo)).then((res) => {
      if (reactionsById.size > 5000) resetReactionCache();
      const recs = [];
      const ids = [];
      for (const [id, rec] of Object.entries(res || {})) if (rec) { reactionsById.set(String(id), rec); recs.push(rec); ids.push(String(id)); }
      warmReactors(recs);
      if (ids.length) { invalidate(ids); dirty = true; schedule(); }
    }).catch((e) => { todo.forEach((id) => reactionFetched.delete(id)); diag('reactions: ' + scrubErr(e)); });
  };

  // ---- typing ----
  let hookedTyping = false;
  const hookTyping = () => {
    if (hookedTyping || !S.typing || !S.friends) return;
    hookedTyping = true;
    try {
      const original = S.typing.addItemTyping;
      S.typing.addItemTyping = function (item) {
        const result = original.apply(this, arguments);
        try {
          // Mirror the official `_canAdd`: only items it accepted (typing display enabled, not a duplicate)
          // end up in `mapIdTyping`.
          if (item && item.conId && (!item.action || item.action === 'typing') && this.mapIdTyping && this.mapIdTyping[item.conId] === item) {
            const conId = String(item.conId);
            const uid = String(item.userId || item.uid || (isGroupId(conId) ? '' : conId));
            const name = uid && uid !== myId() ? nameOf(uid) : '';
            if (name) post({ page: 'main', typing: { convId: conId, name } });
          }
        } catch {}
        return result;
      };
      const removeOriginal = S.typing.removeItemTyping;
      S.typing.removeItemTyping = function (conId) {
        const result = removeOriginal.apply(this, arguments);
        try { if (conId && result) post({ page: 'main', typing: { convId: String(conId), name: '' } }); } catch {}
        return result;
      };
    } catch (e) { hookedTyping = false; diag('typing hook: ' + (e && e.message || e)); }
  };

  // ---- state publishing ----
  const track = { id: null, lastMessages: null, lastList: null, sigs: new Map(), exhausted: false, lastHasMore: null, noGrowth: 0, nameRetries: 0, needsNames: false, reactionScan: null, serverIds: new Set(), fullAt: 0 };
  let dirty = false, timer = null, forceReset = false;
  // `dirty`: a flush is due (the memoised rows stay valid); `remap`: every message is mapped again (state outside the
  // messages changed: names, pins, the conversation's flags).
  let remap = false;
  const FULL_MAP_MS = 10000;
  const remapAll = () => { dirty = true; remap = true; schedule(); };
  // Drops the memoised rows of the loaded messages with these server ids (their reactions changed).
  const invalidate = (ids) => {
    const want = new Set(ids);
    for (const m of track.lastMessages || []) if (m && reactionIdsOf(m).some((sid) => want.has(sid))) mapMemo.delete(m);
  };
  let openSeq = 0, openingId = null;
  const hasMoreOf = (conv) => {
    if (track.exhausted) return false;
    const ml = conv.msgList || {};
    return ml.hasMoreLocal !== false || (ml.hasMoreCloud !== false && ml.hasMoreCloud !== 0 && ml.hasMoreCloud !== undefined);
  };
  const schedule = () => { if (!track.id || timer) return; timer = setTimeout(() => { timer = null; flush(); }, 150); };
  const flush = () => {
    const id = track.id;
    if (!id) return;
    resolveServices();
    meId = myId();
    const conv = convOf(id);
    if (!conv) return; // keep forceReset until the conversation exists in the store
    const messages = conv.messages || [];
    // An empty list while the official load is still in flight is not the truth yet; don't clear the UI.
    if (forceReset && !messages.length && openingId === id) return;
    if (!dirty && !forceReset && messages === track.lastMessages && conv.msgList === track.lastList) return;
    // Everything is mapped again on an explicit refresh, and at least every FULL_MAP_MS on a tick, so what a card or a
    // name shows from state outside the message (a friend request accepted elsewhere, a renamed contact) catches up.
    const now = Date.now();
    const all = remap || forceReset || now - track.fullAt > FULL_MAP_MS;
    if (all) track.fullAt = now;
    dirty = false; remap = false;
    track.lastMessages = messages; track.lastList = conv.msgList;
    if (messages !== track.reactionScan) {
      // Reactions are fetched once per message id (`reactionFetched`): only ids not seen before cost anything.
      track.reactionScan = messages;
      const ids = messages.flatMap(reactionIdsOf);
      track.serverIds = new Set(ids);
      fetchReactions(ids);
    }
    const entries = mapAll(messages, id, all);
    const mapped = entries.map((e) => e.row);
    track.needsNames = mapped.some((j) => !j.isMine && (!j.senderName || !j.senderAvatar));
    const hasMore = hasMoreOf(conv);
    if (forceReset) {
      forceReset = false;
      track.sigs = new Map(entries.map((e) => [e.row.id, e.sig]));
      track.lastHasMore = hasMore;
      track.lastRaw = messages.length;
      post({ page: 'main', chat: { convId: id, messages: mapped, removed: [], hasMore, reset: true } });
      return;
    }
    const next = new Map();
    const changed = [];
    for (const e of entries) {
      next.set(e.row.id, e.sig);
      if (track.sigs.get(e.row.id) !== e.sig) changed.push(e.row);
    }
    const removed = [...track.sigs.keys()].filter((k) => !next.has(k));
    track.sigs = next;
    // Official messages that map to nothing (hidden cards) still count as growth: Swift must learn that an older page arrived.
    const grew = messages.length > (track.lastRaw || 0);
    track.lastRaw = messages.length;
    if (!changed.length && !removed.length && hasMore === track.lastHasMore && !grew) return;
    track.lastHasMore = hasMore;
    post({ page: 'main', chat: { convId: id, messages: changed, removed, hasMore, reset: false, grew: grew && !changed.length && !removed.length } });
  };

  let subscribed = false;
  const subscribe = () => {
    if (subscribed || !store()) return;
    subscribed = true;
    store().subscribe(() => { if (track.id) schedule(); });
    // Names/avatars can arrive after messages: re-check only while some are missing, a bounded number of times.
    setInterval(() => {
      if (track.id && track.needsNames && track.nameRetries < 10) { track.nameRetries++; remapAll(); }
    }, 2500);
  };

  // ---- actions ----
  const waitFor = async (fn, ms = 4000) => { const end = Date.now() + ms; while (Date.now() < end) { const v = fn(); if (v) return v; await sleep(80); } return null; };
  const ready = async () => {
    resolveAttempts = 0; lastResolve = 0; // an explicit action always gets a fresh round of lookups
    const ok = await waitFor(() => resolveServices() && controller(), 8000);
    subscribe();
    return !!ok;
  };
  const findMessage = (convId, id) => {
    const conv = convOf(convId);
    if (!conv) return null;
    const want = String(id);
    for (const m of conv.messages || []) {
      if (!m) continue;
      if (String(m.msgId) === want || String(m.cliMsgId) === want) return m;
      if (Array.isArray(m.message) && Number(m.msgType) === MSG.PHOTO_GROUP) {
        let child = m.message.find((x) => x && (String(x.msgId) === want || String(x.cliMsgId) === want));
        if (!child && want.includes('#')) {
          const [base, idx] = want.split('#');
          if (mapOne(m, convId).id === base) child = m.message[Number(idx)];
        }
        if (child) return Object.assign({}, m, child, { msgType: MSG.PHOTO });
      }
    }
    return null;
  };

  const deactivate = (id) => safe(() => S.loader.cacheMessageLoader.get(id).deActive(), null);

  // Composer mentions → the official list; positions must point at an '@' inside the text.
  const cleanMentions = (list, text) => {
    if (!Array.isArray(list)) return [];
    const seen = new Set();
    return list.map((x) => (x && x.uid !== undefined ? { pos: Number(x.pos), len: Number(x.len), uid: String(x.uid) } : null))
      .filter((x) => x && Number.isInteger(x.pos) && Number.isInteger(x.len) && x.len > 1 && x.pos >= 0
        && x.pos + x.len <= text.length && text.charAt(x.pos) === '@' && !seen.has(x.uid) && seen.add(x.uid))
      .map((x) => ({ pos: x.pos, len: x.len, uid: x.uid, type: x.uid === '-1' ? 1 : 0 }))
      .sort((a, b) => a.pos - b.pos);
  };

  // The chat-box controller a send to `convId` goes through, with that conversation's info → {cc, info, direct}, or
  // 'not-ready' / 'not-open'. `direct` = not the conversation on screen; `needsOpen` refuses that case.
  const boxFor = async (convId, needsOpen) => {
    convId = String(convId);
    if (!(await ready())) { diag('send: services not ready'); return 'not-ready'; }
    // An open of this conversation already in flight is awaited (capped), never restarted.
    if (openingId === convId) await waitFor(() => openingId !== convId, 10000);
    if (!controller() || controller().convId !== convId) repairController(convId);
    let cc = controller();
    // Nothing was ever opened: the registry creates the main controller for this conversation (official getter).
    if (!cc) cc = safe(() => { const reg = chatBoxes(); return reg && reg.getChatBoxControllerByConvId(convId); }, null);
    if (!cc) { diag('send: no chat controller'); return 'not-open'; }
    let info;
    if (cc.convId === convId) info = safe(() => cc._getConversationInfo(), null);
    else {
      // Not the conversation on screen (inline notification reply): the official `_sendMessage` takes the target's
      // conversation info (as `processSendMessageAndCreateTask` does), so any controller can send to it. Nothing is
      // opened or switched — the page keeps showing what Swift shows and no conversation gets marked read.
      if (needsOpen) { diag('send: needs the open conversation'); return 'not-open'; }
      info = convOf(convId) ? safe(() => cc._getConversationInfo(convId), null) : null;
    }
    if (!info) { diag('send: conversation not open'); return 'not-open'; }
    return { cc, info, direct: cc.convId !== convId };
  };

  const doSendText = async (convId, text, quoteMsgId, mentions) => {
    convId = String(convId);
    const box = await boxFor(convId, !!quoteMsgId);
    if (typeof box === 'string') return box;
    const { cc, info, direct } = box;
    try {
      let quoted = false;
      if (quoteMsgId) {
        const target = findMessage(convId, quoteMsgId);
        if (target) { await cc._replyMessage(target, false); quoted = true; }
        else diag('send: quoted message not found');
      }
      const list = isGroupId(convId) ? cleanMentions(mentions, String(text)) : [];
      await cc._processSendMessage(MSG.TEXT, String(text), list, quoted, true, info, true, null, null);
      await sleep(50);
    } catch (e) {
      diag('send failed: ' + scrubErr(e));
      return 'error';
    } finally {
      if (quoteMsgId && !direct) safe(() => cc._quoteBannerData._clear(), null);
      dirty = true; schedule();
    }
    return 'sent';
  };
  let sendChain = Promise.resolve();
  // One send at a time through the controller (text, attachments, cards).
  const serial = (fn) => {
    const run = sendChain.then(fn);
    sendChain = run.catch(() => {});
    return run;
  };
  const refresh = () => remapAll();

  // Official ZTagNameHelper registry (found once in the module cache); SRC_GET_PROFILE comes from `scanModules`.
  let tagRegistry = null;
  const tagHelpers = () => {
    if (tagRegistry) return tagRegistry;
    safe(() => window.__zaloEachExport(window.__zaloRequire, (ex) => {
      if (!tagRegistry && ex && typeof ex === 'object' && own(ex, 'list') && typeof ex.getZTagNameHelperById === 'function') tagRegistry = ex;
    }), null);
    return tagRegistry;
  };
  const profileSrc = () => { scanModules(); return S.codes || { DONT_REQ_SERVER: 2 }; };
  // Module "7itQ" `b(uids)` (official; one shared promise per uid, only uids lacking name/avatar are fetched) →
  // Promise<bool: something was fetched>. Without that export: the same steps here, with in-flight promises kept
  // per uid so concurrent callers await them. The wait is capped, the request itself is not cancelled.
  const profileFlights = new Map();
  const ensureProfiles = async (uids) => {
    const ids = [...new Set(uids.filter(Boolean))];
    if (!ids.length) return false;
    scanModules();
    try {
      if (S.profileFetch) return !!(await Promise.race([Promise.resolve(S.profileFetch(ids)), sleep(4000).then(() => false)]));
      const svc = profileService();
      const src = profileSrc().FETCH_MINI_INFO;
      if (!svc || src === undefined) return false;
      const lacks = (uid) => { const mini = safe(() => svc.getMiniInfo(uid), null); return !mini || !mini.avatar || !miniName(uid); };
      const waiting = new Set(), fresh = [];
      for (const uid of ids.filter(lacks)) { const flight = profileFlights.get(uid); if (flight) waiting.add(flight); else fresh.push(uid); }
      if (fresh.length) {
        const flight = Promise.resolve().then(() => svc.getProfileFriendByIds(fresh, src)).then(() => true)
          .catch((e) => { diag('profiles: ' + scrubErr(e)); return false; })
          .finally(() => fresh.forEach((uid) => { if (profileFlights.get(uid) === flight) profileFlights.delete(uid); }));
        fresh.forEach((uid) => profileFlights.set(uid, flight));
        waiting.add(flight);
      }
      if (!waiting.size) return false;
      return (await Promise.race([Promise.all(waiting), sleep(4000).then(() => [false])])).some(Boolean);
    } catch (e) { diag('profiles: ' + scrubErr(e)); return false; }
  };


  // ---- media resolution: the official photo loader ----
  // A CDN link in a message can be dead (migrated history points at retired `fNN-zpc` hosts, old photos 404).
  // Zalo PC's image component handles that with: local file in ZaloDownloads (`6gCs` locator) → candidates
  // hdUrl / normalUrl / oriUrl (`QualityOnly`) → download to disk through `CloudService.downloadWithMultiSrc`
  // (`loadPC`; falls back to the Zalo Cloud copy when the account has one) → on 404 older than the shelf life
  // (`image.min_shelf_life_*`, 7 days) the "expired" state. `resolveMedia` runs exactly that and reports the
  // outcome to Swift: {state:'ok', path} | {state:'expired'} | {state:'unavailable', reason}.
  const MEDIA = { locator: null, loadPC: null, files: null, expired: null };
  const mediaModules = () => {
    if (MEDIA.locator && MEDIA.loadPC && MEDIA.files) return MEDIA;
    const req = window.__zaloRequire;
    if (!req || typeof window.__zaloEachExport !== 'function') return null;
    window.__zaloEachExport(req, (ex) => {
      if (!ex || (typeof ex !== 'object' && typeof ex !== 'function')) return;
      try {
        if (!MEDIA.locator && ex.b && ex.b.HDUrl === 'hdUrl' && ex.b.ThumbUrl === 'thumbUrl' && ex.a && ex.a.QualityOnly && typeof ex.d === 'function' && ex.d.length === 2 && String(ex.d).includes('uniqBy')) MEDIA.locator = ex;
        if (!MEDIA.loadPC && typeof ex.loadPC === 'function' && String(ex.loadPC).includes('LoadPhotoPC')) MEDIA.loadPC = ex.loadPC;
        if (!MEDIA.files && ex.default && typeof ex.default.fileExists === 'function' && typeof ex.default.getEncodedPathUrl === 'function' && String(ex.default.fileExists).includes('access')) MEDIA.files = ex.default;
        if (!MEDIA.expired && typeof ex.c === 'function' && typeof ex.b === 'function' && String(ex.c).includes('image.min_shelf_life')) MEDIA.expired = ex.c;
      } catch {}
    });
    return MEDIA.locator && MEDIA.loadPC && MEDIA.files ? MEDIA : null;
  };
  // Failure class of a `loadPC` rejection: HTTP status → 'http-404', Chromium net errors (30000 + n) → 'dns' / 'timeout' / 'offline'.
  const mediaFailureClass = (e) => {
    if (!e) return 'other';
    const code = Number(e.code);
    if (Number.isInteger(code) && code >= 100 && code < 600) return 'http-' + code;
    const n = Number(String(e.message || '').replace(/\D/g, ''));
    if (n === 30034 || n === 30063) return 'dns';
    if (n === 30047 || n === 75000 + 5027 || /timeout|tiemout/i.test(String(e.message || ''))) return 'timeout';
    if (n === 30035) return 'offline';
    if (e.name === 'NotReadyError' || (e.constructor && e.constructor.name === 'NotReadyError')) return 'not-ready';
    return 'other';
  };
  // A photo / video listed by the media store (media-store-adapter.js) whose message is not loaded in the chat box: the store's raw item
  // carries what the downloader reads, in the shape of a message.
  const storeMessage = (convId, msgId) => {
    const it = safe(() => window.__zaloMediaStore.item(convId, msgId), null);
    if (!it || !it.message) return null;
    return { msgId: it.msgId, cliMsgId: it.cliMsgId, fromUid: it.fromUid, toUid: it.userId || convId, sendDttm: it.sendDttm, msgType: Number(it.subType) === 2 ? MSG.VIDEO : MSG.PHOTO, message: it.message };
  };
  // The official inline video player (`openFile`, default-login-main-startup-shared-worker-znotification ~1912063) never
  // streams: it plays the local copy `CloudService.downloadWithMultiSrc("runByMsg", msg, …)` saves, with the entry
  // ChatBoxView / Video / Manual / CBVVideoInline and options {caching, duplicate: false, srcAction: Dev, no progress UI}.
  // That path reuses the copy the in-view auto-download already saved (ZaloDownloads/resource/<conv>/video), decrypts an
  // E2EE video (its CDN bytes are ciphertext; the key rides in the URL) and falls back to the Zalo Cloud copy. A
  // personal-cloud message without its key (`checkPCloudError` = "WKSW".a) is not played.
  const VIDEO = { cloud: null, entry: null, consts: null, utils: null, pcloudError: null };
  // The host answers unknown preload globals with catch-all placeholders (any member is a function), which pass every
  // shape test; real modules don't answer a made-up member (same probe as card-actions / zcloud-adapter `real`).
  const real = (o) => !!o && (typeof o === 'object' || typeof o === 'function') && safe(() => o.__olaz_not_a_member__, undefined) === undefined;
  const videoModules = () => {
    if (VIDEO.cloud && VIDEO.entry && VIDEO.consts && VIDEO.utils) return VIDEO;
    const req = window.__zaloRequire;
    if (!req || typeof window.__zaloEachExport !== 'function') return null;
    window.__zaloEachExport(req, (ex) => {
      if (!real(ex)) return;
      try {
        if (!VIDEO.cloud && real(ex.CloudService) && typeof ex.CloudService.getInstance === 'function') VIDEO.cloud = ex.CloudService;
        if (!VIDEO.entry && typeof ex.c === 'function' && real(ex.a) && ex.a.ChatBoxView !== undefined && real(ex.d) && ex.d.CBVVideoInline !== undefined && real(ex.b) && real(ex.e) && real(ex.f)) VIDEO.entry = ex;
        if (!VIDEO.consts && real(ex.default) && real(ex.default.constants) && real(ex.default.constants.DownloadType) && ex.default.constants.DownloadType.Video && real(ex.default.constants.srcAction)) VIDEO.consts = ex.default.constants;
        if (!VIDEO.utils && real(ex.default) && typeof ex.default.getConversationType === 'function' && typeof ex.default.isValidMsgId === 'function') VIDEO.utils = ex.default;
        if (!VIDEO.pcloudError && typeof ex.a === 'function' && typeof ex.b === 'function' && /^function/.test(String(ex.a)) && String(ex.a).includes('isFreev2') && String(ex.a).includes('sendToMeId')) VIDEO.pcloudError = ex.a;
      } catch {}
    });
    return VIDEO.cloud && VIDEO.entry && VIDEO.consts && VIDEO.utils ? VIDEO : null;
  };
  const resolveVideoNow = async (convId, msgId) => {
    const done = (state, extra) => Object.assign({ state }, extra || {});
    if (!(await ready())) return done('unavailable', { reason: 'not-ready' });
    const mods = videoModules();
    if (!mods) return done('unavailable', { reason: 'modules' });
    const msg = findMessage(convId, msgId) || storeMessage(convId, msgId);
    if (!msg || !msg.message || Number(msg.msgType) !== MSG.VIDEO) return done('unavailable', { reason: 'message' });
    if (mods.pcloudError && safe(() => !!mods.pcloudError(msg), false)) return done('unavailable', { reason: 'pcloud' });
    try {
      const b = mods.entry;
      const entry = new b.c(b.a.ChatBoxView).getBuilder().withType(b.f.Video).withMode(b.e.Manual).withCode(b.d.CBVVideoInline)
        .withConvType(b.b[mods.utils.getConversationType(msg.toUid || msg.userId)]).build();
      const res = await mods.cloud.getInstance().downloadWithMultiSrc('runByMsg', msg, {
        entry, type: mods.consts.DownloadType.Video,
        options: { caching: true, duplicate: false, srcAction: mods.consts.srcAction.Dev, showProgress: { progressBar: false, taskBar: false } },
      });
      if (res && res.savePath) return done('ok', { path: String(res.savePath), source: res.isCached ? 'local' : 'download' });
      return done('unavailable', { reason: 'no-path' });
    } catch (e) {
      const cls = mediaFailureClass(e);
      diag('resolveMedia video failed: ' + cls + ' ' + String((e && (e.name + ':' + e.message)) || e).replace(/https?:\/\/\S+/g, '<url>').slice(0, 80));
      return done('unavailable', { reason: cls });
    }
  };
  const mediaFlights = new Map();
  const resolveMediaNow = async (convId, msgId, kind) => {
    const done = (state, extra) => Object.assign({ state }, extra || {});
    if (kind === 'video') return resolveVideoNow(convId, msgId);
    if (kind !== 'photo' && kind !== 'videoThumb') return done('unsupported', { reason: 'kind' });
    if (!(await ready())) return done('unavailable', { reason: 'not-ready' });
    const mods = mediaModules();
    if (!mods) return done('unavailable', { reason: 'modules' });
    const msg = findMessage(convId, msgId) || storeMessage(convId, msgId);
    if (!msg || !msg.message) return done('unavailable', { reason: 'message' });
    const loc = mods.locator;
    let cands = [];
    try {
      if (kind === 'photo') {
        cands = loc.d(loc.a.QualityOnly, msg);
        if (!cands.length) cands = loc.d([loc.b.ThumbUrl], msg);
      } else {
        cands = loc.d([loc.b.ThumbUrl], msg);
      }
    } catch (e) { diag('resolveMedia candidates: ' + (e && e.message || e)); }
    cands = cands.filter((c) => c && c.url);
    if (!cands.length) return done('unavailable', { reason: 'no-source' });
    // 1. A copy the official client already stored.
    for (const c of cands) {
      if (c.localPath && await mods.files.fileExists(c.localPath)) return done('ok', { path: c.localPath, source: 'local', quality: c.type });
    }
    // 2. Download through the official multi-source path, best quality first.
    const classes = [];
    const mediaId = `${msg.cliMsgId}.${msg.fromUid}.${msg.toUid}`;
    for (const c of cands) {
      if (!c.localPath) { classes.push('other'); continue; }
      try {
        await mods.loadPC({ url: c.url, localPath: c.localPath, msgId: msg.msgId, mediaId, sendDttm: msg.sendDttm, timeout: 25000 });
        // `loadPC` resolves only after the official downloader reported the file saved at `localPath`.
        return done('ok', { path: c.localPath, source: 'download', quality: c.type });
      } catch (e) { classes.push(mediaFailureClass(e)); diag('resolveMedia candidate ' + c.type + ' failed: ' + String((e && (e.name + ':' + e.message)) || e).replace(/https?:\/\/\S+/g, '<url>').slice(0, 80)); }
    }
    const gone = classes.every((k) => k === 'http-404' || k === 'http-410' || k === 'dns');
    const old = safe(() => (mods.expired ? !!mods.expired(msg.sendDttm, msg.toUid || convId) : false), false);
    const state = gone && old ? 'expired' : 'unavailable';
    diag(`resolveMedia kind=${kind} state=${state} candidates=${cands.length} classes=${Array.from(new Set(classes)).join(',')}`);
    return done(state, { reason: gone ? 'gone' : (classes[0] || 'other') });
  };
  const resolveMedia = (convId, msgId, kind) => {
    convId = String(convId); msgId = String(msgId); kind = kind || 'photo';
    const key = convId + '|' + msgId + '|' + kind;
    if (mediaFlights.has(key)) return mediaFlights.get(key);
    const flight = Promise.race([
      resolveMediaNow(convId, msgId, kind),
      // A whole video downloads (and decrypts) before it plays.
      sleep(kind === 'video' ? 600000 : 60000).then(() => ({ state: 'unavailable', reason: 'timeout' })),
    ]).catch((e) => { diag('resolveMedia ' + (e && e.message || e)); return { state: 'unavailable', reason: 'error' }; })
      .finally(() => { mediaFlights.delete(key); });
    mediaFlights.set(key, flight);
    return flight;
  };

  const chat = {
    async open(convId) {
      convId = String(convId);
      const seq = ++openSeq;
      openingId = convId;
      const stale = () => seq !== openSeq;
      if (!(await ready())) { diag('open: services not ready'); if (!stale()) openingId = null; return; }
      if (stale()) return;
      const switched = track.id !== convId;
      if (track.id && switched) deactivate(track.id);
      if (switched) { reactionsById.clear(); reactionFetched.clear(); }
      track.id = convId; track.exhausted = false; track.noGrowth = 0; track.nameRetries = 0; track.needsNames = false;
      track.lastMessages = null; track.lastList = null; track.sigs = new Map(); track.reactionScan = null; track.serverIds = new Set();
      forceReset = true; dirty = true;
      schedule();
      try {
        const cc = controller();
        if (!cc || cc.convId !== convId || switched) await S.opener.openConversation(convId);
        if (stale()) return;
        const settled = await waitFor(() => !stale() && convOf(convId) && controller() && controller().convId === convId, 1500);
        if (!settled && !stale()) repairController(convId, true);
        else if (settled) noteBoxFields(controller());
        if (stale()) return;
        await S.loader.getLastMessagesForConversation(convId, {});
        if (stale()) { deactivate(convId); return; }
        // The chat view marks its loader active so the official in-memory message cache follows the conversation.
        safe(() => S.loader.cacheMessageLoader.get(convId).active(), null);
      } catch (e) { diag('open ' + (e && e.message || e)); }
      if (!stale()) { openingId = null; remapAll(); }
    },
    async close(convId) {
      convId = String(convId);
      if (track.id === convId || openingId === convId) { openSeq++; openingId = null; }
      if (track.id === convId) track.id = null;
      deactivate(convId);
      try { if (S.opener) await S.opener.closeConversation(convId); } catch (e) { diag('close ' + (e && e.message || e)); }
    },
    async loadMore(convId) {
      convId = String(convId);
      if (!(await ready())) return;
      const conv = convOf(convId);
      let cc = controller();
      if (conv && track.id === convId && (!cc || cc.convId !== convId) && repairController(convId)) cc = controller();
      if (!conv || !cc || cc.convId !== convId || track.id !== convId) { diag('loadMore: conversation not open'); return; }
      const loading = () => { const ml = (convOf(convId) || {}).msgList || {}; return !!(ml.isLoadingMessageTop || ml.isLoadingMessage); };
      if (loading()) return;
      const count = () => ((convOf(convId) || {}).messages || []).length;
      const before = count();
      let loaded = null;
      try {
        const res = await cc._loadMoreMessages();
        if (Array.isArray(res)) loaded = res.length;
      } catch (e) { diag('loadMore ' + (e && e.message || e)); }
      await waitFor(() => !loading(), 15000);
      await sleep(100);
      if (track.id !== convId) return;
      const grew = count() > before || (loaded || 0) > 0;
      if (grew) track.noGrowth = 0;
      else {
        // Only give up when the official flags agree, or after repeated empty pages.
        const ml = (convOf(convId) || {}).msgList || {};
        const officialDone = ml.hasMoreLocal === false && (ml.hasMoreCloud === false || ml.hasMoreCloud === 0 || ml.hasMoreCloud === undefined);
        if (officialDone || ++track.noGrowth >= 2) track.exhausted = true;
      }
      dirty = true; schedule();
    },
    // Sends share the controller's quote banner: run them one at a time.
    sendText(convId, text, quoteMsgId, mentions) { return serial(() => doSendText(convId, text, quoteMsgId, mentions)); },
    // Group members for the composer's @-popover, through the official suggestion engine.
    async mentionCandidates(convId, query, mentioned) {
      convId = String(convId);
      if (!isGroupId(convId)) return [];
      if (!(await ready()) || !S.groups) return [];
      const registry = tagHelpers();
      if (!registry) return [];
      try {
        const info = await S.groups.getFullInfoGroupById(convId, profileSrc().DONT_REQ_SERVER);
        if (!info || !Array.isArray(info.topMember)) return [];
        const helper = registry.getZTagNameHelperById('composer');
        helper.initState(meNow());
        for (const uid of Array.isArray(mentioned) ? mentioned : []) helper.isMentioned[String(uid)] = true;
        const text = '@' + String(query || '');
        const found = helper.getListSuggestMention(text, text.length, { groupId: info.userId || convId, creatorId: info.creatorId, topMember: info.topMember }) || [];
        return found.filter((x) => x && !x.isCmd && x.id !== undefined).map((x) => {
          const isAll = !!x.isMentionAll || String(x.id) === '-1';
          return { id: String(x.id), name: isAll ? 'All' : (str(x.dName) || nameOf(String(x.id))), avatar: isAll ? '' : (avatarOf(String(x.id)) || str(x.avatar)), isAll };
        });
      } catch (e) { diag('mentionCandidates ' + (e && e.message || e)); return []; }
    },
    // Who reacted to a message ("Biểu cảm" popup): the official reacted list (`{uid:{rType:count}}`) with the
    // popup's own tab / row ordering. Unknown profiles are fetched like module "7itQ" `b(uids)` does
    // (shared per-uid promises, FETCH_MINI_INFO), then re-read from the mini-info cache.
    // → {tabs:[{type,key,emoji,image,total}], users:[{uid,name,avatar,isMe,total,icons:[{type,key,emoji,image,count}]}]},
    //   or null when the answer is unknown (services not ready, error, no reaction data) — never "nobody reacted".
    async reactors(convId, msgId) {
      convId = String(convId);
      if (!(await ready())) return null;
      try {
        const target = findMessage(convId, msgId);
        const sid = String(target ? target.msgId : msgId);
        if (isFakeId(sid)) return { tabs: [], users: [] }; // pending message: nothing to react to yet
        let fetched = false;
        if (S.reactCache) {
          try {
            const res = await Promise.race([Promise.resolve(S.reactCache.getMessageReactions([sid])), sleep(3000).then(() => null)]);
            if (res && typeof res === 'object') { fetched = true; if (res[sid]) reactionsById.set(sid, res[sid]); }
          } catch (e) { diag('reactors fetch: ' + scrubErr(e)); }
        }
        // A failed / timed-out refresh still has the cached entry to show; with neither, the answer is unknown.
        if (!fetched && !reactionsById.has(sid)) return null;
        const table = reactorTable(reactionsById.get(sid));
        if (!table.size) return { tabs: [], users: [] };
        if (await ensureProfiles([...table.keys()].filter((uid) => !isMeUid(uid)))) remapAll();
        const tabs = new Map();           // rType → {…icon, total}
        const users = [];
        for (const [uid, row] of table) {
          const isMe = isMeUid(uid);
          const types = [...row.keys()].sort((a, b) => Number(a) - Number(b));
          const icons = [];
          let total = 0;
          for (const t of types) {
            const n = row.get(t);
            total += n;
            const icon = iconInfo(t);
            if (!icon) continue;
            icons.push(Object.assign({}, icon, { count: n }));
            const tab = tabs.get(t) || Object.assign({}, icon, { total: 0 });
            tab.total += n;
            tabs.set(t, tab);
          }
          icons.sort((a, b) => b.count - a.count); // stable: ties stay in ascending rType order
          const mini = isMe ? null : safe(() => profileService().getMiniInfo(uid), null);
          users.push({
            uid, isMe, name: cachedName(uid) || 'Người dùng Zalo',
            avatar: isMe ? myAvatar() : (avatarOf(uid) || str(mini && mini.avatar)),
            total, icons, firstType: Number(types[0]),
          });
        }
        users.sort((a, b) => (b.total - a.total) || (a.isMe ? -1 : b.isMe ? 1 : a.firstType - b.firstType));
        const tabList = [...tabs.values()].sort((a, b) => (b.total - a.total) || (Number(a.type) - Number(b.type)))
          .map((t) => ({ type: t.type, key: t.key, emoji: t.emoji, image: t.image, total: t.total }));
        diag('reactors: ' + users.length + ' users, ' + tabList.length + ' tabs');
        return { tabs: tabList, users: users.map(({ firstType, ...u }) => u) };
      } catch (e) { diag('reactors ' + scrubErr(e)); return null; }
    },
    // Photo / video-thumbnail whose CDN link failed: the official loader's outcome (see "media resolution").
    resolveMedia(convId, msgId, kind) { return resolveMedia(convId, msgId, kind); },
    async markRead(convId) {
      convId = String(convId);
      if (!(await ready())) return;
      // ChatView may call this right as it opens the conversation: wait for the open to land.
      await waitFor(() => controller() && controller().convId === convId, 3000);
      const cc = controller();
      if (!cc || cc.convId !== convId) return;
      try { await cc.readMessageOfConv(convId); } catch (e) { diag('markRead ' + (e && e.message || e)); }
    },
    async react(convId, msgId, emoji) {
      convId = String(convId);
      if (!(await ready()) || !S.reactSender || !S.reactCache) return;
      const entry = REACTIONS.find((r) => r[2] === emoji || r[2].replace('️', '') === String(emoji).replace('️', ''));
      const target = findMessage(convId, msgId);
      if (!entry || !target || isFakeId(target.msgId)) { diag('react: unsupported emoji or message not found'); return; }
      const reaction = { rType: entry[0], rIcon: entry[1] };
      const clientId = Date.now();
      try {
        S.reactSender.sendReaction(convId, reaction, clientId, target);
        const rec = S.reactCache.generateReactMsg(convId, reaction, clientId, target);
        S.reactCache.onReceiveReactions({ [rec.rMsgId]: rec }, () => {}, 'msg.sendReaction');
      } catch (e) { diag('react ' + (e && e.message || e)); }
      reactionFetched.delete(String(target.msgId));
      setTimeout(() => { fetchReactions([String(target.msgId)]); }, 500);
    },
  };

  // Internals for the card-actions adapter (card-actions-adapter.js attaches `performAction` & co. to `chat`).
  Object.defineProperty(chat, '__core', {
    value: { S, ready, controller, repairController, findMessage, convOf, isGroupId, isMeUid, meNow, myName, myAvatar, parseJSON, str, absUrl, nameOf, avatarOf, diag, scrubErr, safe, own, sleep, waitFor, MSG, boxFor, serial, refresh, chatBoxes },
    enumerable: false,
  });
  window.__zaloChat = chat;
  // Start resolving/subscribing early so typing is captured before any conversation is opened.
  const boot = setInterval(() => { if (resolveServices() && S.friends) { subscribe(); clearInterval(boot); } }, 600);
  setTimeout(() => clearInterval(boot), 120000);
})();
