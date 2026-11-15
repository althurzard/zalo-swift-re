// Olaz privacy & blocklist adapter (runs in the main renderer; exposes window.__olazPrivacy).
// Wraps official client modules verified in app.asar:
// - uWWm: privacy settings (getSetting, fetchSetting, updateSettings, setSetting)
// - dSSf: fetchBlockedFriendList()
// - UiPd: blockFriend(uid, SET_BLOCK | UNSET_BLOCK), isBlocked(uid)

(() => {
  if (typeof location !== 'undefined' && location.pathname.split('/').pop() !== 'index.html') return;

  const PRIVACY_KEYS = [
    'view_birthday',
    'show_online_status',
    'display_seen_status',
    'receive_message',
    'accept_stranger_call',
    'add_friend_via_phone',
    'add_friend_via_qr',
    'add_friend_via_group',
    'add_friend_via_contact',
    'display_on_recommend_friend',
  ];

  const DEFAULT_ERR = 'Có lỗi xảy ra, vui lòng thử lại sau.';
  const NET_ERR = 'Vui lòng kiểm tra lại kết nối mạng.';

  const safe = (fn, fallback) => { try { return fn(); } catch { return fallback; } };
  const str = (v) => (typeof v === 'string' ? v : (v == null ? '' : String(v)));
  const zlog = (msg) => { safe(() => window.webkit.messageHandlers.zlog.postMessage('[privacy] ' + msg)); };

  const real = (ex) => {
    if (!ex || (typeof ex !== 'object' && typeof ex !== 'function')) return false;
    return safe(() => ex.__olaz_not_a_member__ === undefined && ex.__olaz_probe__ === undefined, false);
  };

  const req = () => (typeof window !== 'undefined' ? window.__zaloRequire : null) || null;

  const mod = (id) => {
    const r = req();
    if (!r) return null;
    const hit = r.c && r.c[id] ? r.c[id].exports : null;
    if (real(hit)) return hit;
    if (r.m && r.m[id]) {
      const loaded = safe(() => r(id), null);
      if (real(loaded)) return loaded;
    }
    return null;
  };

  const eachExport = (visit) => {
    const r = req();
    if (typeof window.__zaloEachExport === 'function') {
      safe(() => window.__zaloEachExport(r, visit));
      return;
    }
    if (!r || !r.c) return;
    for (const id of Object.keys(r.c)) {
      const ex = r.c[id] && r.c[id].exports;
      if (real(ex)) safe(() => visit(ex, id));
    }
  };

  const findExport = (id, pred) => {
    const pick = (ex) => {
      if (!real(ex)) return null;
      if (real(ex.default) && pred(ex.default)) return ex.default;
      if (pred(ex)) return ex;
      return null;
    };
    const direct = mod(id);
    const hit = pick(direct);
    if (hit) return hit;
    let found = null;
    eachExport((ex) => {
      if (found) return;
      const cand = pick(ex);
      if (cand) found = cand;
    });
    return found;
  };

  const privacySvc = () => findExport(
    'uWWm',
    (o) => typeof o.getSetting === 'function' && typeof o.updateSettings === 'function' && typeof o.fetchSetting === 'function'
  );

  const friendMgrSvc = () => findExport(
    'dSSf',
    (o) => typeof o.fetchBlockedFriendList === 'function'
  );

  const profileSvc = () => findExport(
    'UiPd',
    (o) => typeof o.blockFriend === 'function' && (typeof o.isBlocked === 'function' || typeof o.getProfileMe === 'function')
  );

  const blockConsts = () => {
    const c = findExport('1pet', (o) => typeof o.SET_BLOCK === 'number' && typeof o.UNSET_BLOCK === 'number');
    return {
      SET_BLOCK: (c && c.SET_BLOCK) || 1,
      UNSET_BLOCK: (c && c.UNSET_BLOCK) || 2,
      ALREADY_BLOCKED: (c && c.ALREADY_BLOCK_ERROR_CODE) || 215,
    };
  };

  const extractErr = (err) => {
    if (err === 'ERR_NO_NETWORK' || (err && err.code === 'ERR_NO_NETWORK')) {
      return { ok: false, errorCode: -1, error: NET_ERR };
    }
    const raw = (err && err.rawError) || err;
    const code = safe(() => {
      const c = raw && (raw.error_code !== undefined ? raw.error_code : (raw.errCode !== undefined ? raw.errCode : raw.code));
      return typeof c === 'number' && Number.isFinite(c) ? c : null;
    }, null);
    if (code === -1) return { ok: false, errorCode: code, error: NET_ERR };
    return { ok: false, errorCode: code, error: DEFAULT_ERR };
  };

  const readPrivacySnapshot = (svc) => {
    const out = {};
    let presentCount = 0;
    for (const key of PRIVACY_KEYS) {
      let val = safe(() => svc.getSetting(key), undefined);
      if ((val === null || val === undefined) && svc.settings && Object.prototype.hasOwnProperty.call(svc.settings, key)) {
        val = svc.settings[key];
      }
      if (val !== null && val !== undefined) {
        presentCount += 1;
        out[key] = typeof val === 'boolean' ? (val ? 1 : 0) : Number(val);
      }
    }
    return { out, presentCount };
  };

  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

  const getSettings = async (force = false) => {
    const svc = privacySvc();
    if (!svc) return { ok: false, errorCode: null, error: 'Chưa sẵn sàng, hãy thử lại sau giây lát.' };

    let snap = readPrivacySnapshot(svc);
    if (force || snap.presentCount === 0) {
      const ret = safe(() => svc.fetchSetting(), null);
      if (ret && typeof ret.then === 'function') {
        try { await ret; } catch {}
      } else {
        const deadline = force ? 6 : 25;
        for (let i = 0; i < deadline; i += 1) {
          await sleep(100);
          snap = readPrivacySnapshot(svc);
          if (!force && snap.presentCount > 0) break;
        }
      }
      snap = readPrivacySnapshot(svc);
    }

    zlog('getSettings count=' + snap.presentCount);
    return { ok: true, settings: snap.out };
  };

  const updateSetting = async (key, value) => {
    if (!PRIVACY_KEYS.includes(key)) {
      return { ok: false, errorCode: null, error: 'Thiết lập không hợp lệ.' };
    }
    const svc = privacySvc();
    if (!svc) return { ok: false, errorCode: null, error: 'Chưa sẵn sàng, hãy thử lại sau giây lát.' };

    const wireValue = typeof value === 'boolean' ? (value ? 1 : 0) : Math.trunc(Number(value));
    if (!Number.isFinite(wireValue)) {
      return { ok: false, errorCode: null, error: 'Giá trị thiết lập không hợp lệ.' };
    }

    return new Promise((resolve) => {
      let settled = false;
      const finish = (res) => {
        if (settled) return;
        settled = true;
        resolve(res);
      };
      try {
        svc.updateSettings(
          { [key]: wireValue },
          () => {
            safe(() => {
              if (typeof svc.setSetting === 'function') svc.setSetting(key, wireValue);
              else if (svc.settings && typeof svc.settings === 'object') svc.settings[key] = wireValue;
            });
            zlog('updateSetting ok key=' + key);
            finish({ ok: true, key, value: wireValue });
          },
          (err) => {
            const res = extractErr(err);
            zlog('updateSetting fail key=' + key + ' code=' + String(res.errorCode));
            finish(res);
          }
        );
      } catch (err) {
        const res = extractErr(err);
        zlog('updateSetting fail key=' + key + ' code=' + String(res.errorCode));
        finish(res);
      }
    });
  };

  const getBlockedUsers = async () => {
    const fm = friendMgrSvc();
    if (!fm) return { ok: false, errorCode: null, error: 'Chưa sẵn sàng, hãy thử lại sau giây lát.' };
    const pSvc = profileSvc();

    try {
      const list = await Promise.resolve(fm.fetchBlockedFriendList());
      const arr = Array.isArray(list) ? list : [];
      const seen = new Set();
      const users = [];
      for (const item of arr) {
        if (!item || typeof item !== 'object') continue;
        const uid = str(item.userId || item.id).trim();
        if (!uid || seen.has(uid)) continue;
        seen.add(uid);
        const mini = pSvc && typeof pSvc.getMiniInfo === 'function' ? safe(() => pSvc.getMiniInfo(uid), null) : null;
        const cached = pSvc && typeof pSvc.getProfileByIdFromCache === 'function' ? safe(() => pSvc.getProfileByIdFromCache(uid), null) : null;
        const zaloName = str(item.zaloName || item.zName || (mini && mini.zName) || (cached && cached.zaloName) || '');
        const displayName = str(item.displayName || item.dName || (mini && (mini.dName || mini.displayName)) || (cached && cached.displayName) || zaloName);
        const avatar = str(item.avatar || (mini && mini.avatar) || (cached && cached.avatar) || '');
        users.push({ userId: uid, displayName, zaloName, avatar });
      }
      zlog('getBlockedUsers count=' + users.length);
      return { ok: true, users };
    } catch (err) {
      const res = extractErr(err);
      zlog('getBlockedUsers fail code=' + String(res.errorCode));
      return res;
    }
  };

  const setBlocked = async (uid, blocked) => {
    const target = str(uid).trim();
    if (!target) return { ok: false, errorCode: null, error: 'Không xác định được người dùng.' };
    const svc = profileSvc();
    if (!svc) return { ok: false, errorCode: null, error: 'Chưa sẵn sàng, hãy thử lại sau giây lát.' };

    const { SET_BLOCK, UNSET_BLOCK, ALREADY_BLOCKED } = blockConsts();
    const wantBlock = Boolean(blocked);
    const action = wantBlock ? SET_BLOCK : UNSET_BLOCK;

    try {
      await Promise.resolve(svc.blockFriend(target, action));
      zlog('setBlocked ok blocked=' + String(wantBlock));
      return { ok: true, userId: target, blocked: wantBlock };
    } catch (err) {
      const res = extractErr(err);
      if (wantBlock && res.errorCode === ALREADY_BLOCKED) {
        zlog('setBlocked already_blocked');
        return { ok: true, userId: target, blocked: true };
      }
      zlog('setBlocked fail code=' + String(res.errorCode));
      return res;
    }
  };

  const isBlocked = (uid) => {
    const target = str(uid).trim();
    if (!target) return false;
    const svc = profileSvc();
    if (!svc || typeof svc.isBlocked !== 'function') return false;
    return Boolean(safe(() => svc.isBlocked(target), false));
  };

  window.__olazPrivacy = {
    getSettings,
    updateSetting,
    getBlockedUsers,
    setBlocked,
    isBlocked,
  };
})();
