# Zalo for macOS — Reverse Engineering Notes

Source: `ZaloSetup-universal-26.10.20.dmg` (337.9 MB) — analyzed 2026-10-25.

## 1. Packaging identity

| Fact | Value |
|---|---|
| Bundle ID | `com.vng.zalo` |
| Version | 26.10.20 (build 26.10.20.3253) |
| Runtime | **Electron 22.3.9** (Chromium 108), universal (arm64 + x64) |
| App size | 762 MB installed; `app.asar` 180 MB |
| Updater | electron-updater / Squirrel (`app-update.yml`) |
| URL scheme | `zalo://` |
| Entry | `bootstrap.js` → `main-dist/main.js` (single-instance lock) |
| Permissions | Camera, microphone, Bluetooth (calls); ATS allows arbitrary loads |

Other processes: `compact-app` (mini overlay chat), `znotification` (notification window),
utility processes for SQLite and media, `mainless-worker`.

## 2. Code layout (extracted ASAR → `reanalysis/app_extracted/`)

- `main-dist/` — Electron main process, **obfuscated** with `@zsecure/zpc` (`zsymb(...)` calls).
- `pc-dist/` — the renderer. **This is the Zalo Web app** (`index.html` title "Đăng nhập Zalo Web",
  `body class="web"`). React + Redux Toolkit, webpack-bundled:
  - `lazy/default-login-main-startup-…js` (17 MB) — entire UI: **0 references to `require("electron")`**.
    Desktop integration goes through a preload bridge (`preload-render.js`), not direct Electron APIs.
  - `lazy/lang-vi.js` — 6,469 Vietnamese UI strings (full feature map, parsed to `reanalysis/lang_vi.json` — VNG content, gitignored; regenerate locally).
  - `libs/libsignal-protocol.static.js` — Signal-protocol E2E encryption (pure JS).
  - Workers: `sync-v2`, `dal`, `zd`, `search`, `cpu-heavy`, `opfs`, `pdf`, `trust`.
- `native/nativelibs/` — `.node` binaries: `zcall` (VoIP/video via `vcmac`), `sqlite3`,
  `db-cross-v4`, `mp4thumb`, `os-sys-info`, `file-utils`, `v8-profiles`. These are the only
  parts that cannot run under plain JavaScriptCore.

## 3. UI structure (from lang pack + CSS class census)

- **Login** (`login.html`): QR-code login ("Quét mã QR để đăng nhập"), phone-number login,
  email login, company-account (Zalo Business) login.
- **Main window** (`index.html`): left icon **tab-bar nav rail** + conversation list + chat pane.
  - Rail tabs (strings found): **Tin nhắn** (Messages), **Danh bạ** (Contacts/You),
    **Ưu tiên** (Focus tab), phân loại **Labels/Khách hàng** (customer labels for Business mode),
    **Công việc** (Todo), ZCloud (drive), Calls, Settings, profile.
  - Conversation list: `conv-item`, pinned ("Ưu tiên ghim"), group/community badges, unread counts,
    labels ("Phân loại hội thoại"), broadcast.
  - Chat: `message-view` / `chat-message` (810 rules) with pictures, voice messages
    ("Tin nhắn thoại"), quotes/replies ("Trả lời"), reactions, comments ("Bình luận"),
    recall ("Thu hồi"), E2EE notices, date separators (`chat-date`), typing status.
  - Composer: `chat-box-input` ("Nhập tin nhắn"), attachments, stickers/emoji, AI translate
    (`ai-translation-language-model.js` — TF.js on-device model), screenshot capture.
- **Communities** (348 strings — biggest feature): groups of groups, membership approval,
  management menus.

## 4. Brand / theme tokens

- Primary blue: `#0068FF` (CTA links, buttons; pressed `#005AE0`, tonal bg `#E5F1FF`).
- Text primary (light): `#081B3A`. Dark-mode window bg: `#22262B`.
- Fonts: system + embedded fonts in `pc-dist/fonts/`.
- Tagline: "Zalo - Nhắn gửi yêu thương" ("Send love").

## 5. Network surface (from CSP + bundle strings)

- Static/resources: `res-zalo.zadn.vn`, `stc-chat.zdn.vn`, `res.zalo.zdn.vn` (avatars: `s120-ava-talk.zadn.vn`).
- Messaging API: `zimsg.chat.zalo.me`, `wss://…chat.zalo.me`, `wss://*.zavi.me` (realtime).
- Identity/auth: `zwid.api.zalo.me`. Cloud drive: `f12/f14-zpcloud.zdn.vn`. Web: `zalo.me`.
- Avatars modelled as `https://s120-ava-talk.zadn.vn/…` URLs; CDN for files `*.z-cdn.me`.

## 6. Feasibility verdict for the native rewrite

- **UI layer**: 100 % portable to SwiftUI — the renderer is plain React with no Electron coupling.
- **Engine layer**: pure-JS protocol/crypto (Signal + sync + DAL workers) is embeddable in
  **JavaScriptCore** with Swift shims (WebSocket, storage, fetch). Native `.node` modules
  (calls, sqlite) would need a Node sidecar — out of scope for v1.
- **Real login/messaging against VNG servers** requires re-implementing their proprietary
  handshake/obfuscation (`@zsecure/zpc` on the wire too) — v1 ships a demo engine behind a
  `ZaloService` protocol so a future JS engine can be dropped in.

## 7. Asset provenance

`Assets/zalo-wordmark.svg`, `zalo-logo.png`, `avatar-default.png` extracted from `pc-dist/assets/`;
`zalo.icns` from `Resources/`. Used for visual fidelity of the early recreation. These are VNG's assets: they are
gitignored and **not part of the public repo** (Olaz ships its own artwork); extract them locally if needed.

## SQLite host (DB 4.0 data access layer)

Zalo PC 26.10 keeps every database in SQLite behind its data access layer (DAL). Pieces, all in `main-dist/`:
`utility-process-sqlite.js` (the host: node-sqlite3 built with SQLCipher, one `.db` per database under
`<userData>/<…>/_production/`), `main.js` (the MsgChannel broker between scripts), `preload-sqlite.js` + `sqlite.html`
(the older in-window host and the IndexedDB → SQLite migration), `dal-worker.js` / `search-worker.js` /
`sync-v2-sub-worker.js` (renderer-side DAL clients). Olaz reproduces the host (`HostScripts/sqlite-host.js` +
`ZaloRuntime/SQLiteHost.swift`); what it speaks:

- **Mode flags**: `$zFeatures.migrateDB.isMigrateFullDone → true` makes the adapter-state service (`adp-st` in the
  `database-config` store, `0` IDB / `1` SQLite) move every database to SQLite; `$zdb.canIUseSQLite → true`;
  `$zdb.getNameOfTargetScriptForDALChannelFromHost → "utility-process-sqlite"`. `fail_sqlite3=true` /
  `checkFailedLoadSqlite → true` only steer the legacy search index to its web worker.
- **Channel broker** (`$zMsgChannel`): `requestOpenChannelTo(current, target, channelID)` → main creates a
  `MessageChannelMain` and pushes `port-transferred-v2` (SUBSCRIBE_V2 event with the port and
  `{channelID, channelSessionID, isReconnect, nameOfCurrentScript, nameOfTargetScript}`) to both scripts; each answers
  `notifyPortDelivered(current, target, channelID, sessionID)`; when both did, main pushes `channel-established`
  `[current, target, channelID]`. The DAL channel id is `"dal"`; clients are `render`, `login`, `shared-worker`,
  `search-worker`, `sync-v2-sub-workerDALWorker-1..3` (workers get their port relayed by the page). SUBSCRIBE_V2 in the
  official preload passes `(key, event, …args)` and posts the ports separately as a `window.postMessage` from origin
  `file://` with `{zChannelId: "__Z_I2M__", apiKey, key}`; the renderer's `$zsub` pairs the two by key.
- **Port protocol**: `{"zmsg-port-msg-id": id, type: "invoke-msg-request", data, meta: {createdDttm}}` answered by
  `{…, type: "invoke-msg-response", error, result, meta: {…, handledDttm}}`; a handler returning `"skip-handle-msg"`
  sends nothing. `data = {typeID, data}` with typeIDs `SQL_STATEMENT`, `DAL_UTILITY` (`DAL_UTILITY/CLOSE_DB`,
  `DELETE_DB`, `GET_PARTITION_KEYS`, `CLEAR_SESSIONAL_POOLS_UTILITY_TYPE_ID`, `CLEAR_ALL_POOLS_UTILITY_TYPE_ID`),
  `BACK_UP`, `DB_CORRUPTION`, `DB_ENCRYPTION` (`…/CHECKSTT` → `"notStarted" | "running" | "finished"`), and the
  host → client `NEED-SCHEMA-MIGRATION {fullname, currentVersion}`.
- **SQL_STATEMENT**: `{connection: {fullname, cipherKey, version | null, sessional, transactionMode, poolType},
  libMethod, statement}` with `libMethod` `run` (`statement: {query: {query, params: <count>}, params: [...], migrate}`
  → `{lastID, changes}`, a failed UNIQUE constraint still resolves), `runs` (`params: [[...], …]`, one transaction),
  `all` / `get` (rows as objects; `get` → `undefined` when none), `optimized-all` (`{queries: [{query, params}],
  params: [[[...]]]}` → concatenated rows), `serialize` (`{data: [{method: "run"|"runs", query, params}], migrate}`,
  one transaction). Results come back as `{result, connInfo?}`. Errors as node-sqlite3's `{errno, code, message}`.
- **Schema versions**: when a pool opens, the host compares `PRAGMA user_version` with the requested version
  (`null` = keep, floor 1) and, if different, invokes the requesting script with `NEED-SCHEMA-MIGRATION`; the renderer
  runs its migration statements with `migrate: true` (they bypass the paused pool) and sets `PRAGMA user_version`
  itself; everything else waits.
- **Encryption**: the host opens a database with a SQLCipher key only once the official encryption job
  (`DB_ENCRYPTION/START`) processed it. Olaz never starts that job, so its files are plain SQLite.
- **Migration from IndexedDB**: the official path relaunches with `--db-migrate` and runs the copy inside
  `sqlite.html` / `preload-sqlite.js` (Node). Not reproduced: an install moves to SQLite with empty databases and the
  phone → PC sync brings history back.
