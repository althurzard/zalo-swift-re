// Olaz profile adapter (runs in the main renderer; exposes window.__olazProfile).
// Wraps official client modules verified in app.asar:
// - UiPd: getProfileMe(true), updateProfileMe({ name, gender, dob }), updateMyAvatar(160, clientId, file, metaData)
// - fBUP: updateStatus(escapedText)

(() => {
  if (typeof location !== 'undefined' && location.pathname.split('/').pop() !== 'index.html') return;

  const AVATAR_SIZE = 160;
  const DEFAULT_ERR = 'Có lỗi xảy ra, vui lòng thử lại sau.';
  const NET_ERR = 'Vui lòng kiểm tra lại kết nối mạng.';

  const safe = (fn, fallback) => { try { return fn(); } catch { return fallback; } };
  const str = (v) => (typeof v === 'string' ? v : (v == null ? '' : String(v)));
  const zlog = (msg) => { safe(() => window.webkit.messageHandlers.zlog.postMessage('[profile] ' + msg)); };

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

  const isProfileSvc = (o) => (
    typeof o.getProfileMe === 'function' &&
    typeof o.updateProfileMe === 'function' &&
    typeof o.updateMyAvatar === 'function'
  );

  const isApiSvc = (o) => (
    typeof o.updateStatus === 'function' &&
    typeof o.getSettings === 'function' &&
    typeof o.setSettings === 'function'
  );

  const profileSvc = () => findExport('UiPd', isProfileSvc);
  const apiSvc = () => findExport('fBUP', isApiSvc);

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

  const storeUser = () => safe(() => (window.__zaloStore && window.__zaloStore.getState && window.__zaloStore.getState().user) || {}, {});

  const toIntOrNull = (v) => {
    if (v === undefined || v === null || v === '') return null;
    const n = Number(v);
    return Number.isFinite(n) ? Math.trunc(n) : null;
  };

  const toEpochSecondsOrNull = (v) => {
    if (v === undefined || v === null || v === '') return null;
    const n = Number(v);
    if (!Number.isFinite(n)) return null;
    return Math.abs(n) > 1e11 ? Math.trunc(n / 1000) : Math.trunc(n);
  };

  const normalizeProfile = (raw, extra = {}) => {
    const p = raw && typeof raw === 'object' ? raw : {};
    const u = storeUser();
    const pick = (a, b, c) => (a !== undefined && a !== null && a !== '' ? a : (b !== undefined && b !== null && b !== '' ? b : c));
    const genderVal = p.gender !== undefined && p.gender !== null ? p.gender : (extra.gender !== undefined ? extra.gender : u.gender);
    const dobVal = p.dob !== undefined && p.dob !== null ? p.dob : (extra.dob !== undefined ? extra.dob : u.dob);
    const statusVal = typeof p.status === 'string'
      ? p.status
      : (typeof extra.status === 'string' ? extra.status : (typeof u.status === 'string' ? u.status : ''));
    return {
      userId: str(pick(p.userId, p.id, u.userId)),
      displayName: str(pick(p.displayName, extra.displayName, u.displayName || p.zaloName || u.zaloName)),
      zaloName: str(pick(p.zaloName, u.zaloName, '')),
      avatar: str(pick(p.avatar, extra.avatar, u.avatar)),
      phoneNumber: str(pick(p.phoneNumber, u.phoneNumber, '')),
      gender: toIntOrNull(genderVal),
      dob: toEpochSecondsOrNull(dobVal),
      sdob: str(pick(p.sdob, u.sdob, '')),
      status: statusVal,
    };
  };

  const getProfileMe = async (force = true) => {
    const svc = profileSvc();
    if (!svc) return { ok: false, errorCode: null, error: 'Chưa sẵn sàng, hãy thử lại sau giây lát.' };
    try {
      let raw = await Promise.resolve(svc.getProfileMe(force !== false));
      if (!raw && typeof svc.getProfileMeSync === 'function') {
        raw = safe(() => svc.getProfileMeSync(), null);
      }
      return { ok: true, profile: normalizeProfile(raw) };
    } catch (err) {
      const res = extractErr(err);
      zlog('getProfileMe fail code=' + String(res.errorCode));
      return res;
    }
  };

  const updateProfile = async (payload) => {
    const svc = profileSvc();
    if (!svc) return { ok: false, errorCode: null, error: 'Chưa sẵn sàng, hãy thử lại sau giây lát.' };
    const args = payload && typeof payload === 'object' ? payload : {};
    const name = str(args.name).trim();
    const gender = Number(args.gender);
    const dob = str(args.dob).trim();
    if (!name || (gender !== 0 && gender !== 1) || !/^\d{4}-\d{2}-\d{2}$/.test(dob)) {
      return { ok: false, errorCode: null, error: 'Thông tin hồ sơ chưa hợp lệ.' };
    }
    const fallbackDob = (() => {
      const parts = dob.split('-').map(Number);
      if (parts.length !== 3 || parts.some((n) => !Number.isFinite(n))) return undefined;
      const dt = new Date(parts[0], parts[1] - 1, parts[2]);
      return Number.isNaN(dt.getTime()) ? undefined : Math.trunc(dt.getTime() / 1000);
    })();
    try {
      await Promise.resolve(svc.updateProfileMe({ name, gender, dob }));
      let refreshed = null;
      try { refreshed = await Promise.resolve(svc.getProfileMe(true)); } catch {}
      zlog('updateProfile ok');
      return {
        ok: true,
        profile: normalizeProfile(refreshed, { displayName: name, gender, dob: fallbackDob }),
      };
    } catch (err) {
      const res = extractErr(err);
      zlog('updateProfile fail code=' + String(res.errorCode));
      return res;
    }
  };

  const updateStatus = async (text) => {
    const api = apiSvc();
    if (!api) return { ok: false, errorCode: null, error: 'Chưa sẵn sàng, hãy thử lại sau giây lát.' };
    const statusText = typeof text === 'string' ? text : str(text);
    // fBUP.updateStatus interpolates into `'{"status":"'+e+'"}'`; escape JSON string characters safely.
    const escaped = JSON.stringify(statusText).slice(1, -1);
    try {
      const resp = await Promise.resolve(api.updateStatus(escaped));
      if (resp && typeof resp === 'object' && typeof resp.error_code === 'number' && resp.error_code !== 0) {
        const errRes = extractErr(resp);
        zlog('updateStatus fail code=' + String(errRes.errorCode));
        return errRes;
      }
      const svc = profileSvc();
      let refreshed = null;
      if (svc) {
        try { refreshed = await Promise.resolve(svc.getProfileMe(true)); } catch {}
      }
      zlog('updateStatus ok');
      return {
        ok: true,
        status: statusText,
        profile: normalizeProfile(refreshed, { status: statusText }),
      };
    } catch (err) {
      const res = extractErr(err);
      zlog('updateStatus fail code=' + String(res.errorCode));
      return res;
    }
  };

  const decodeBase64Bytes = (base64) => {
    const bin = atob(base64);
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i += 1) bytes[i] = bin.charCodeAt(i);
    return bytes;
  };

  const makeUploadFile = (bytes) => {
    if (typeof File === 'function') {
      const file = safe(() => new File([bytes], 'avatar.jpg', { type: 'image/jpeg' }), null);
      if (file) return file;
    }
    const blob = new Blob([bytes], { type: 'image/jpeg' });
    safe(() => {
      blob.name = 'avatar.jpg';
      blob.lastModifiedDate = new Date();
    });
    return blob;
  };

  const updateAvatar = async (base64Jpeg, width, height) => {
    const svc = profileSvc();
    if (!svc) return { ok: false, errorCode: null, error: 'Chưa sẵn sàng, hãy thử lại sau giây lát.' };
    const b64 = typeof base64Jpeg === 'string' ? base64Jpeg.trim() : '';
    if (!b64) return { ok: false, errorCode: null, error: 'Dữ liệu ảnh không hợp lệ.' };
    let bytes;
    try {
      bytes = decodeBase64Bytes(b64);
    } catch {
      return { ok: false, errorCode: null, error: 'Không thể đọc dữ liệu ảnh.' };
    }
    if (!bytes.length) return { ok: false, errorCode: null, error: 'Dữ liệu ảnh trống.' };

    const file = makeUploadFile(bytes);
    const w = Number(width) > 0 ? Math.trunc(Number(width)) : 0;
    const h = Number(height) > 0 ? Math.trunc(Number(height)) : 0;
    const metaData = w > 0 && h > 0
      ? { origin: { width: w, height: h }, processed: { width: w, height: h, size: bytes.length } }
      : { processed: { size: bytes.length } };

    try {
      await Promise.resolve(svc.updateMyAvatar(AVATAR_SIZE, Date.now(), file, metaData));
      // UiPd._doUpdateMyAvatar refreshes the full profile 500ms after upload succeeds.
      await new Promise((resolve) => setTimeout(resolve, 550));
      let refreshed = null;
      try { refreshed = await Promise.resolve(svc.getProfileMe(true)); } catch {}
      const profile = normalizeProfile(refreshed);
      zlog('updateAvatar ok');
      return { ok: true, avatar: profile.avatar, profile };
    } catch (err) {
      const res = extractErr(err);
      zlog('updateAvatar fail code=' + String(res.errorCode));
      return res;
    }
  };

  window.__olazProfile = {
    getProfileMe,
    updateProfile,
    updateStatus,
    updateAvatar,
  };
})();
