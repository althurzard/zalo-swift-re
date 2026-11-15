// Olaz conversations adapter (index.html only): list filters, conversation labels ("Phân loại"),
// the stranger-message folder ("Tin nhắn từ người lạ") and the My Documents ("Cloud của tôi") id.
// Posts {page:'main', conversationExtras:{…}} via `zstate`; Swift calls `window.__zaloConversations`.
//
// Everything goes through the official client's own services (nothing is re-implemented):
//
//   list + filters  ConvListController (DI singleton: `onTypeFilterChange`, `onLabelFilterChange`,
//                   `listVisible`, `listFiltered`, `listStrangers`, `typeFilter`, `labelFilters`). Swift picks a
//                   filter, we drive the controller exactly as the official sidebar does and publish the list it
//                   computes (`getList` semantics), so "Ưu tiên / Khác / Chưa đọc / by label" are the official
//                   predicates (`ConvList.filterByUnread/filterByLabel`, archived-chat split, strangers carrying
//                   a label …) and stay live as the controller reacts to previews, unread and label changes.
//   strangers       `listStrangers` = conversations with non-friends (ConvList.groupConversation). Official shows a
//                   single pseudo-row `stranger_box` in the list for strangers I have not answered; strangers I
//                   answered appear inline. Opening the box lists `filterByResponsed(listStrangers, false)`
//                   sorted newest first (the controller's STRANGER type filter) — published as `strangerIds`.
//                   The folder itself has no accept/ignore/block actions in the official client; those are on the
//                   chat banner (Kết bạn / Chặn / Báo xấu).
//   labels          `window._label` (official label manager: `_cache` = [{id,text,color,emoji,offset,createTime,
//                   conversations[]}], `update`, `remove`, `drag`, `updateConversation`, `removeConversation`,
//                   `genId`) with the ActionBuilder payloads the official label editor sends, so changes sync to
//                   the server (version bump) like the official client. A conversation has at most one label.
//   My Documents   config object `{stickerUrl, sendToMeId}`.
(() => {
  'use strict';
  if (!/index\.html$/.test(location.pathname)) return;
  if (window.__zaloConversations) return;
  const post = (state) => { try { window.webkit.messageHandlers.zstate.postMessage(state); } catch {} };
  const diag = (s) => { try { window.webkit.messageHandlers.zlog.postMessage('[conversations] ' + s); } catch {} };
  const safe = (fn, d) => { try { const v = fn(); return v === undefined ? d : v; } catch { return d; } };
  const own = (o, k) => Object.prototype.hasOwnProperty.call(o, k);

  const FILTER = { ALL: 0, UNREAD: 1, STRANGER: 2, FOCUSED: 3, ARCHIVED: 4 }; // Bd.FilterType
  const STRANGER_BOX = 'stranger_box';                                       // Tt.CONV_FILTER.STRANGER
  const TAG_CONV = 128;                                                      // ConversationListActions.TAG_CONV
  // Defaults of the official `chat_label` remote config (module CAXv.default reads the live values).
  const DEFAULT_LIMITS = { maxLabels: 15, maxNameLength: 30, minNameLength: 1, palette: ['#D91B1B', '#F31BC8', '#FF6905', '#FAC000', '#4BC377', '#2AC5BB', '#0068FF', '#6F3FCF'] };

  const S = { ctrl: null, cfg: null, builder: null, limits: null };
  const resolve = () => {
    const req = window.__zaloRequire;
    if (!req || typeof window.__zaloDI !== 'function' || !window.__zaloEachExport) return false;
    if (!S.ctrl) {
      for (const r of window.__zaloDI(req)) {
        const i = r.instance;
        if (i && typeof i === 'object' && typeof i.onTypeFilterChange === 'function' && typeof i.applyLabelFilter === 'function' && Array.isArray(i.listVisible)) { S.ctrl = i; break; }
      }
    }
    if (!S.cfg || !S.builder || !S.limits) {
      window.__zaloEachExport(req, (ex) => {
        if (!ex || typeof ex !== 'object' || ex === window.$capp) return; // $capp is a catch-all stub proxy
        try {
          if (!S.cfg && own(ex, 'stickerUrl') && own(ex, 'sendToMeId')) S.cfg = ex;
          if (!S.builder && ex.ActionBuilder && typeof ex.ActionBuilder.buildCreateActionData === 'function' && Function.prototype.toString.call(ex.ActionBuilder.buildCreateActionData).includes('create')) S.builder = ex.ActionBuilder;
          if (!S.limits && typeof ex.getColorPalette === 'function' && typeof ex.getMaxLabels === 'function' && Array.isArray(ex.getColorPalette())) S.limits = ex;
        } catch {}
      });
    }
    return !!(S.ctrl && S.cfg);
  };
  const mgr = () => window._label && typeof window._label.update === 'function' ? window._label : null;
  const labelCache = () => { const m = mgr(); return m && Array.isArray(m._cache) ? m._cache : null; };

  const limits = () => {
    const l = S.limits, d = DEFAULT_LIMITS;
    const num = (fn, def) => { const v = safe(() => l && l[fn](), def); return typeof v === 'number' && v > 0 ? v : def; };
    const palette = safe(() => l && l.getColorPalette(), null);
    return {
      maxLabels: num('getMaxLabels', d.maxLabels), maxNameLength: num('getMaxLengthOfLabelNames', d.maxNameLength),
      minNameLength: num('getMinLengthOfLabelNames', d.minNameLength),
      palette: Array.isArray(palette) && palette.length ? palette.map(String) : d.palette,
    };
  };

  // ---- snapshot ----
  let lastKey = '', actionSeq = 0, lastAction = null;
  const snapshot = () => {
    const c = S.ctrl, un = c.unreadDataManager, cd = c.convDataManager;
    const cache = labelCache();
    const labels = (cache || safe(() => c.labelDataManager.getAllLabels(), []))
      .filter(Boolean).slice().sort((a, b) => (a.offset || 0) - (b.offset || 0))
      .map((l) => ({ id: String(l.id), name: String(l.text || ''), color: String(l.color || ''), emoji: String(l.emoji || ''), convIds: (l.conversations || []).map(String) }));
    const type = Number(c.typeFilter), labelIds = (c.labelFilters || []).map(String);
    const list = type === FILTER.ALL && labelIds.length === 0 ? c.listVisible : c.listFiltered;
    const strangers = (c.listStrangers || []).map(String);
    const unbox = !!safe(() => c.isUnboxStrangerAccount(), false);
    // STRANGER filter: strangers I have not answered (all of them when the account "unboxes" strangers).
    const notAnswered = unbox ? strangers : strangers.filter((id) => safe(() => cd.isRespondedByMeSync(id) === false, true));
    // Same ordering the controller's STRANGER filter produces (`ConvList.sortConvId`, newest first).
    const folder = safe(() => sortConvIds(notAnswered), null) || notAnswered;
    const unreadOf = (id) => { const u = safe(() => un.getUnreadByConvIdSync(id), null); return (u && (u.smsUnreadCount || 0)) || 0; };
    const unreadChats = folder.filter((id) => unreadOf(id) > 0).length;
    return {
      selfConversationId: String((S.cfg && S.cfg.sendToMeId) || ''),
      limits: limits(),
      labels,
      archivedEnabled: !!c.isEnableArchivedChat,
      filter: { type, labelIds },
      listIds: (list || []).map(String),
      strangerIds: strangers,
      strangerFolderIds: folder.map(String),
      strangerBox: { chats: folder.length, unreadChats, unreadMessages: folder.reduce((a, id) => a + unreadOf(id), 0), newestId: String(c.newestStrangerId || '') },
      unboxStranger: unbox,
      action: lastAction,
    };
  };
  // `ConvList.sortConvId(ids, false, true)` — the sort the official STRANGER filter applies.
  // A miss is not rescanned on every snapshot: the next full module scan waits 1 s, then twice as long after each miss, up to 30 s.
  let convListUtil = null, sortScanAt = 0, sortScanGap = 1000;
  const sortConvIds = (ids) => {
    if (!convListUtil && Date.now() >= sortScanAt) {
      window.__zaloEachExport(window.__zaloRequire, (ex) => {
        try { if (!convListUtil && ex && ex !== window.$capp && ex.ConvList && typeof ex.ConvList.sortConvId === 'function' && Function.prototype.toString.call(ex.ConvList.sortConvId).includes('getConvByIdSync')) convListUtil = ex.ConvList; } catch {}
      });
      if (!convListUtil) { sortScanAt = Date.now() + sortScanGap; sortScanGap = Math.min(sortScanGap * 2, 30000); }
    }
    const out = convListUtil ? convListUtil.sortConvId(ids.slice(), false, true) : null;
    return Array.isArray(out) ? out : null;
  };

  const publish = (force) => {
    if (!resolve()) return;
    let snap;
    try { snap = snapshot(); } catch (e) { diag('snapshot failed: ' + (e && e.name ? e.name : typeof e)); return; }
    const key = JSON.stringify(snap);
    if (!force && key === lastKey) return;
    lastKey = key;
    post({ page: 'main', conversationExtras: snap });
  };
  const timer = setInterval(() => publish(false), 1200);
  setTimeout(() => publish(false), 300);

  const report = (ok, text) => { lastAction = { seq: ++actionSeq, ok, text }; publish(true); };
  const errText = (e) => (e && (e.err_msg || e.message)) || (typeof e === 'string' ? e : '') || 'Không thể cập nhật phân loại. Vui lòng thử lại.';
  const vi = { exist: 'Phân loại đã tồn tại', empty: 'Chưa nhập tên phân loại hội thoại' };
  const findLabel = (id) => { const cache = labelCache() || []; return cache.find((l) => l && String(l.id) === String(id)) || null; };
  const checkName = (name, exceptId) => {
    const L = limits(), t = String(name || '').trim();
    if (t.length < L.minNameLength) return vi.empty;
    if (t.length > L.maxNameLength) return 'Tên phân loại tối đa ' + L.maxNameLength + ' ký tự';
    const dup = (labelCache() || []).some((l) => l && String(l.id) !== String(exceptId) && String(l.text || '').trim().toLowerCase() === t.toLowerCase());
    return dup ? vi.exist : null;
  };
  const tagRedux = (convId, labelId) => {
    try { window.__zaloStore.dispatch({ type: TAG_CONV, payload: { data: [{ userId: String(convId), label: labelId }] } }); } catch {}
  };

  window.__zaloConversations = {
    publish: () => publish(true),

    // Official filters: type = FilterType (0 Tất cả, 1 Chưa đọc, 3 Ưu tiên, 4 Khác), labelIds = label ids as strings.
    setFilter(type, labelIds) {
      if (!resolve()) return;
      const c = S.ctrl, t = Number(type), ids = (labelIds || []).map(String);
      try {
        if (c.typeFilter !== t) c.onTypeFilterChange(t);
        const same = ids.length === c.labelFilters.length && ids.every((x, i) => x === String(c.labelFilters[i]));
        if (!same) c.onLabelFilterChange(ids);
      } catch (e) { diag('setFilter failed: ' + e); }
      publish(true);
    },

    // labelId null/'' removes the conversation from its label (official `removeConversation`).
    async setConvLabel(convId, labelId) {
      try {
        const m = mgr();
        if (!m || !labelCache()) return report(false, 'Danh sách phân loại chưa sẵn sàng');
        if (labelId === null || labelId === undefined || labelId === '') {
          await m.removeConversation(String(convId));
          tagRedux(convId, null);
        } else {
          const label = findLabel(labelId);
          if (!label) return report(false, 'Không tìm thấy phân loại');
          // force=true: add even when already present (the official menu toggles by passing null instead).
          await m.updateConversation(String(convId), label.id, true, false, true);
          tagRedux(convId, label.id);
        }
        publish(true);
      } catch (e) { report(false, errText(e)); }
    },

    async createLabel(name, color, convIds) {
      try {
        const m = mgr(), cache = labelCache();
        if (!m || !cache) return report(false, 'Danh sách phân loại chưa sẵn sàng');
        const L = limits(), text = String(name || '').trim();
        const bad = checkName(text, null);
        if (bad) return report(false, bad);
        if (cache.length >= L.maxLabels) return report(false, 'Bạn đã tạo quá số phân loại cho phép (' + L.maxLabels + ')');
        const label = { id: m.genId(), color: String(color || L.palette[0]), text, conversations: [], emoji: '', offset: cache.length, createTime: Date.now() };
        const action = S.builder ? S.builder.buildCreateActionData({ label }) : null;
        await m.update([...cache, label], true, true, action);
        for (const id of convIds || []) await m.updateConversation(String(id), label.id, true, false, true).then(() => tagRedux(id, label.id));
        report(true, 'Đã tạo phân loại');
      } catch (e) { report(false, errText(e)); }
    },

    async updateLabel(id, name, color) {
      try {
        const m = mgr(), cache = labelCache(), prev = findLabel(id);
        if (!m || !cache || !prev) return report(false, 'Không tìm thấy phân loại');
        const text = String(name || '').trim();
        const bad = checkName(text, id);
        if (bad) return report(false, bad);
        const next = Object.assign({}, prev, { text, color: String(color || prev.color) });
        const action = S.builder ? S.builder.buildEditActionData({ updatedLabelData: next, previousLabelData: prev }) : null;
        await m.update(cache.map((l) => (l && l.id === prev.id ? next : l)), true, true, action);
        report(true, 'Cập nhật phân loại thành công');
      } catch (e) { report(false, errText(e)); }
    },

    async deleteLabel(id) {
      try {
        const m = mgr(), prev = findLabel(id);
        if (!m || !prev) return report(false, 'Không tìm thấy phân loại');
        const convs = (prev.conversations || []).slice();
        await m.remove([{ id: prev.id }]);
        convs.forEach((cid) => tagRedux(cid, null));
        // Leaving a deleted label selected would show an empty list; the controller drops it as the official UI does.
        const c = S.ctrl;
        if (c && c.labelFilters.map(String).includes(String(prev.id))) c.onLabelFilterChange(c.labelFilters.filter((x) => String(x) !== String(prev.id)));
        report(true, 'Đã xóa phân loại');
      } catch (e) { report(false, errText(e)); }
    },

    // ids = label ids in the new order (official drag-to-sort → `drag`).
    async reorderLabels(ids) {
      try {
        const m = mgr(), cache = labelCache();
        if (!m || !cache) return;
        const byId = new Map(cache.map((l) => [String(l.id), l]));
        const next = (ids || []).map((x) => byId.get(String(x))).filter(Boolean);
        if (next.length !== cache.length) return;
        await m.drag(next);
        publish(true);
      } catch (e) { report(false, errText(e)); }
    },
  };
})();
