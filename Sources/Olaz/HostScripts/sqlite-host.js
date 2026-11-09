// Olaz host script — the official client's SQLite host, inside the page.
//
// Zalo PC 26.10 keeps its databases in SQLite behind a data access layer (DAL). Every script that owns data (the main
// page "render", the hidden "shared-worker" page, "login", and the search / sync web workers) reaches the SQLite host
// over an Electron MessagePort channel that main.js brokers (`main-dist/main.js`, MsgChannel manager) to the
// `utility-process-sqlite` utility process (`main-dist/utility-process-sqlite.js`). This script plays both:
//
//   broker    `$zMsgChannel.requestOpenChannelTo(current, target, channelID)` → a MessageChannel; port1 goes to the
//             requester as the official `port-transferred-v2` push ({channelID, channelSessionID, isReconnect,
//             nameOfCurrentScript, nameOfTargetScript} + the port), port2 stays here. `notifyPortDelivered(...)` from
//             the requester → the official `channel-established` push ([current, target, channelID]). Only the SQLite
//             host is served; the official page code relays ports to its workers itself.
//   host      the port protocol of the utility process: {"zmsg-port-msg-id": id, type: "invoke-msg-request",
//             data: {typeID, data}, meta} answered with {…, type: "invoke-msg-response", error, result, meta}.
//             typeID SQL_STATEMENT {connection: {fullname, version, sessional, …}, libMethod, statement} runs on the
//             native SQLite in Swift (`SQLiteHost.swift`, bridge `$znode.sqliteHost.*`) and answers {result}; DAL_UTILITY
//             (close / delete / partition keys / clear pools), DB_ENCRYPTION (never started here), DB_CORRUPTION and
//             BACK_UP (unsupported) are answered like the official handlers. The schema-version handshake is the
//             official one: a database at another `PRAGMA user_version` than the renderer asks for makes the host
//             invoke the renderer back with NEED-SCHEMA-MIGRATION {fullname, currentVersion}; the renderer runs its
//             migration statements (`migrate: true`) and sets the version, other statements wait.
//
// Active only when Swift chose the SQLite backend (`$znode.sqliteHostEnabled`); otherwise the page stays on IndexedDB.
(() => {
  'use strict';
  if (window.__zaloSqliteHost) return;
  const spec = window.__zaloBridgeSpec || {};
  if (!spec.values || spec.values['$znode.sqliteHostEnabled'] !== true) return;
  const diag = (s) => { try { window.webkit.messageHandlers.zlog.postMessage('[sqlite-host] ' + s); } catch {} };
  const scrub = (e) => String((e && (e.name + ': ' + e.message)) || e).replace(/\d{6,}/g, '<id>').slice(0, 200);

  const HOST = 'utility-process-sqlite';
  const MSG_ID = 'zmsg-port-msg-id';
  const REQUEST = 'invoke-msg-request';
  const RESPONSE = 'invoke-msg-response';
  const SKIP = 'skip-handle-msg';
  const MIGRATION_TIMEOUT_MS = 10 * 60 * 1000;
  const native = (method, args) => window.__zaloBridge.callAsync('$znode.sqliteHost.' + method, args);

  // ---- channel broker (main.js MsgChannel manager, SQLite host only) ----
  let sessionSeq = 0;
  const channels = new Map(); // `${requester}|${channelID}` → {requester, channelID, sessionID, port, established}
  const emitWhenListened = (channel, args, ports, tries = 50) => {
    const bridge = window.__zaloBridge;
    if (bridge.ipcHasListener(channel)) { ports ? bridge.ipcEmitPorts(channel, args, ports) : bridge.ipcEmit(channel, args); return; }
    if (tries <= 0) { diag('no listener for ' + channel); return; }
    setTimeout(() => emitWhenListened(channel, args, ports, tries - 1), 200);
  };
  const local = window.__zaloLocal = window.__zaloLocal || {};
  local['$zMsgChannel.requestOpenChannelTo'] = (current, target, channelID) => {
    if (target !== HOST) { diag('channel to ' + target + ' not supported'); return Promise.resolve(); }
    const key = current + '|' + channelID;
    if (channels.has(key)) { diag('channel ' + channelID + ' from ' + current + ' already exists'); return Promise.resolve(); }
    const pair = new MessageChannel();
    const channel = { requester: String(current), channelID: String(channelID), sessionID: ++sessionSeq, port: pair.port2, established: false };
    channels.set(key, channel);
    listen(channel);
    const data = { channelID, channelSessionID: channel.sessionID, isReconnect: false, nameOfCurrentScript: current, nameOfTargetScript: HOST };
    // The official main answers over IPC, after the request returned.
    setTimeout(() => emitWhenListened('port-transferred-v2', [data], [pair.port1]), 0);
    diag('channel ' + channelID + ' opened for ' + current);
    return Promise.resolve();
  };
  local['$zMsgChannel.notifyPortDelivered'] = (current, target, channelID, sessionID) => {
    const channel = channels.get(current + '|' + channelID);
    if (!channel || target !== HOST || channel.sessionID !== sessionID || channel.established) return Promise.resolve();
    channel.established = true;
    setTimeout(() => emitWhenListened('channel-established', [[current, HOST, channelID]], null), 0);
    return Promise.resolve();
  };

  // ---- port protocol ----
  let invokeSeq = 0;
  const invokes = new Map(); // host → renderer requests in flight: id → {resolve, reject}
  const respond = (channel, id, meta, error, result) => {
    const message = { [MSG_ID]: id, type: RESPONSE, error, result, meta: Object.assign({}, meta || {}, { handledDttm: Date.now() }) };
    try { channel.port.postMessage(message); } catch (e) { diag('respond failed: ' + scrub(e)); }
  };
  const invokeRenderer = (channel, data) => new Promise((resolve, reject) => {
    const id = 'sqlite-host-' + (++invokeSeq);
    invokes.set(id, { resolve, reject });
    channel.port.postMessage({ [MSG_ID]: id, type: REQUEST, data, meta: { createdDttm: Date.now() } });
  });
  const listen = (channel) => {
    channel.port.onmessage = (event) => {
      const message = event.data;
      if (!message || typeof message !== 'object') return;
      const id = message[MSG_ID];
      if (id === undefined || id === null) return;
      if (message.type === RESPONSE) {
        const pending = invokes.get(id);
        if (!pending) return;
        invokes.delete(id);
        if (message.error) pending.reject(message.error); else pending.resolve(message.result);
        return;
      }
      if (message.type !== REQUEST) return;
      Promise.resolve().then(() => dispatch(channel, message.data)).then(
        (result) => { if (result !== SKIP) respond(channel, id, message.meta, null, result === undefined ? null : result); },
        (e) => respond(channel, id, message.meta, serializeError(e), null));
    };
  };
  // Swift reports SQLite failures as "SQLITE_<CODE>:<errno>:<detail>"; the renderer expects node-sqlite3's {errno, code, message}.
  const serializeError = (e) => {
    const text = String((e && e.message) || e || '');
    // (WebKit may wrap the bridge's rejection text in an Error: "Error: SQLITE_…".)
    const m = /^(?:Error:\s*)?(SQLITE_[A-Z_]+):(\d+):([\s\S]*)$/.exec(text);
    if (m) return { errno: Number(m[2]), code: m[1], message: m[1] + ': ' + m[3] };
    return { name: (e && e.name) || 'Error', message: text };
  };

  // ---- request handlers (utility-process-sqlite) ----
  const dispatch = (channel, request) => {
    const { typeID, data } = request || {};
    switch (typeID) {
      case 'SQL_STATEMENT': return statement(channel, data || {});
      case 'DAL_UTILITY': return utility(data || {});
      case 'DB_ENCRYPTION': return encryption(data || {});
      case 'DB_CORRUPTION': return undefined;
      case 'BACK_UP': throw new Error('Backup is not supported');
      default: throw new Error(`No request handler found for '${typeID}'`);
    }
  };

  // Databases this page opened: fullname → {opened: Promise<open result>, ready: Promise<void>, sessional}.
  const dbs = new Map();
  const withTimeout = (promise, ms, what) => Promise.race([promise, new Promise((_, reject) => setTimeout(() => reject(new Error(what + ' timed out')), ms))]);
  const ensure = (channel, fullname, version, sessional) => {
    let db = dbs.get(fullname);
    if (db) return db;
    db = { sessional: !!sessional };
    db.opened = native('open', [fullname, version === undefined ? null : version, !!sessional]);
    db.ready = db.opened.then(async (info) => {
      if (!info || !info.migrate) return;
      // The official host asks the requesting script to upgrade the schema and waits for it.
      try {
        await withTimeout(invokeRenderer(channel, { typeID: 'NEED-SCHEMA-MIGRATION', data: { fullname, currentVersion: Number(info.userVersion) || 0 } }), MIGRATION_TIMEOUT_MS, 'schema migration of ' + fullname);
      } finally {
        await native('migrated', [fullname]).catch(() => {});
      }
    });
    db.ready.catch((e) => { diag('open ' + fullname + ' failed: ' + scrub(e)); if (dbs.get(fullname) === db) dbs.delete(fullname); });
    dbs.set(fullname, db);
    return db;
  };
  const statement = async (channel, data) => {
    const { connection, libMethod, statement: stmt } = data;
    const { fullname, version, sessional } = connection || {};
    if (!fullname || typeof fullname !== 'string') throw new Error('SQL_STATEMENT without a database');
    const db = ensure(channel, fullname, version, sessional);
    // Migration statements run while the handshake is open; everything else waits for it.
    await (stmt && stmt.migrate ? db.opened : db.ready);
    const result = await native('exec', [fullname, libMethod, stmt || {}]);
    return { result: libMethod === 'get' && (result === null || result === undefined) ? undefined : result };
  };
  const utility = async (data) => {
    const { type, data: payload } = data;
    const fullname = payload && payload.fullname;
    switch (type) {
      case 'DAL_UTILITY/CLOSE_DB': dbs.delete(fullname); return native('close', [fullname]);
      case 'DAL_UTILITY/DELETE_DB': dbs.delete(fullname); return native('delete', [fullname]);
      case 'DAL_UTILITY/GET_PARTITION_KEYS': return native('partitionKeys', [fullname]);
      case 'DAL_UTILITY/CLEAR_SESSIONAL_POOLS_UTILITY_TYPE_ID':
        for (const [name, db] of dbs) if (db.sessional) dbs.delete(name);
        return native('closeSessional', []);
      case 'DAL_UTILITY/CLEAR_ALL_POOLS_UTILITY_TYPE_ID': dbs.clear(); return native('closeAll', []);
      default: return undefined;
    }
  };
  // The official encryption job (SQLCipher) never runs here: every database reads as not started.
  const encryption = (data) => (data.type === 'DB_ENCRYPTION/CHECKSTT' ? 'notStarted' : undefined);

  window.__zaloSqliteHost = { channels, dbs };
  diag('installed');
})();
