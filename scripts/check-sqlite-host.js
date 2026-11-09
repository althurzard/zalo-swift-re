#!/usr/bin/env node
// Protocol check of HostScripts/sqlite-host.js: runs bridge.js + sqlite-host.js in node (MessageChannel, no WebKit) with
// `node:sqlite` standing in for SQLiteHost.swift, and a client that speaks the official channel / port protocol the way the
// renderer's channel manager and DAL connection do. Prints every exchange; exits non-zero on a protocol failure.
//
//   node --no-warnings scripts/check-sqlite-host.js            (Node 22.5+ for node:sqlite)
const fs = require('fs'), vm = require('vm'), path = require('path'), os = require('os');
const { DatabaseSync } = require('node:sqlite');
const dir = process.argv[2] || path.join(__dirname, '..', 'Sources', 'Olaz', 'HostScripts');
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'olaz-sqlite-'));
const logs = [];
// ---- fake Swift: $znode.sqliteHost.* over the bridge (same semantics as SQLiteHost.swift) ----
const dbs = new Map(); const migrating = new Set();
const fileOf = (name) => path.join(root, name + '.db');
const codeName = { 1: 'SQLITE_ERROR', 19: 'SQLITE_CONSTRAINT' };
const wrap = (fn) => { try { return fn(); } catch (e) { const errno = e.errcode || 1; throw new Error(`${codeName[errno] || 'SQLITE_ERROR'}:${errno}:${e.message}`); } };
const conn = (name) => { let d = dbs.get(name); if (!d) { fs.mkdirSync(path.dirname(fileOf(name)), { recursive: true }); d = new DatabaseSync(fileOf(name)); dbs.set(name, d); } return d; };
const swift = {
  open: async (name, version, sessional) => { const d = conn(name); const cur = d.prepare('PRAGMA user_version').get().user_version; let req = version === null || version === undefined ? cur : version; req = Math.max(req, 1); if (cur === req || migrating.has(name)) return { userVersion: cur, migrate: false }; migrating.add(name); return { userVersion: cur, migrate: true }; },
  migrated: async (name) => { migrating.delete(name); },
  exec: async (name, method, st) => {
    const d = conn(name); const q = (v) => (typeof v === 'string' ? v : (v && v.query) || '');
    switch (method) {
      case 'run': return wrap(() => { try { const r = (st.params && st.params.length) ? d.prepare(q(st.query)).run(...st.params) : (d.exec(q(st.query)), { lastInsertRowid: 0, changes: 0 }); return { lastID: Number(r.lastInsertRowid), changes: Number(r.changes) }; } catch (e) { if (/UNIQUE constraint failed/.test(e.message)) return { lastID: 0, changes: 0 }; throw e; } });
      case 'runs': return wrap(() => { d.exec('BEGIN'); try { const p = d.prepare(q(st.query)); for (const row of st.params) p.run(...row); d.exec('COMMIT'); } catch (e) { d.exec('ROLLBACK'); throw e; } return null; });
      case 'all': return wrap(() => d.prepare(q(st.query)).all(...(st.params || [])));
      case 'get': return wrap(() => d.prepare(q(st.query)).get(...(st.params || [])) ?? null);
      case 'optimized-all': return wrap(() => { const out = []; st.queries.forEach((qq, i) => { const p = d.prepare(q(qq)); for (const row of st.params[i] || []) out.push(...p.all(...row)); }); return out; });
      case 'serialize': return wrap(() => { d.exec('BEGIN'); try { for (const it of st.data) { const p = d.prepare(q(it.query)); if (it.method === 'runs') for (const row of it.params) p.run(...row); else p.run(...(it.params || [])); } d.exec('COMMIT'); } catch (e) { d.exec('ROLLBACK'); throw e; } return null; });
      default: throw new Error('unknown ' + method);
    }
  },
  close: async (name) => { const d = dbs.get(name); if (d) { d.close(); dbs.delete(name); } return null; },
  delete: async (name) => { await swift.close(name); for (const s of ['', '-shm', '-wal']) { try { fs.unlinkSync(fileOf(name) + s); } catch {} } return null; },
  partitionKeys: async (name) => fs.existsSync(fileOf(name)) ? [''] : [],
  closeSessional: async () => null, closeAll: async () => null,
};
const calls = [];
const ctx = {
  console, logs, setTimeout, clearTimeout, setInterval, clearInterval, Promise, JSON, Object, Array, Number, String, Map, Set, WeakMap, Math, RegExp, Error, Date, MessageChannel, MessagePort, MessageEvent, btoa, atob, Uint8Array, ArrayBuffer,
  webkit: { messageHandlers: {
    zbridge: { postMessage: async (msg) => { if (msg.kind === 'call' && msg.path.startsWith('$znode.sqliteHost.')) { const m = msg.path.slice('$znode.sqliteHost.'.length); calls.push(m); return swift[m](...msg.args); } if (msg.kind === 'subscribe') return null; throw new Error('unexpected ' + JSON.stringify(msg).slice(0, 80)); } },
    zlog: { postMessage: (s) => logs.push(s) } } },
  __zaloBridgeSpec: { globals: ['$zMsgChannel', '$znode'], members: { '$znode.sqliteHostEnabled': 'value' }, values: { '$znode.sqliteHostEnabled': true },
    ipc: { '$zMsgChannel.onReceiveTransferredPortV2': { channel: 'port-transferred-v2', type: 'SUBSCRIBE_V2' }, '$zMsgChannel.onChannelEstablished': { channel: 'channel-established', type: 'SUBSCRIBE' },
           '$zMsgChannel.requestOpenChannelTo': { channel: 'open-channel-to', type: 'NOTIFY' }, '$zMsgChannel.notifyPortDelivered': { channel: 'port-delivered', type: 'NOTIFY' } } },
};
ctx.window = ctx; vm.createContext(ctx);
for (const f of ['bridge.js', 'sqlite-host.js']) vm.runInContext(fs.readFileSync(path.join(dir, f), 'utf8'), ctx);
const MSG_ID = 'zmsg-port-msg-id';
(async () => {
  // ---- the renderer side ----
  let port = null, established = null, seq = 0; const pending = new Map(); const hostRequests = [];
  ctx.$zMsgChannel.onReceiveTransferredPortV2((key, event, data) => { port = event.ports[0]; port.onmessage = (ev) => {
    const m = ev.data; if (m.type === 'invoke-msg-response') { const p = pending.get(m[MSG_ID]); pending.delete(m[MSG_ID]); m.error ? p.reject(m.error) : p.resolve(m.result); }
    else if (m.type === 'invoke-msg-request') { hostRequests.push(m.data); setTimeout(() => port.postMessage({ [MSG_ID]: m[MSG_ID], type: 'invoke-msg-response', error: null, result: 'migrated-by-renderer', meta: m.meta }), 10); }
  }; console.log('port received: key', key, 'data', JSON.stringify(data)); ctx.$zMsgChannel.notifyPortDelivered(data.nameOfCurrentScript, data.nameOfTargetScript, data.channelID, data.channelSessionID); });
  ctx.$zMsgChannel.onChannelEstablished((event, args) => { established = args; });
  const invoke = (data) => new Promise((resolve, reject) => { const id = ++seq; pending.set(id, { resolve, reject }); port.postMessage({ [MSG_ID]: id, type: 'invoke-msg-request', data, meta: { createdDttm: Date.now() } }); });
  const sql = (fullname, libMethod, statement, version = 3) => invoke({ typeID: 'SQL_STATEMENT', data: { connection: { fullname, cipherKey: null, version, sessional: false, transactionMode: 2 }, libMethod, statement } });
  ctx.$zMsgChannel.requestOpenChannelTo('render', 'utility-process-sqlite', 'dal');
  await new Promise((r) => setTimeout(r, 50));
  console.log('established:', JSON.stringify(established));
  // Migration handshake: the file is at user_version 0, the renderer asks for 3 → NEED-SCHEMA-MIGRATION, migrate statements pass, others wait.
  const waiting = sql('user/db1', 'all', { query: { query: 'SELECT * FROM t', params: 0 }, params: [] });
  await new Promise((r) => setTimeout(r, 5));
  console.log('host asked:', JSON.stringify(hostRequests));
  const mig = await sql('user/db1', 'run', { query: { query: 'CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT UNIQUE, blob BLOB)', params: 0 }, params: [], migrate: true });
  console.log('migrate run:', JSON.stringify(mig));
  await sql('user/db1', 'run', { query: { query: 'PRAGMA user_version = 3;', params: 0 }, params: [], migrate: true });
  console.log('select after migration:', JSON.stringify(await waiting));
  console.log('run insert:', JSON.stringify(await sql('user/db1', 'run', { query: { query: 'INSERT INTO t (name) VALUES (?)', params: 1 }, params: ['a'] })));
  console.log('run duplicate (UNIQUE) resolves:', JSON.stringify(await sql('user/db1', 'run', { query: { query: 'INSERT INTO t (name) VALUES (?)', params: 1 }, params: ['a'] })));
  console.log('runs:', JSON.stringify(await sql('user/db1', 'runs', { query: { query: 'INSERT INTO t (name) VALUES (?)', params: 1 }, params: [['b'], ['c']] })));
  console.log('all:', JSON.stringify(await sql('user/db1', 'all', { query: { query: 'SELECT id, name FROM t ORDER BY id', params: 0 }, params: [] })));
  console.log('get missing:', JSON.stringify(await sql('user/db1', 'get', { query: { query: 'SELECT * FROM t WHERE id = ?', params: 1 }, params: [99] })));
  console.log('optimized-all:', JSON.stringify(await sql('user/db1', 'optimized-all', { queries: [{ query: 'SELECT name FROM t WHERE id = ?', params: 1 }], params: [[[1], [2]]] })));
  console.log('serialize:', JSON.stringify(await sql('user/db1', 'serialize', { data: [{ method: 'run', query: { query: 'INSERT INTO t (name) VALUES (?)', params: 1 }, params: ['d'] }, { method: 'runs', query: { query: 'INSERT INTO t (name) VALUES (?)', params: 1 }, params: [['e']] }] })));
  try { await sql('user/db1', 'all', { query: { query: 'SELECT * FROM nope', params: 0 }, params: [] }); } catch (e) { console.log('error shape:', JSON.stringify(e)); }
  console.log('partition keys:', JSON.stringify(await invoke({ typeID: 'DAL_UTILITY', data: { type: 'DAL_UTILITY/GET_PARTITION_KEYS', data: { fullname: 'user/db1' } } })));
  console.log('encryption:', JSON.stringify(await invoke({ typeID: 'DB_ENCRYPTION', data: { type: 'DB_ENCRYPTION/CHECKSTT' } })));
  try { await invoke({ typeID: 'BACK_UP', data: {} }); } catch (e) { console.log('backup:', JSON.stringify(e)); }
  console.log('close:', JSON.stringify(await invoke({ typeID: 'DAL_UTILITY', data: { type: 'DAL_UTILITY/CLOSE_DB', data: { fullname: 'user/db1' } } })), 'reopen same version → no handshake:', JSON.stringify(await sql('user/db1', 'get', { query: { query: 'SELECT count(*) AS n FROM t', params: 0 }, params: [] })), 'host requests', hostRequests.length);
  console.log('swift calls:', calls.join(','));
  console.log('logs:', logs);
  fs.rmSync(root, { recursive: true, force: true });
  process.exit(0);
})().catch((e) => { console.error('FAILED', e); process.exit(1); });
