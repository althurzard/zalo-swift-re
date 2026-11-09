# Zalo PC 26.10.20 (client 694) — preload bridge spec for a Swift/WKWebView host

Sources: `main-dist/preload-render.js` (module `T5SJ` = entry that assigns `window.$z*` and calls `contextBridge.exposeInMainWorld`), `main-dist/main.js` (handlers in module `FEqq`, bootstrap in `j6F3`, entry `tGN0`), renderer `pc-dist/**`. Module ids below are webpack ids inside those files. **[R]** = read directly in code, **[I]** = inferred.

Machine-readable companion: `reanalysis/bridge-table.json` (`table`: every table-driven member → `{channel,type}`; `local`: members implemented in the preload itself; `notes`: dispatch rules).

---

## 0. How the bridge works (read first)

### 0.1 Table-driven members (module `DmP7` `f(table)`, type enum `i6mH`) [R]

```js
// DmP7
case NOTIFY: case REQUEST: t[n]=(...a)=>ipcRenderer.invoke(apiKey,...a)
case REQUEST_SYNC: t[n]=(...a)=>ipcRenderer.sendSync(apiKey,...a)
case SUBSCRIBE:   t[n]=cb=>ipcRenderer.on(apiKey,cb)            // cb(event,...args)
case UNSUBSCRIBE: t[n]=cb=>ipcRenderer.removeAllListeners(apiKey) // ignores cb!
case PROVIDE:     t[n]=fn=>ipcRenderer.handle(apiKey,fn)          // polyfill, see 0.2
case STOP_PROVIDE:t[n]=()=>ipcRenderer.removeHandler(apiKey)
case RAW_SEND:    t[n]=(...a)=>ipcRenderer.send(apiKey,...a)
case ONCE ("SUBSCRIBE_ONCE"): t[n]=cb=>CNL1.once(apiKey,cb)       // sets event.sender
case SUBSCRIBE_V2: on(apiKey,(ev,...r)=>{k=++u; afterWindowLoad(()=>window.postMessage({zChannelId:"__Z_I2M__",apiKey,key:k},"file://",ev.ports)); cb(k,ev,...r)})
```

Consequences for Swift:

| type | JS shape you must expose | Swift side |
|---|---|---|
| REQUEST / NOTIFY | `(...args) => Promise` | **Always settle the promise.** NOTIFY is also `invoke` (resolves `undefined`). A never-settling stub hangs whatever `await`s it. |
| REQUEST_SYNC | `(...args) => value`, synchronous | Needs a sync channel (see 0.4). |
| RAW_SEND | `(...args) => undefined` | fire-and-forget message |
| SUBSCRIBE | `cb => …`; later call `cb(event, ...args)` | Push from Swift: `dispatch(channel, ...args)` → call every cb with a fake `event` object (`{sender:{}, ports:[]}`) **as the first argument**. |
| UNSUBSCRIBE | `cb => …` | removes **all** listeners of that channel (Electron semantics). |
| PROVIDE | `fn => …` registers a renderer-side handler | Swift "invokes the renderer": call fn(event,...args), await, return value to Swift. |
| ONCE | `cb => …` one-shot | |
| SUBSCRIBE_V2 | like SUBSCRIBE but `cb(key, event, ...args)` and MessagePorts posted via `window.postMessage` | only `$zMsgChannel.onReceiveTransferredPortV2`; renderer checks `e.origin === "file://"` and `e.source === window` [R] |

Renderer side always goes through `globalThis.$zsub` (lazy chunk `default-login-startup-main-startup-shared-worker-znotification`) [R]: it keeps its own listener list per channel and calls the preload's `onX(dispatcher)` **once**, and `removeListenX()` only when the last listener goes. So each channel gets at most one preload-level listener.

### 0.2 PROVIDE polyfill (module `IzvT`) [R]

`ipcRenderer.handle` does not exist in Electron renderers; preload adds it: main sends `"__Z_IPC_INVOKE__"(reqId, channel, ...args)` (main side `/oPU` `webContents.invoke`), the renderer runs the handler and replies `ipcRenderer.send("__Z_IPC_INVOKED__", reqId, errOrNull, result)`. Swift equivalent: `evaluateJavaScript("__bridge.invokeRenderer(channel,args)")` returning a promise.

### 0.3 Globals exposed (`exposeInMainWorld`, 41) [R]

`MetriczGlobal $zenv $zcommon $znode $zwindow $zresource $zlogger $zupdater $zapp $zdownload $zdb $zsessionManager $zmulti $zcall $zsharedWorker $zelectron $zelectronNative $zuri $zscreencap $zlogin $zperf $zconfig $zMetric $zFileManager $zpc $zFeatures $zcloud $zMsgChannel $zscript $zInAppPayment $capp $zbackup $zpreload $zsqlitebw $zsafeStorage $zMigrateDrive $zTFModels $znetwork $zprotocol $znoti`

- `$zenv = {isPreloaded:true, isRenderer:true}` — the renderer checks `window.$zenv?.isPreloaded` before several bridge paths (e.g. `signalCloseDBs`) [R].
- `$zFileManager` is exposed with `trustPathFromBlob: undefined` (deliberately removed) [R].
- `$zelectron` = table `GfBU` **merged with** local `{getElectronStore}` (`4Hrq.a`).
- `$zFileManager` = local `U3kX.mn()` **merged with** table `k4W9`.
- `$zFeatures` = object of tables + locals (fileRes, libvips, libjxl).
- `$zsub` is NOT a preload global (renderer-made).

### 0.4 Synchronous members — you need a sync path [R]

`$zelectron.getPathSync/getAppPathSync/getInfoScreenOfMouseSync` (sendSync), the whole electron-store API (`get/set/has/delete/...` are sync; ctor does `ipcRenderer.sendSync("electron-store-get-data")` → `{defaultCwd:userData, appVersion}`), `$zFileManager.getSentryConfig` (sendSync + `fs-extra.readJsonSync`), `$znode.fs.*Sync`, `$znode.fsExtra.*Sync`, all of `$znode.path`, `$znode.os`, `$znode.crypto` (sync Node crypto), `$zelectronNative.*` clipboard reads.
Recommended Swift design [I]: (a) implement `path`, `os`, `crypto` (hash/HMAC/AES/random), electron-store **purely in JS** inside the injected user-script, with store contents snapshotted into the script at document-start (inject the JSON of every `<userData>/*.json` store) and writes mirrored async to Swift; (b) for genuinely sync file-system calls use the `prompt()` trick (`WKUIDelegate runJavaScriptTextInputPanelWithPrompt` returns synchronously) or a pre-computed cache.

### 0.5 Node callback-style APIs — likely cause of the first stall [R]

The renderer calls Node's **callback** forms, not promises:

```js
$znode.fs.access(e, $znode.fs.constants.R_OK|W_OK|F_OK, (e=>{t(!e)}))      // d9141… chunk
$znode.fs.access(e, s.constants.F_OK, (a=>{ if(a) return …n(a); …t(!0) }))
$znode.fsExtra.ensureDir(dir, null, (e=>{ e ? log(e) : … }))             // (path, opts, cb)
```

So `fs.*` (non-Sync, non-promises) must invoke the **last-argument callback** with `(err)`/`(err,result)`; `fsExtra.*` (universalify) must support **both** promise (no callback) and callback (last arg is a function). `fs.constants` must be `{F_OK:0,R_OK:4,W_OK:2,X_OK:1,...}`. `fs.exists` is `util.promisify(fs.exists)` (resolves boolean). `fsPromise.*` = `fs.promises.*`.

---
## 1. Preload-local members (no IPC) — exact Node API

### 1.1 `$znode` (module `15f/` `de()`) [R]

| member | implementation |
|---|---|
| `fs.{statSync,existsSync,accessSync,mkdirSync,unlinkSync,readdirSync}` | `require("fs").X` — **sync** |
| `fs.{stat,lstat,mkdir,readdir,unlink,access,rmdir,link}` | `fs.X` — **callback style** (last arg cb) |
| `fs.constants`, `fs.constanst` (typo) | `fs.constants` |
| `fs.exists` | `util.promisify(fs.exists)` → Promise<boolean> |
| `fsPromise.{stat,lstat,mkdir,readdir,unlink,link,access,rmdir,rm}` | `fs.promises.X` |
| `fsExtra.{copy,move,ensureDir,rename,remove}` | fs-extra (Promise **or** callback) |
| `fsExtra.{copySync,ensureDirSync,renameSync,existsSync,statSync,removeSync}` | fs-extra sync |
| `path.{basename,delimiter,dirname,extname,format,isAbsolute,join,normalize,parse,posix,relative,resolve,sep,toNamespacedPath}` | `require("path")` (darwin → posix; `sep="/"`) |
| `os.{hostname,networkInterfaces,platform,release,cpus,uptime,homedir,type,arch,totalmem,freemem}`, `os.EOL` | `require("os")` |
| `crypto.createHash(alg)` | `{update(data)→self, digest(enc?)}`; digest without enc returns **ArrayBuffer** |
| `crypto.randomBytes(n)` | ArrayBuffer |
| `crypto.createCipheriv/createDecipheriv(alg="aes-256-gcm", key=rand32, iv=rand16, opts)` | `{update(buf)→ArrayBuffer, final()→ArrayBuffer, setAutoPadding, getAuthTag()→ArrayBuffer, setAuthTag}`; non-string args converted with `Buffer.from` |
| `crypto.encrypt/decrypt(input, alg, key, iv=Buffer.alloc(16), opts{key,iv,input,output}, authTagOpts)` | one-shot `createCipheriv`+`update`+`final`; returns string if `opts.output` else ArrayBuffer |
| `crypto.hash(data, alg, inputEnc, outEnc, opts)` | `createHash(alg).update(data,inputEnc).digest(outEnc)` (ArrayBuffer if no outEnc) |
| `crypto.publicEncrypt(key, data, inEnc="base64", outEnc="base64")`, `privateDecrypt(key,padding,data,{input,output})`, `generateKeyPairSync`, `constants` | Node crypto |
| `shell.openPath(p)`, `shell.showItemInFolder(p)` | **IPC** `invoke("__shell__", "openPath"|"showItemInFolder", p)` → main `Mz8P.openPath(p[, reveal])` → bool |
| `child_process.{spawn,exec,execSync}(cmd,opts)` | **IPC** `invoke("__child_process__", method, cmd, {timeout})`; main allows only a whitelist of commands. No-op/reject in Swift. |
| `zlib.gzip` | callback |
| `nativelibs` | `{asyncSqlite, ...require("../native/nativelibs")}` — **native .node** (sqlite3, zimage, zjxl, zlang, ocr…) → expose `{}`; callers are behind feature flags |
| `admzip, progressStream, util.promisify, rimraf, unusedFilename{sync,async}, url{format,pathToFileURL→string}, diskSpace, fastGlob` | npm libs; only used by backup/export/resource-mgmt features → stub |

### 1.2 `$zelectron.getElectronStore(opts)` (module `4Hrq.a` → `rO0L` → `Y6nd` electron-store → `woLD` conf) [R]

- Cached per `opts.name` (default `"default"` cache key; conf default file name `"config"`).
- Instance API (bound functions): `get(key, default?)`, `set(key, value)` / `set(object)`, `has`, `reset(...keys)`, `delete`, `clear`, `onDidChange(key, cb)→unsubscribe`, `onDidAnyChange(cb)→unsubscribe`. Keys use **dot-notation paths** (`"zsskd.<k>"`, `"force_quit.launched"`).
- File: `<userData>/<name>.json` (userData = `~/Library/Application Support/Zalo` [I: package name "Zalo"]), JSON pretty-printed, no encryption in the renderer calls seen.
- Names used by renderer: `"database-config"` (DB adapter state, key `adp-st`), `"migrate-config"` (watch:true), `"compact-app-config"`, unnamed default, plus dynamic names [R].

### 1.3 `$zFileManager` local part (module `U3kX`) [R]

All Node `fs`/`path` based; most check `await $zFileManager.isTrustPath(p)` (IPC `is_trust_path`) first.

| member | what it does |
|---|---|
| getSentryConfig() | **sync**: `sendSync("_electron_get-path-sync","userData")` + `readJsonSync(<userData>/sentry-config.json)` → object or null. Return `null`. |
| saveSentryConfig(obj, dir) | `writeFileSync(<dir>/sentry-config.json)` |
| getViewerkey(userDataPath) | reads `<userData>/z_u.txt`; **rejects** `Error("z_u.txt not found")` if missing — must reject, not hang |
| writeRecentId(uid) | writes `<appData>/z_u.txt` |
| writeActionLog/getActionLog/removeActionLog, getQosLog/removeQosLog, writeUptimeLog/readUptimeLog | `action_log.txt`, `qos_log.txt`, `timeonapp.txt` in given dir (getActionLog zips with adm-zip) |
| readZLog, truncateFileUpto, writeZLog, writeZLogBetween, scandirLog, getExtraLogFiles, readLogRange, writeLogRange, cleanupLogFileDescriptors, initBinaryLogFile, sealCalfLog, readCalfActiveCompressed, mergeCalfLogGroup | zlog files under `<userData>/<logdir>`; safe to resolve empty/[] |
| getPhotoWithPaths(title, defaultPath, opts) | `$zwindow.showOpenDialog` + `fs.stat/readFile` → `{photoPaths, photoResults:[{isSuccess,data:{name,path,size,content?:Uint8Array,needReadBlob}}]}` |
| getDefaultExportFolder, pickExportFolder, initTempDBFolderPath, createTempDBFolder, setupWriteStreamBackup, achiveBackupFile, removeOutputZipTemp, renameExportZipFile, pickBackupFile, extractBackupFile, readBackUpData, removeDBBackupFile, copyBUResourceToApp, removeTempBUFolder, removeTempDBFolder | backup export/import (aes-256-cbc zip) → stub |
| getInstallSource(x) | reads `<exe>/../../pc_<x>` → reject |
| cleanConvResourcePhoto | rename+rimraf picture dir |
| getFileArrayBuffer(p) / getFileBlob(p) / getFileBlobURL(p, URL) / readFileAsync(p, enc) | read trusted file → ArrayBuffer / Blob(ReadableStream) / objectURL / Buffer |
| writeBufferToPath(p, ab) / writeBlobToPath(p, blob) / appendBufferToPath(p, buf) | write trusted file |
| getFileInZip({localPath,url,entry:{offset,size,zipKey,name}}, cfg) | read range from local zip or HTTP `Range` fetch, write to `<ZaloTemp>/<zipKey>/<name>`, return path |
| svcReadPath(p,{start,end,type}), svcStatAsync(p) | ranged read / `{size}` |
| testChecksum(p, md5), getMd5LargeFileObject(p), getPartialFingerprint(p) | md5 / sha1 of first+last 64 KiB |
| readChunksArrayObject(key, fileInfo, part, secure, …) | chunked upload reader → `{chunks:DataView[], noChunk, tag?, checksumEncr?}` (needed for **file/photo upload**) |
| trustBlob(blob) | calls `trustPathFromBlob` (removed in main world → effectively no-op) |
| createSync2BackupDir, cleanupBackupDir, createSync2BackupFilePath, getSync2BackupFilePath, getSync2BackupRootDir, writeSync2BackupData | `<ZaloAppDir>/sync2/...` |

### 1.4 Other locals [R]

| global.member | implementation |
|---|---|
| `$zcommon.send(ch,...a)` | `ipcRenderer.send` **only** for `"show-photo-viewer"`; `receive/remove` whitelist `[""]` → no-ops (module `S4OH`) |
| `$zelectronNative.*` (`4Hrq.b`) | Electron `clipboard` (readImage→{isEmpty,toJPEG,toPNG}, readText, write/writeText, writeImage, availableFormats, read, readBuffer), `webFrame` (setVisualZoomLevelLimits(1,1), setZoomFactor, getResourceUsage, clearCache), `nativeImage.createFromDataURL(u).toPNG().buffer`, `process.getHeapStatistics().totalAvailableSize`. Map to NSPasteboard; zoom no-op. |
| `$zpc.zfile.{getChecksum,compareChecksum,readFileByChunksForUpload}`, `$zpc.zprocess.getActiveResourcesInfo` | module `YQF/`; md5 with XOR de-noise (key 147, sig `077a416c4f07`) for `ZaloDownloads/fileNoise`; chunk reader for upload |
| `$zFeatures.fileRes.{createDetachCleaner,createKeepDelDb}` | `Hz92`: detached `rm -rf`; small JSON db at `getZaloDirSync()/<db_name>` with AES-256-CBC(userId) rows |
| `$zFeatures.libvips.resizeImage`, `$zFeatures.libjxl.*` | native `nativelibs.zimage()/zjxl()` → reject (renderer has fallbacks [I]) |
| `MetriczGlobal.{getProcessStats,getProcessMemory,startCPUMonitor,stopCPUMonitor,getCPUUsage,onCPUChange,removeCPUChangeListener,getArch}` | `process.*`; `getArch` returns `"arm64"` when `os.cpus()[0].model` matches `^Apple M\d+$` |
| `$zpreload.triggerWindowLoadedEvent()` | resolves the internal "window loaded" container (also auto on `load`) that gates SUBSCRIBE_V2 port posting; return `undefined` synchronously |

---

## 2. Main-process handler semantics for the channels that matter

(Full per-member list with handler code is in the Appendix.) All `invoke` handlers are registered by `2K8J` → `K/Cq.a` = `ipcMain.handle(apiKey, checkTrustSender(fn))`; `send`/`sendSync` ones by `K/Cq.b` = `ipcMain.on` or by chained `ipcMain.on` in `j6F3` [R].

### 2.1 Login / session / cookies

| channel (member) | main does [R] | Swift |
|---|---|---|
| `_electron_set-app-cookie` (`$zelectron.setAppCookie(zpw_sek)`) | `cookies.set({name:"zpw_sek",value,httpOnly,secure,sameSite:"no_restriction",expirationDate:now+7d})` for `https://zaloapp.com`/`zaloapp.com`, `https://zalo.me`/`zalo.me`, `https://chat.zalo.me`/`chat.zalo.me`; `flushStore()`; resolves undefined | put the cookie in your URLSession/WK cookie store for those 3 domains; persist |
| `_electron_set-cookie` (`setCookie(name,value,url,domain)`) | same, exp now+365d | same |
| `_electron_clear-cookie` | `clearStorageData({storages:["cookies"]})` | clear jar |
| `login-success` (`$zlogin.notifyLoginSuccess()`) | `j6F3.onLoginSuccess()`: `Ue=null`; `Zt(win,{already_login:"y",new_install_success,install_source})` → **`loadURL(index.html + qt(params))`**; `once("did-finish-load")` → `send("login-success")` (and reload once if `Je`); after 2 s maybe `send("binary-updated")` | navigate to index.html with query (see 2.4) then push `login-success` |
| `login` RAW_SEND (`$zlogin.login(code)`) | logout path: logQos 91062, close child windows, `sn()` = **load login.html**, then on did-finish-load `send("signal_USER_NOT_LOGGED_IN")` | navigate to login.html |
| `login-step`, `login-after-install` RAW_SEND | bookkeeping only | no-op |
| `new-session` (`$zsessionManager.authenticate(session)`) | main SessionManager.setSession(session) (`{userId, UIN, …}`), dispatch only if changed | store; no reply |
| `db-authenticated` (`$zdb.authenticateDb(session)`) | MainDatabaseManager: store session, **broadcast `db-authenticated`(session)** to all registered DB clients (incl. the sender) | push `db-authenticated` back to the renderer with the same object |
| `db-client-connected` (`$zdb.notifyDbConnected(bundleName)`) | register client; **if a session is already known, `send("db-authenticated", session)`**; if a close is in progress forward `db-start-close-dbs` | same (on login page: no session → nothing) |
| `db-start-close-dbs` (`$zdb.requestCloseDbs(dbNames,bundleName,opts)`) | broadcast `db-start-close-dbs`(dbNames,bundleName,opts) to all clients; **promise resolves when every client called `notifyFinishCloseDb`** | push to renderer, resolve on `db-finish-close-dbs` |
| `zsafestorage-execute` (`$zsafeStorage.execute(method,...a)`) | `tGN0` singleton: methods `encryptString(s)→string`, `decryptString(s)→string`, `get(key)→string|null`, `set(key,val)`; backing electron-store `"zsafe-storage"`, key path `zsskd.<key>` (`.` forbidden); cipher selected by store key `zsskv`: `"1"` → Electron `safeStorage` (Keychain), else (default, written `"2"`) CryptoJS AES-256-CBC key `"d9c07b9de9915af401607d3f360211ac"`, IV `[155,72,37,195,9,217,80,42,145,102,171,75,214,176,134,18]`, output base64 | implement exactly (only Swift reads it back, but keep format) |
| `zproto-encrypt-with-keychain` (`$zprotocol.encryptWithKeychain(identifier, Uint8Array[], enableKeychain?)`) | SecureCipher: secret per identifier (`vn(id).toLowerCase()`): keychain mode (only if app is codesigned & enabled) → `safeStorage` encrypted 32-byte key in store `"zprotocol-config"` key `secure_ks_<id>`; else raw key XOR-masked with `8e1df793d3531b9f6bdaf3d0ac560b91` at `root_secret_<id>`. Per item: salt16, iv16, `hkdf(sha256, key, salt, "ZprotocolSecureKDF", 64)` → encKey=0..31, macKey=32..63; ct=AES-256-CBC; tag=HMAC-SHA256(macKey, ct‖iv‖salt); output `[type(0x4B keychain|0x49 raw)][iv][salt][ct][tag]` → returns array of Buffers (arrive as Uint8Array) | implement (use raw 0x49 mode; store key in Keychain or file) |
| `zproto-decrypt-with-keychain` (`(identifier, Uint8Array[])`) | inverse; `len<65` → throw; HMAC check | implement |
| `zproto-config-sync-to-main` (`{isEnableKeychainEnc}`) | set flag | store/no-op |

The renderer uses these for the **trusted-device / linking protocol** (`TrustProtocol`, `SecureCipher.encryptSafeStorage` → `$zprotocol.encryptWithKeychain`; zsafe-storage class `pQlW`) — it is on the QR path when the server sets `qr_format_trust_device` (see 2.5).

### 2.2 Storage-selection channels (force IndexedDB)

| channel | main | return in Swift |
|---|---|---|
| `sqlite-available` (`$zdb.canIUseSQLite`) | `!!nativelibs.sqlite3()` | **false** |
| `fail-load-sqlite3` (`$zdb.checkFailedLoadSqlite`) | `!getSqlite3LoadState()` (true = failed) | **true** |
| `is-migrate-full-done` (`$zFeatures.migrateDB.isMigrateFullDone`) | `FKO5.migrateFullyDone` | **false** |
| `get-migrate-local-info` (`(version,key)`) | stored per-key object or default | **`{disable_migrate:true}`** |
| `update-migrate-local-info` | merge & persist | resolve |
| `migratedb:check_need_wait_bu` | `!canMigrateWithCurrBUStatus(n)` | false |
| `migratedb:signal_restart` | **relaunch app** with RESTART_APP_ARGS | no-op |
| `migratedb:signal_done` | `migrateFullyDone=true` | no-op |
| `z-db-corruption-detector` (`$zdb.getIDBDatabaseHealthStatus`) | LevelDB snapshot compare → enum `OK=0, RESET_COUNTER=1, INVALID_COUNTER=2` | **0** |
| `get-name-of-target-script-for-dal-channel-from-host` | `"utility-process-sqlite"` or `"preload-sqlite"` | `"preload-sqlite"` (only matters with SQLite) |
| `SQLITE_BW/RELOAD`, `SQLITE_BW/PING`, `SQLITE_BW/DISPOSE`, `show-sqlite`, `status-load-sqlite3`, `shared-worker-req-events`, `shared-worker-resp-events` | SQLite helper window plumbing | resolve undefined |

### 2.3 Window/app channels used at startup

| channel | main | Swift |
|---|---|---|
| `_electron_get-path` (`getPath(name)`) | `"db"` → `IpzU.getDbPathRoot()`; else `app.getPath(name)` | names seen: `userData, appData, home, temp, exe, desktop, db` (+ downloads/documents [I]) |
| `_electron_get-path-sync` | `e.returnValue = app.getPath(name)` | sync |
| `_electron_get-app-version` | `app.getVersion()` | `"26.10.20"` |
| `_electron_get-app-path(-sync)` | `app.getAppPath()` | resources/app dir |
| `get-child-url`, `get-photo-viewer-url` | `getHtml("child.html")` / `getHtml("popup-viewer.html")` = `url.format({pathname:<resources>/pc-dist/<f>, protocol:"file:", slashes:true})` | file URL string |
| `get-resource-dir` | pc-dist dir | path |
| `renderer-ready` (`$zapp.notifyRendererReady(x)`) | init notification module + trustPathBoostrap(x) | resolve |
| `app-started` | `setMainAppStarted(true)` | resolve |
| `set-login-size`, `main-window-expand`, `minimize`, `focus-window`, `toggle-maximize`, `close-window` (hides, does not quit), `hide-window` | window geometry | map to NSWindow |
| `get-auth-domain-ready` (`$zresource.getAuthDomainReady`) | `bBLl.readyReceive()` → flag + `signalToRenderer()`, which pushes **only if a domain switch is pending** | resolve undefined |
| `get-auth-domain` (`$zresource.authError(info)`) | `bBLl.warning(info)` → may start service-map failover | resolve undefined |
| `script-connected`, `script-terminated`, `open-channel-to`, `port-delivered` | MessagePort broker between scripts/utility processes | resolve undefined (no utility processes) |
| `exec` / `exec_raw` / `cancel` (`$zFeatures.mainless`) | run Node method in `mainless-worker.js` thread pool (`zip, unzip, unzip2, md5, fileEexc, getDirSize, genThumbMac/WinOfficeBuffer, parseLink, parseBank, getLocalSize, cleanLocalResourceFolder, getTotalLocalFiles, getDirectorySizeInfo*, getInfoZipFile, getSubFolderFirstEntry`); returns result or `{error:{name,message,code}}`; progress via push `remote_events {id,...}` | return `{error:{name:"NotSupported"}}` (renderer rejects with it), implement `md5`/`parseLink` later if needed |
| `badge-count` | macOS dock badge (`>5` → `"5+"`) | NSDockTile |
| `_noti_*` | Electron Notification | UNUserNotificationCenter or no-op |

### 2.4 Page URLs main builds (`j6F3.qt`) [R]

`login.html` / `index.html` + `?type=23&client_version=694&app_version=26.10.20&about_version=&new_install=<0|1>` + `&zauthdm=<auth>&zdmapi=<api>` (if known) + optional `&pass_code &after_backup &after_crashed &major_version &db_version &fail_sqlite3=true &imei &phone &iso &code &quest_cert &cap_cert &already_login=y &mode_lang &new_install_success=1 &install_source`.
Note: main appends `failSqlite3` as **`fail_sqlite3=true`** whenever its sqlite3 native load failed; the renderer then sets `Ze.disableSqlite3=true` [R] → **add `&fail_sqlite3=true` to every page URL you load**.

### 2.5 Main → renderer pushes during login-page startup and QR login [R unless marked]

| when | push | how |
|---|---|---|
| every navigation start (`did-start-loading`) | `unload-zlog` (no args) | `Ne.webContents.send(z)` (`z = UNLOAD_ZLOG_CHANNEL`) |
| login.html `did-finish-load` (only when main itself loaded login via `sn()`) | `signal_USER_NOT_LOGGED_IN` (no args) | `$zlogin.onUserNotLogged` — the renderer doesn't subscribe to it in this build (0 uses) |
| window events | `visibility-change` with `"show"`, `"focus"` (+2nd arg `"1"`), `"blur"`, `"hide"`, `"minimize"`, `"maximize"`, `"unmaximize"` | `$zwindow.onVisibilityChange` (subscribed at boot) |
| every 10 s until answered | **`webContents.invoke("get-imei")`** → renderer PROVIDE handler (`$zresource.onRequestImei`) returns `{imei, installerType:"unknown", autoUpdaterConfig}`; main then `setCurrentIMEI` + starts updater | optional (only feeds updater); Swift may call it once to learn the imei |
| on domain fail-over only | `webContents.invoke("get-auth-domain-reply", encryptcl(JSON{wpa,zdmapi,zpw_sek}))` | not on normal startup |
| window close | `before-close` | — |
| powerMonitor | `event-os-changed` `"0"/"1"/"4"/"5"`, `resume-app-event` | — |
| after `notifyLoginSuccess` | navigate to index.html, then `login-success` | see 2.1 |
| updater (`update-is-avail` handler) | `binary-updated` | ignore |

There is **no** push the QR flow waits for. After `getServerInfo` → `reqqr`, the renderer (lazy `login-startup` chunk) runs:

```js
const d=await We.default.getQRCode(imei, loggedUids, lang, self_g?1:0, qr_format_trust_device?1:0) // reqqr
r.base64Qr = await tr.a().genFirstQR(qr_format_trust_device ? e.tokenId : e.qrCnt, e.base64Qr, self_g)
D(i)  // → long-poll waitingScan (chkWaitScan URL), then waitingConfirm
```

`genFirstQR` returns the server PNG immediately unless `serverConfig.qr_format_trust_device` (merged from server config) is true; then it does `await Q().createLinkingState()` and `this._deviceLinkingState.generateQr(...)` — the **trusted-device protocol** (TrustProtocol worker + TrustStorage DB + `$zprotocol.encrypt/decryptWithKeychain` + `$zsafeStorage.execute`) [R for the call chain; I that the worker/DB layer is what blocks]. The trust DB goes through the DAL engine → adapter selection (`getAdapterTypeOfSharedDatabases`: reads electron-store `"database-config"` key `adp-st`, awaits `$zFeatures.migrateDB.isMigrateFullDone()` and the `upgradeRequired` flag) → IndexedDB. Therefore, for the stall:

1. Every REQUEST/NOTIFY stub must **resolve** (default `undefined`) — a pending `isMigrateFullDone` / `getIDBDatabaseHealthStatus` / `notifyDbConnected` / `notifyScriptConnected` blocks the DB layer.
2. Return the concrete values from 2.2 (`isMigrateFullDone:false`, `canIUseSQLite:false`, `checkFailedLoadSqlite:true`, `getIDBDatabaseHealthStatus:0`).
3. `$zprotocol.encryptWithKeychain` must return an **array of Uint8Array** same length/order as input; `decryptWithKeychain` likewise.
4. `$zsafeStorage.execute("get",k)` → string or `null`; `"set"` → undefined.
5. `getViewerkey` must reject when there's no file.
6. IndexedDB must work for the page origin (see §3).
7. Local-only functions: `$zpreload.triggerWindowLoadedEvent()` returns undefined; `$zapp.beforeAppQuit/beforeAppClose` are just SUBSCRIBE registrations (no reply needed).

After the phone confirms: `setAppCookie(zpw_sek)` → `gr()` (link-device completion, `sr.d({encK:"",refreshToken:zpw_kt})` = save renew-session data, timeout 30 s) → `localStorage.login_info=…` → `$zlogin.notifyLoginSuccess()` → you navigate to index.html.

---

## 3. Critical path & what can be no-op'd

### (a) login.html → QR → index.html

| step | members (boot order observed + code) | minimal faithful Swift |
|---|---|---|
| preload | `$zenv`, all globals defined before page scripts (WKUserScript at documentStart, main frame) | inject |
| 1 | `$zFileManager.getSentryConfig()` (sync) | `null` |
| 2 | `$zelectron.getAppVersion()` | `"26.10.20"` |
| 3 | `$zelectron.getPath("userData")` | real dir |
| 4 | `$zelectron.getElectronStore({name:"database-config"})` | JS store over injected snapshot |
| 5 | `$zwindow.onVisibilityChange(cb)` | register; push `visibility-change "show"/"focus"` when window shows |
| 6 | `$znode.path.sep/join`, `$znode.fsExtra.ensureDir(p,null,cb)`, `$znode.fs.constants.F_OK`, `$znode.fs.access(p,mode,cb)` | **callback style!** (§0.5) |
| 7 | `$zresource.onRequestImei(fn)` | store fn (PROVIDE) |
| 8 [I: order] | `$zdb.notifyDbConnected("login")`, `$zdb.checkFailedLoadSqlite`, `$zdb.canIUseSQLite`, `$zFeatures.migrateDB.isMigrateFullDone`, `$zdb.getIDBDatabaseHealthStatus`, `$zscript.notifyScriptConnected`, `$zconfig.getThemeConfig`, `$zapp.notifyRendererReady` … | resolve with §2.2 values |
| 9 | HTTP: getServerInfo → reqqr → (trust protocol: `$zprotocol.*`, `$zsafeStorage.*`, IDB) → waitingScan → waitingConfirm | proxy |
| 10 | `$zelectron.setAppCookie(zpw_sek)` | cookie jar (3 domains) |
| 11 | `$zlogin.notifyLoginSuccess()` | load index.html (§2.4 + `already_login=y`), then push `login-success` |

Persistence between pages [R]: imei = localStorage `z_uuid` (`uuid + "-" + md5(navigator.userAgent)`, generated on first use; also accepted from URL `imei=`); login sets `login_info`, `z_needSyncMsg`, `FORCE_GET_FRIEND_LIST`, etc. in localStorage. **login.html and index.html must share origin + localStorage + IndexedDB.** Session itself = cookie `zpw_sek` (+ server Set-Cookie cookies); main decides at startup by `cookies.get({url:authDomain /*default https://wpa.zaloapp.com*/})` containing `zpw_sek` → index.html, else login.html [R, `tGN0`/`j6F3.Sn`].

### (b) index.html → conversations → WebSocket

- Same boot members as login plus: `$zsessionManager.authenticate(session)`, `$zdb.authenticateDb(session)` (push `db-authenticated` back), `$zapp.notifyAppStarted`, `$zwindow.expandMainWindow`, `$zFeatures.activeDeactive.setup/createTimer/getIdleTime`, `$zapp.registerIdleCheckInterval`, `$zconfig.updateRemoteConfigs`, `$zsharedWorker.show` (no-op), `$zFeatures.mainless.execRaw` (return `{error}`), `$zMsgChannel.*` (no-op), `$zFileManager.*` reads for avatars/files, `$zlogger.loadShellQos` (no-op).
- The WebSocket is a plain browser `new WebSocket(this._config.url + "&t=" + Date.now())`, `binaryType="arraybuffer"` [R] — **no bridge member involved**; you only need cookies + UA on the upgrade.
- Session data comes from HTTP (`/api/login/getLoginInfo` etc.) using the cookie jar [I].

### (c) sending a text message
No bridge member is required [I: no `$z*` reference in the send path; it is XHR/WS + IndexedDB]. Side calls that should resolve: `$zapp.updateBadgeCount`, `$znoti.*`, `$zFeatures.transfer.notifyReceiveMediaMsgs`.

### Safe to no-op (resolve `undefined`, or a falsy/empty value)
`$zupdater.*`, `$zMetric.*`, `MetriczGlobal.*`, `$zlogger.*` (QoS/GA/zlog; `checkRecentCrash`→false), `$zperf.*`, `$zcall.*`, `$zscreencap.*`, `$zInAppPayment.*`, `$capp.*`, `$zbackup.*`, `$zMigrateDrive.*`, `$zTFModels.ss.*` (getters → null), `$zFeatures.{kikiAssistant,zaloCall,ocr,languageDetector (isSupported→{supported:false}),libvips,libjxl,zwalker,fileWalkerStream,syncDownload,genThumb}`, `$zsqlitebw.*`, `$zsharedWorker.*`, `$zMsgChannel.*`, `$zscript.*`, `$znetwork.*`, `$zcloud.*` (except if you need file helpers), `$zmulti.*`, `$zconfig.checkAutoLaunchEnable`→false, `$zresource.getRecentFiles`→[].

---

## 4. SQLite vs IndexedDB, native modules

- Default adapter type for every DB is **IDB** (`JTyQ`: `const s="adp-st", i=a.a.IDB, o=a.a.IDB`) [R]. The adapter-state service (`nUpV`, lazy chunk `default-login-main-startup-shared-worker.dc4740…`) switches a DB to SQLite only if `await $zFeatures.migrateDB.isMigrateFullDone()` is true **or** the `"database-config"` store has the `upgradeRequired` key (`fzd6`) [R]. `adapterManager.canUse(SQLite)` additionally requires `await $zdb.canIUseSQLite()` [R].
- Legacy search index uses sqlite over IPC unless `$zdb.checkFailedLoadSqlite()` → true or URL `fail_sqlite3=true` (`_useIPC=false` → web worker) [R].
- The IDB→SQLite migration UI (`main-startup` chunk) may call `$zFeatures.migrateDB.signalRestartAppToMigrate()` ("first session, silent migrate") → make it a no-op and return `{disable_migrate:true}` from `getMigrateLocalInfo` so it logs "force skip migrate" [R].
- **Recipe (IndexedDB)**: `isMigrateFullDone→false`, `canIUseSQLite→false`, `checkFailedLoadSqlite→true`, `getMigrateLocalInfo→{disable_migrate:true}`, URL `&fail_sqlite3=true`, never create `upgradeRequired` in `database-config.json`.
- **Recipe (SQLite host)**: `isMigrateFullDone→true`, `canIUseSQLite→true`, `getNameOfTargetScriptForDALChannelFromHost→"utility-process-sqlite"`, plus a MsgChannel broker and the utility-process port protocol — see `REVERSE-ENGINEERING-NOTES.md` § SQLite host (Olaz: `HostScripts/sqlite-host.js`, `ZaloRuntime/SQLiteHost.swift`).
- Other native `.node` users: `$znode.nativelibs` (sqlite3, zimage, zjxl, zlang, ocr…) via `require("../native/nativelibs")`; `$zFeatures.libvips/libjxl/ocr/languageDetector` (main-side `EXGp`); mainless worker. Return errors/unsupported.
- IndexedDB in WKWebView: Electron used partition `persist:zalo` (LevelDB under `Partitions/zalo/IndexedDB`). WebKit does not give `file://` documents persistent IndexedDB reliably [I] — prefer a custom scheme (`WKURLSchemeHandler`) serving pc-dist **but** the renderer checks `e.origin === "file://"` for SUBSCRIBE_V2 port messages and sends `ref=window.location.origin` on some auth APIs when `le` is true [R] — keep that in mind if you change the origin.

---

## 5. Network: cookies, UA, headers

| item | main.js [R] |
|---|---|
| User-Agent | `Ne.webContents.setUserAgent("ZaloPC-"+process.platform+"-"+J()+"v"+X())` → **`ZaloPC-darwin-23v694`** (whole UA replaced; also passed to multi-window manager for child windows). In-app browser window uses default UA with "Zalo"→"ZaloPC". |
| Session | `webPreferences.partition:"persist:zalo"`, `webSecurity:true` (prod), `contextIsolation:true`, `sandbox:false`, `nodeIntegration:false` |
| Request header rewriting | **none**: no `onBeforeSendHeaders` / `onBeforeRequest` anywhere in main.js. |
| `webRequest.onSendHeaders` | observe only: maps `X-ZA-RequestId` request header → request id (for `$zapp.checkNetworkTimeout(requestId)` → `{requestId, sent}`) (`PQA1`) |
| `webRequest.onCompleted/onErrorOccurred` | observe only (net-error QoS, `znet-error-code` push on cert-date errors for `p\d+-(msg|ctl)-chat.<dm>`) |
| `webRequest.onHeadersReceived` | only kiki OAuth CSP monitor (sub-frames); passes `responseHeaders` through unchanged |
| CORS | not touched → Chromium CORS applies; servers must already answer the `file://` origin [I]. With a Swift proxy you control the response, add ACAO/ACAC for your page origin. |
| Cookies set by main | `zpw_sek` (setAppCookie: zaloapp.com, zalo.me, chat.zalo.me, 7 d, httpOnly, secure, SameSite=None); `setCookie` generic (365 d); legacy migrations: native-app `zpw_sek` (Windows only), `_remme_` on `zclient.zalo`. All other cookies come from server `Set-Cookie` → your jar must accept & send them (including on the WSS upgrade). |
| Startup cookie check | `cookies.get({url: authDomain})`, `{url:"https://zclient.zalo"}`, `{url:"https://zaloapp.com"}` → `zpw_sek` present ⇒ index |
| Proxy | `session.setProxy({proxyRules:"http://…|socks5://…,direct://"})` from stored config (`proxy-set`) |
| Cert | `XVBg` installs `setCertificateVerifyProc` (default+partition) when cert config enabled — logging/known-root checks; Swift: default trust |
| Chromium switches | `ignore-connections-limit=files-wpa.zaloapp.com`, `disable-pinch`, `enable-features=JXL` |
| Default domains | auth `https://wpa.zaloapp.com` (`XPAe.DEFAULT_AUTH_DOMAIN`), service map from `…/service_map_pc.bin` mirrors (main-side failover) |

---

## Appendix — every table-driven member

`kind`: async = returns Promise; sync = blocking; send = fire & forget; event on/off = subscription. `uses` = number of call sites in renderer bundles (includes `$zsub.` wrappers; duplicated chunks inflate counts). "main side" = handler (manual summary or trimmed `FEqq` source, logs elided).

### `$zwindow`

| member | kind | ipc | channel | main side | uses |
|---|---|---|---|---|---|
| minimize | async | invoke | `minimize` | `BrowserWindow.fromWebContents/ id → minimize()` | 13 |
| maximizeToggler | async | invoke | `toggle-maximize` | `maximizeToggler:(e,t,n)=>{const r=Object(s.b)(e.sender,t);if(r){return(void 0!==n?n:!r.isMaximized())?r.maximize():r.unmaximize()}log()}` | 8 |
| setLoginSize | async | invoke | `set-login-size` | `loginResize()` → fixed login window size | 10 |
| expandMainWindow | async | invoke | `main-window-expand` | `expandWindowOnAuthenticated()` → main window size/limits | 16 |
| isMaximized | async | invoke | `check-maximize` | `isMaximized:(e,t)=>{const n=Object(s.b)(e.sender,t);return n&&!n.isDestroyed()?n.isMaximized():(log(),!1)}` | 4 |
| isFullScreen | async | invoke | `check-fullscreen` | `isFullScreen:(e,t)=>{const n=Object(s.b)(e.sender,t);return n&&n.fullScreenable?n.isFullScreen():(log(),!1)}` | 0 |
| fullscreenToggler | async | invoke | `toggle-fullscreen` | `fullscreenToggler:(e,t,n)=>{const r=Object(s.b)(e.sender,t);if(r){return(void 0!==n?n:!r.isFullScreen())?r.setFullScreen(!0):r.setFullScreen(!1)}log()}` | 0 |
| flashFrame | async | invoke | `flash-frame` | `flashFrame:(e,t,n)=>{if("win32"!==process.platform)return;const r=Object(s.b)(e.sender,n);if(r)return t?r.flashFrame(!0):r.flashFrame(!1);log()}` | 0 |
| focus | async | invoke | `focus-window` | focus window (photo/file viewer ids special-cased) | 62 |
| closeWindow | async | invoke | `close-window` | `closeWindow:(e,t)=>{if(t&&[d.Constants.PHOTO_VIEWER_ID,d.Constants.FILE_VIEWER_ID].some((e=>e===t)))return void u.ZPopupWindowMainManager.close(t);const n=Object(s.b)(e.s…` | 13 |
| hide | async | invoke | `hide-window` | `hide:(e,t)=>{if(t&&[d.Constants.PHOTO_VIEWER_ID,d.Constants.FILE_VIEWER_ID].some((e=>e===t)))u.ZPopupWindowMainManager.hide(t).catch((e=>{log()})).finally((()=>{e.sender&…` | 7 |
| setContentProtection | async | invoke | `set-content-protection` | `setContentProtection:(e,t,n)=>{try{const r=Object(s.b)(e.sender,t);if(!r\|\|r.isDestroyed())return void log();r.setContentProtection(n),log()}catch(r){log()}}` | 1 |
| showInactive | async | invoke | `show-inactive` | `showInactive:(e,t)=>{const n=Object(s.b)(e.sender,t);n?n.showInactive():log()}` | 1 |
| show | async | invoke | `show` | `show:(e,t)=>{const n=Object(s.b)(e.sender,t);n?(n.isMaximized()\|\|n.show(),setTimeout((()=>{n.setOpacity(1)}),300)):log()}` | 0 |
| quit | async | invoke | `quit` | `quit:e=>{const{appQuitFlow:t}=n("DfAL");t.requestQuitApp()}` | 1 |
| showOpenDialog | async | invoke | `show-open-dialog` | `dialog.showOpenDialog(win,opts)` → `{canceled,filePaths}`; picked paths added to trust list | 56 |
| showSaveDialog | async | invoke | `show-save-dialog` | `dialog.showSaveDialog` → `{canceled,filePath}`; trusted | 24 |
| showOpenDialogSync | async | invoke | `show-open-dialog-sync` | `showOpenDialogSync:(e,t)=>{let n=o.BrowserWindow.getFocusedWindow();n\|\|(n=o.BrowserWindow.fromWebContents(e.sender));const r=o.dialog.showOpenDialogSync(n,t);return nul…` | 0 |
| showSaveDialogSync | async | invoke | `show-save-dialog-sync` | `showSaveDialogSync:(e,t)=>{let n=o.BrowserWindow.getFocusedWindow();n\|\|(n=o.BrowserWindow.fromWebContents(e.sender));const r=o.dialog.showSaveDialogSync(n,t);return Obj…` | 0 |
| onVisibilityChange | event on | on | `visibility-change` | main → renderer push (22 send-sites found) | 37 |
| removeListenVisibilityChange | event off (removeAll) | removeAllListeners | `visibility-change` | local only | 20 |
| onHideWindowComplete | event on | on | `hide-window-complete` | main → renderer push (1 send-sites found) | 0 |
| removeListenHideWindowComplete | event off (removeAll) | removeAllListeners | `hide-window-complete` | local only | 0 |
| openPhotoViewerDevtool | async | invoke | `open-photo-viewer-devtool` | `openPhotoViewerDevtool:()=>{u.ZPopupWindowMainManager.openDevtools(d.Constants.PHOTO_VIEWER_ID)}` | 4 |
| onUnloadZLog | event on | on | `unload-zlog` | push (no direct send-site found; may be sent by helper/never) | 5 |
| removeListenUnloadZLog | event off (removeAll) | removeAllListeners | `unload-zlog` | local only | 5 |
| onCloseMediaViewer | event on | on | `close-media-viewer` | main → renderer push (1 send-sites found) | 4 |
| removeListenCloseMediaViewer | event off (removeAll) | removeAllListeners | `close-media-viewer` | local only | 4 |

### `$zresource`

| member | kind | ipc | channel | main side | uses |
|---|---|---|---|---|---|
| getPhotoviewerUrl | async | invoke | `get-photo-viewer-url` | `getHtml("popup-viewer.html")` | 4 |
| getChildUrl | async | invoke | `get-child-url` | `getHtml("child.html")` = `file://<resources>/pc-dist/child.html` | 4 |
| onClipboardChange | event on | on | `clipboard-change` | main → renderer push (2 send-sites found) | 1 |
| removeListenClipboardChange | event off (removeAll) | removeAllListeners | `clipboard-change` | local only | 0 |
| onRequestImei | renderer-side handler | handle (polyfill) | `get-imei` | main calls `webContents.invoke("get-imei",…)` (1 sites) | 5 |
| removeListenRequestImei | remove handler | removeHandler | `get-imei` | local only | 5 |
| getResourceDir | async | invoke | `get-resource-dir` | `getResourceDir()` (pc-dist dir) | 0 |
| onCheckIdleUpdaterBusy | renderer-side handler | handle (polyfill) | `check-updater-busy` | main calls `webContents.invoke("check-updater-busy",…)` (3 sites) | 4 |
| removeListenCheckIdleUpdateBusy | remove handler | removeHandler | `check-updater-busy` | local only | 0 |
| getRecentFiles | async | invoke | `get-recent-file` | Windows Recent folder shortcuts → return [] | 4 |
| authError | async (fire&forget, still invoke) | invoke | `get-auth-domain` | `bBLl.warning(info)` – service-map failover trigger. No-op | 4 |
| getAuthDomainReady | async (fire&forget, still invoke) | invoke | `get-auth-domain-ready` | `bBLl.readyReceive()` → sets ready flag and calls signalToRenderer(), which **only pushes if a domain switch is pending** (`_SwitchToNewData`) | 4 |
| getAuthDomainReply | renderer-side handler | handle (polyfill) | `get-auth-domain-reply` | main calls `webContents.invoke("get-auth-domain-reply",…)` (1 sites) | 4 |
| onBackupAppState | renderer-side handler | handle (polyfill) | `backup-app-state` | main calls `webContents.invoke("backup-app-state",…)` (1 sites) | 1 |
| removeListenBackupAppState | remove handler | removeHandler | `backup-app-state` | local only | 1 |
| onRestoreAppState | renderer-side handler | handle (polyfill) | `restore-app-state` | main calls `webContents.invoke("restore-app-state",…)` (1 sites) | 1 |
| removeListenRestoreAppState | remove handler | removeHandler | `restore-app-state` | local only | 1 |

### `$zlogger`

| member | kind | ipc | channel | main side | uses |
|---|---|---|---|---|---|
| crossQosLog | async | invoke | `cross_OS_LOG_QOS` | QoS log relay → no-op | 11 |
| crossQosConfig | async (fire&forget, still invoke) | invoke | `cross_OS_LOG_QOS_config` | `crossQosConfig:(e,...t)=>{const{logControl:r}=n("qkcG");r?r.updateConfig(e,...t):log()}` | 8 |
| notifyOsCloseMain | async (fire&forget, still invoke) | invoke | `signal_OS_CLOSE_MAIN` | `notifyOsCloseMain:(e,...t)=>{const{logControl:r}=n("qkcG");r?(r.readyAction(e,...t),r.readyQos(e,...t)):log()}` | 4 |
| notifyQosReady | async (fire&forget, still invoke) | invoke | `cross_OS_LOG_QOS_READY` | `notifyQosReady:(e,...t)=>{const{logControl:r}=n("qkcG");r?r.readyQos(e,...t):log()}` | 4 |
| onQosLog | event on | on | `cross_OS_LOG_QOS` | main → renderer push (1 send-sites found) | 8 |
| onActionLog999 | event on | on | `cross_ACTION_LOG_999_CHANNEL` | main → renderer push (1 send-sites found) | 4 |
| removeListenActionLog999 | event off (removeAll) | removeAllListeners | `cross_ACTION_LOG_999_CHANNEL` | local only | 4 |
| removeListenQosLog | event off (removeAll) | removeAllListeners | `cross_OS_LOG_QOS` | local only | 0 |
| notifyActionLogReady | async (fire&forget, still invoke) | invoke | `cross_OS_LOG_ACTION_READY` | `notifyActionLogReady:(e,...t)=>{const{logControl:r}=n("qkcG");r?r.readyAction(e,...t):log()}` | 4 |
| onActionLog | event on | on | `cross_OS_LOG_ACTION` | main → renderer push (1 send-sites found) | 4 |
| removeListenActionLog | event off (removeAll) | removeAllListeners | `cross_OS_LOG_ACTION` | local only | 4 |
| onMainUncaughtError | event on | on | `main-process-uncaught-error` | main → renderer push (1 send-sites found) | 4 |
| removeListenMainUncaughtError | event off (removeAll) | removeAllListeners | `main-process-uncaught-error` | local only | 4 |
| sendLog | async (fire&forget, still invoke) | invoke | `log` | zlog from renderer → no-op | 6 |
| sendLogGa | async (fire&forget, still invoke) | invoke | `log-ga` | GA → no-op | 0 |
| sendViewerkey | async (fire&forget, still invoke) | invoke | `receive-viewerkey` | `sendViewerkey:(e,t)=>{const{crashReporter:r}=n("NLsH"),i=n("Htpd"),o=n("Bkv4");r.addExtraParameter("sentry[tags][viewer_key]",t),o.setTag("viewer_key",t),i.receiveViewerK…` | 4 |
| onReceiveViewerkey | event on | on | `receive-viewerkey` | main → renderer push (1 send-sites found) | 1 |
| removeListenViewerkey | event off (removeAll) | removeAllListeners | `receive-viewerkey` | local only | 0 |
| loadShellQos | async | invoke | `load-shell-qos` | QoS → no-op | 1 |
| checkRecentCrash | async | invoke | `check-recently-crash` | → false | 0 |

### `$zupdater`

| member | kind | ipc | channel | main side | uses |
|---|---|---|---|---|---|
| requestUpdate | async | invoke | `update-is-avail` | (handler) `send("binary-updated", pendingUpdate)` | 0 |
| requestCheckUpdate | async (fire&forget, still invoke) | invoke | `z-check-for-update` | binary updater check → no-op | 4 |
| onNewUpdate | event on | on | `binary-updated` | main → renderer push (4 send-sites found) | 17 |
| onNewManualUpdate | event on | on | `z-manual-binary-updated` | main → renderer push (2 send-sites found) | 17 |
| onFallbackUpdate | event on | on | `fallback-update` | main → renderer push (1 send-sites found) | 5 |
| removeListenNewUpdate | event off (removeAll) | removeAllListeners | `binary-updated` | local only | 16 |
| removeListenNewManualUpdate | event off (removeAll) | removeAllListeners | `z-manual-binary-updated` | local only | 16 |
| removeListenFallbackUpdate | event off (removeAll) | removeAllListeners | `fallback-update` | local only | 8 |
| onResourceUpdate | event on | on | `resources-updated` | main → renderer push (1 send-sites found) | 4 |
| removeResourceUpdate | event off (removeAll) | removeAllListeners | `update-is-avail` | local only | 4 |
| onManualUpdateInstalling | event on | on | `z-manual-update-installing` | main → renderer push (1 send-sites found) | 8 |
| removeListenManualUpdateInstalling | event off (removeAll) | removeAllListeners | `z-manual-update-installing` | local only | 8 |
| onManualUpdateDownloading | event on | on | `z-manual-update-downloading` | main → renderer push (1 send-sites found) | 12 |
| removeListenManualUpdateDownloading | event off (removeAll) | removeAllListeners | `z-manual-update-downloading` | local only | 12 |
| onManualUpdateChecked | event on | on | `z-manual-update-checked` | main → renderer push (1 send-sites found) | 8 |
| removeListenManualUpdateChecked | event off (removeAll) | removeAllListeners | `z-manual-update-checked` | local only | 8 |
| onManualUpdateCheckedOnly | event on | on | `z-manual-update-checked-only` | main → renderer push (1 send-sites found) | 8 |
| removeListenManualUpdateCheckedOnly | event off (removeAll) | removeAllListeners | `z-manual-update-checked-only` | local only | 8 |
| onManualUpdateCheckOnlyErr | event on | on | `z-manual-update-checked-only-err` | push (no direct send-site found; may be sent by helper/never) | 8 |
| removeListenManualUpdateCheckOnlyErr | event off (removeAll) | removeAllListeners | `z-manual-update-checked-only-err` | local only | 8 |
| onManualUpdateErr | event on | on | `z-manual-update-err` | main → renderer push (3 send-sites found) | 8 |
| removeListenManualUpdateErr | event off (removeAll) | removeAllListeners | `z-manual-update-err` | local only | 8 |
| requestCheckDownloadUpdate | send (no reply) | send | `z-manual-check-download-update` | j6F3: starts manual updater. No-op | 8 |
| requestCheckDownloadUpdateOnly | async (fire&forget, still invoke) | invoke | `z-manual-check-download-update-only` | `requestCheckDownloadUpdateOnly:e=>{const t=n("F0FE"),{checkPendingUpdate:r}=n("j6F3");t.checkUpdateOnly(r())}` | 8 |
| requestResourceReload | async (fire&forget, still invoke) | invoke | `resources-reload-safe` | `requestResourceReload:e=>{const{reloadResourceOnUpdate:t}=n("j6F3");t()}` | 4 |
| requestBinaryReload | async (fire&forget, still invoke) | invoke | `binary-reload-safe` | `requestBinaryReload:e=>{const{binaryReloadSafe:t}=n("j6F3");t()}` | 16 |
| requestManualBinaryReload | async (fire&forget, still invoke) | invoke | `manual-binary-reload-safe` | `requestManualBinaryReload:e=>{const{manualBinaryReloadSafe:t}=n("j6F3");t()}` | 8 |
| openUpdatePage | async (fire&forget, still invoke) | invoke | `OPEN_UPDATE_PAGE` | `openUpdatePage:e=>{Object(L.openExternal)("https://zalo.me/pc")}` | 6 |
| onReceiveUpdateInfo | event once | once | `receive-update-info` | main → renderer push (1 send-sites found) | 4 |
| onUncaughtError | event off (removeAll) | removeAllListeners | `updater-uncaught-error` | local only | 4 |
| removeListenUncaughtError | event off (removeAll) | removeAllListeners | `updater-uncaught-error` | local only | 4 |

### `$zapp`

| member | kind | ipc | channel | main side | uses |
|---|---|---|---|---|---|
| notifyRendererReady | async (fire&forget, still invoke) | invoke | `renderer-ready` | O0oV.init(arg, mainWindow) (notifications) + trustPathBoostrap(arg) | 4 |
| notifyAppStarted | async (fire&forget, still invoke) | invoke | `app-started` | `setMainAppStarted(true)` | 1 |
| onRequestShowAbout | event on | on | `about` | main → renderer push (2 send-sites found) | 1 |
| onRequestShowPreference | event on | on | `preferences` | main → renderer push (1 send-sites found) | 5 |
| removeListenShowAbout | event off (removeAll) | removeAllListeners | `about` | local only | 0 |
| removeListenShowPreference | event off (removeAll) | removeAllListeners | `preferences` | local only | 4 |
| beforeAppQuit | event on | on | `app-before-quit` | main → renderer push (1 send-sites found) | 5 |
| removeListenBeforeAppQuit | event off (removeAll) | removeAllListeners | `app-before-quit` | local only | 1 |
| beforeAppClose | event on | on | `before-close` | main → renderer push (1 send-sites found) | 4 |
| removeListenBeforeAppClose | event off (removeAll) | removeAllListeners | `before-close` | local only | 0 |
| checkNetworkTimeout | async | invoke | `CHECK_NETWORK_TIMEOUT_ERR` | `checkNetworkTimeout:(e,t)=>{const{checkNetworkTimeoutMain:r}=n("PQA1");return r(e,t)}` | 4 |
| requestShowFromTray | event on | on | `show-from-tray` | main → renderer push (1 send-sites found) | 4 |
| removeListenRequestShowFromTray | event off (removeAll) | removeAllListeners | `show-from-tray` | local only | 4 |
| notifyClickNoti | async (fire&forget, still invoke) | invoke | `noti-click` | `notifyClickNoti:(e,t)=>{const n=F.a.getMainWindow();n&&n.webContents.send(M.a.NOTI_CLICK,t)}` | 1 |
| onClickNoti | event on | on | `noti-click` | main → renderer push (1 send-sites found) | 8 |
| removeListenClickNoti | event off (removeAll) | removeAllListeners | `noti-click` | local only | 8 |
| onRequestRestartAppForBackup | event on | on | `bu-ask-restart` | main → renderer push (1 send-sites found) | 1 |
| removeListenBackupRestartReq | event off (removeAll) | removeAllListeners | `bu-ask-restart` | local only | 1 |
| notifyDbFail | async (fire&forget, still invoke) | invoke | `signal-db-fail` | `notifyDbFail:e=>{}` | 1 |
| notifyDbCorruption | async (fire&forget, still invoke) | invoke | `signal-db-corruption` | `notifyDbCorruption:e=>{n("BUsq").getInstance().onDBCorruption()}` | 1 |
| requestHideBeforeQuit | send (no reply) | send | `z-hide-app-before-quit` | j6F3: sets quitting flag, `mainWindow.hide()` | 4 |
| onOsRequestRestart | event on | on | `os-force-restart` | main → renderer push (1 send-sites found) | 4 |
| removeListenOsRestart | event off (removeAll) | removeAllListeners | `os-force-restart` | local only | 4 |
| requestQuitAppImmediately | async | invoke | `do-quit` | `requestQuitAppImmediately:e=>{H.appQuitFlow.quit()}` | 2 |
| cancelQuitApp | async | invoke | `cancel-quit` | `cancelQuitApp:e=>{H.appQuitFlow.cancelQuit()}` | 1 |
| osConfirmRestart | async | invoke | `os-confirm-restart` | `osConfirmRestart:e=>{const{osConfirmRestart:t}=n("j6F3");t()}` | 12 |
| restartByZAM | async | invoke | `ZAM_RESET_DB` | `restartByZAM:e=>{n("ADpw")._restartApp()}` | 16 |
| onConfirmAppQuit | event on | on | `before-quit` | main → renderer push (1 send-sites found) | 1 |
| removeListenConfirmAppQuit | event off (removeAll) | removeAllListeners | `before-quit` | local only | 1 |
| onNetErr | event on | on | `znet-error-code` | main → renderer push (1 send-sites found) | 4 |
| removeListenNetErr | event off (removeAll) | removeAllListeners | `znet-error-code` | local only | 4 |
| onRequestShowOpenFile | event on | on | `zfile-popup` | main → renderer push (1 send-sites found) | 4 |
| removeListenShowOpenFile | event off (removeAll) | removeAllListeners | `zfile-popup` | local only | 4 |
| onReceiveArgument | event on | on | `receive-arguments` | main → renderer push (1 send-sites found) | 4 |
| removeListenReceiveArguments | event off (removeAll) | removeAllListeners | `receive-arguments` | local only | 4 |
| onShowToastFromMain | event on | on | `show-toast-from-main` | push (no direct send-site found; may be sent by helper/never) | 4 |
| removeListenToastFromMain | event off (removeAll) | removeAllListeners | `show-toast-from-main` | local only | 4 |
| registerProcess | async (fire&forget, still invoke) | invoke | `zmain_register_process` | `registerProcess:(e,t,r)=>{n("T7kW").register(t,r)}` | 6 |
| onPing | renderer-side handler | handle (polyfill) | `zping` | main calls `webContents.invoke("zping",…)` (1 sites) | 1 |
| removeListenPing | remove handler | removeHandler | `zping` | local only | 0 |
| requestCreateNoti | async | invoke | `noti-create` | `requestCreateNoti:(e,t)=>{const{onReceiveCreateNoti:r}=n("j6Qk");r(t)}` | 4 |
| onRequestShowNoti | event on | on | `noti-create` | main → renderer push (2 send-sites found) | 1 |
| notifyNotiReady | async | invoke | `noti-ready` | `notifyNotiReady:e=>{const{onNotiReady:t}=n("j6Qk");t()}` | 1 |
| notifyRelaunchMode | send (no reply) | send | `receive-relaunch-mode` | j6F3: stores crash auto-relaunch mode/timeout. No-op | 0 |
| changeLanguage | send (no reply) | send | `language-change` | ML2M context-menu module: `s=t` (context-menu language). No-op | 18 |
| enableNetHandler | async | invoke | `enable-net-handler` | `enableNetHandler:(e,t=0)=>{const r=n("PQA1"),i=F.a.getMainWindow();t&&!r.isEnabled&&r.attachNetErrorHandlers(i)}` | 4 |
| updateCurrentUserId | send (no reply) | send | `ChatApp-receive-userId` | j6F3: `Ln=t; Mn()` → flushes pending argv (`receive-arguments`) to renderer. No-op | 4 |
| getProxyConfig | async | invoke | `proxy-get` | returns stored proxy config or undefined | 0 |
| setProxyConfig | send (no reply) | send | `proxy-set` | j6F3: stores proxy in appConfig (`pass` CBC-encoded) and `session.setProxy` | 0 |
| updateBadgeCount | async | invoke | `badge-count` | macOS: `app.dock.setBadge` (>5 → "5+") / bounce | 28 |
| updateCertConfig | async (fire&forget, still invoke) | invoke | `cert-config` | `updateCertConfig(e,...t){const{TConfigCertsConsumer:r}=n("JYJ5");U.ModuleContainer.resolve(r).invokeUpdateConfig(e,...t)}` | 4 |
| beforeAppRestartSilently | event on | on | `app-before-restart-silently` | main → renderer push (1 send-sites found) | 1 |
| removeListenBeforeAppRestartSilently | event off (removeAll) | removeAllListeners | `app-before-restart-silently` | local only | 1 |
| afterAppRestartSilently | event on | on | `app-after-restart-silently` | main → renderer push (1 send-sites found) | 1 |
| removeListenAfterAppRestartSilently | event off (removeAll) | removeAllListeners | `app-after-restart-silently` | local only | 1 |
| registerIdleCheckInterval | async (fire&forget, still invoke) | invoke | `register-idle-check-interval` | `registerIdleCheckInterval(e,t){const n=U.ModuleContainer.resolve(j.b),{processId:r,sender:i}=e,o={processId:r,webContents:i};n.preload_onIdleCheckIntervalRegistered(o,t)}` | 1 |
| onStartIdle | event on | on | `start-idle` | main → renderer push (2 send-sites found) | 1 |
| removeListenStartIdle | event off (removeAll) | removeAllListeners | `start-idle` | local only | 1 |
| onEndIdle | event on | on | `end-idle` | main → renderer push (1 send-sites found) | 1 |
| removeListenEndIdle | event off (removeAll) | removeAllListeners | `end-idle` | local only | 1 |
| setMainWindowResizable | async (fire&forget, still invoke) | invoke | `set-main-window-resizable` | `setMainWindowResizable(e,t){const{getMainWindow:r}=n("j6F3"),i=r();i&&i.setResizable(t)}` | 21 |
| onListenSwitchTab | event on | on | `switch_tab` | main → renderer push (3 send-sites found) | 4 |
| requestRelaunch | async | invoke | `request_relaunch` | `requestRelaunch:e=>{n("ADpw")._requestRelaunchApp()}` | 9 |
| onAppVisibilityChanged | event on | on | `app-visibility-change` | main → renderer push (1 send-sites found) | 2 |
| removeListenAppVisibilityChanged | event off (removeAll) | removeAllListeners | `app-visibility-change` | local only | 2 |
| getAppVisibilityStatus | async | invoke | `get-app-visibility` | `getAppVisibilityStatus:e=>{const{appVisibility:t}=n("XDOQ");return t.getAppVisibilityState()}` | 1 |

### `$zdownload`

| member | kind | ipc | channel | main side | uses |
|---|---|---|---|---|---|
| sendDownloadRequest | async | invoke | `new-download-channel` | download manager (GYN9) → implement only if downloads needed | 20 |
| onDownloadResp | event on | on | `new-download-channel` | main → renderer push (3 send-sites found) | 4 |
| removeListenDownloadResp | event off (removeAll) | removeAllListeners | `new-download-channel` | local only | 0 |
| updateDownloadConfig | async | invoke | `download-config-change` | `updateDownloadConfig:(e,t)=>{const{downloadModuleConf:r}=n("rw62");r&&r.setDownloadConf(t)}` | 4 |
| updateInvalidFileExts | async | invoke | `invalid-file-exts-change` | `updateInvalidFileExts:(e,t)=>{}` | 4 |
| downloadThumbTemp | async | invoke | `download-thumb-temp` | `downloadThumbTemp:async(e,t,n)=>{try{return[null,await new ce(t,n).download()]}catch(r){return[r,null]}}` | 1 |
| onDownloadQuotaHit | event on | on | `download-quota-hit` | main → renderer push (1 send-sites found) | 4 |
| removeListenDownloadQuotaHit | event off (removeAll) | removeAllListeners | `download-quota-hit` | local only | 0 |

### `$zdb`

| member | kind | ipc | channel | main side | uses |
|---|---|---|---|---|---|
| sendRequest | async | invoke | `shared-worker-req-events` | Htpd.channelReqListener → forwards SQLite request to hidden "dbTask" window (shared-worker.html) | 4 |
| processRequest | event on | on | `shared-worker-req-events` | push (no direct send-site found; may be sent by helper/never) | 1 |
| removeListenNewRequest | event off (removeAll) | removeAllListeners | `shared-worker-req-events` | local only | 0 |
| sendResponse | async | invoke | `shared-worker-resp-events` | forward SQLite response back to main window | 2 |
| processResponse | event on | on | `shared-worker-resp-events` | main → renderer push (1 send-sites found) | 4 |
| removeListenNewResponse | event off (removeAll) | removeAllListeners | `shared-worker-resp-events` | local only | 0 |
| onFailedLoadSqlite | event on | on | `fail-load-sqlite3` | main → renderer push (1 send-sites found) | 4 |
| checkFailedLoadSqlite | async | invoke | `fail-load-sqlite3` | `!getSqlite3LoadState()` → **return true** (=sqlite failed ⇒ renderer uses web-worker search) | 4 |
| updateAvailableSqliteState | async (fire&forget, still invoke) | invoke | `status-load-sqlite3` | if false: mark sqlite failed and push `fail-load-sqlite3` to main window | 2 |
| notifyOpenDBFailed | async (fire&forget, still invoke) | invoke | `db-open-fail` | `notifyOpenDBFailed:(e,t,r)=>{const{onOpenDbFail:i}=n("j6F3");i(t,r)}` | 10 |
| authenticateDb | async (fire&forget, still invoke) | invoke | `db-authenticated` | MainDatabaseManager.onRendererAuthenticated(session) → store & **broadcast `db-authenticated`(session)** to all DB clients | 1 |
| onReceiveSession | event on | on | `db-authenticated` | main → renderer push (2 send-sites found) | 5 |
| removeListenNewSession | event off (removeAll) | removeAllListeners | `db-authenticated` | local only | 4 |
| notifyDbConnected | async (fire&forget, still invoke) | invoke | `db-client-connected` | register client (bundleName); **if a session is known, immediately `send("db-authenticated",session)`**; if closing, forward `db-start-close-dbs` | 6 |
| requestCloseDbs | async (fire&forget, still invoke) | invoke | `db-start-close-dbs` | `requestCloseDbs(dbNames,bundleName,opts)` → broadcast `db-start-close-dbs`(dbNames,bundleName,opts) to clients; **resolves only when every client called notifyFinishCloseDb** | 1 |
| onRequestCloseDbs | event on | on | `db-start-close-dbs` | main → renderer push (2 send-sites found) | 6 |
| removeListenRequestCloseDbs | event off (removeAll) | removeAllListeners | `db-start-close-dbs` | local only | 4 |
| notifyFinishCloseDb | async (fire&forget, still invoke) | invoke | `db-finish-close-dbs` | marks client closed; resolves pending requestCloseDbs when all done | 6 |
| abortSyncMsg | async (fire&forget, still invoke) | invoke | `sync-msg-abort` | `abortSyncMsg:(e,t)=>{n("Htpd").receiveRequestAbortSync(t)}` | 1 |
| getIDBDatabaseHealthStatus | async | invoke | `z-db-corruption-detector` | compares LevelDB snapshot of Partitions/zalo/IndexedDB → 0 OK / 1 RESET_COUNTER / 2 INVALID_COUNTER → **return 0** | 1 |
| canIUseSQLite | async | invoke | `sqlite-available` | `!!nativelibs.sqlite3()` → **return false** | 3 |
| showSQLite | async (fire&forget, still invoke) | invoke | `show-sqlite` | `showSQLite:()=>n("zeLT").show()` | 0 |
| getNameOfTargetScriptForDALChannelFromHost | async | invoke | `get-name-of-target-script-for-dal-channel-from-host` | `migrateFullyDone ? "utility-process-sqlite" : "preload-sqlite"` | 5 |

### `$zsessionManager`

| member | kind | ipc | channel | main side | uses |
|---|---|---|---|---|---|
| authenticate | async (fire&forget, still invoke) | invoke | `new-session` | SessionManager(main).setSession(session) (dispatch event if userId/UIN changed) | 1 |
| onReceiveSession | event on | on | `new-session` | push (no direct send-site found; may be sent by helper/never) | 5 |
| removeListenReceiveSession | event off (removeAll) | removeAllListeners | `new-session` | local only | 4 |

### `$zmulti`

| member | kind | ipc | channel | main side | uses |
|---|---|---|---|---|---|
| onChildWindowClose | event on | on | `CHILD_WINDOW_CLOSED` | push (no direct send-site found; may be sent by helper/never) | 4 |
| removeListenChildWindowClose | event off (removeAll) | removeAllListeners | `CHILD_WINDOW_CLOSED` | local only | 0 |
| closeAllChilds | async | invoke | `close-all-childs` | `closeAllChilds:e=>{n("3dTn").closeAllChild()}` | 4 |

### `$zcall`

| member | kind | ipc | channel | main side | uses |
|---|---|---|---|---|---|
| onRequestCallFromServer | event on | on | `call-server-request` | push (no direct send-site found; may be sent by helper/never) | 0 |
| removeListenRequestCallFromServer | event off (removeAll) | removeAllListeners | `call-server-request` | local only | 0 |
| onRequestCallFromLocal | event on | on | `call-local-request` | push (no direct send-site found; may be sent by helper/never) | 0 |
| removeListenRequestCallFromLocal | event off (removeAll) | removeAllListeners | `call-local-request` | local only | 0 |
| onCallUpdate | event on | on | `call-update` | main → renderer push (4 send-sites found) | 4 |
| removeListenCallUpdate | event off (removeAll) | removeAllListeners | `call-update` | local only | 0 |
| onCallActiveNative | event on | on | `call_active_native_app` | push (no direct send-site found; may be sent by helper/never) | 0 |
| removeListenCallActiveNative | event off (removeAll) | removeAllListeners | `call_active_native_app` | local only | 0 |
| onPcShuttingDown | event on | on | `pc-shutting-down` | push (no direct send-site found; may be sent by helper/never) | 0 |
| removeListenPcShuttingDown | event off (removeAll) | removeAllListeners | `pc-shutting-down` | local only | 0 |
| onStopSharing | event on | on | `stop-sharing` | push (no direct send-site found; may be sent by helper/never) | 0 |
| removeListenStopSharing | event off (removeAll) | removeAllListeners | `stop-sharing` | local only | 0 |
| onCallSignal | event on | on | `call-send-signal` | main → renderer push (1 send-sites found) | 4 |
| removeListenCallSignal | event off (removeAll) | removeAllListeners | `call-send-signal` | local only | 0 |
| onCallRequest | event on | on | `call-request` | main → renderer push (1 send-sites found) | 4 |
| removeListenCallRequest | event off (removeAll) | removeAllListeners | `call-request` | local only | 0 |
| initCall | send (no reply) | send | `call-init` | (call module) – no-op | 4 |
| sendDataToNative | send (no reply) | send | `call-send-to-native` | (call module) – no-op | 4 |
| onCallResponseDevices | event once | once | `call-response-listDevice` | push (no direct send-site found; may be sent by helper/never) | 4 |
| removeListenCallDevices | event off (removeAll) | removeAllListeners | `call-response-listDevice` | local only | 4 |

### `$zsharedWorker`

| member | kind | ipc | channel | main side | uses |
|---|---|---|---|---|---|
| show | async (fire&forget, still invoke) | invoke | `show-shared-worker` | `show:e=>{const{sharedWorkerManager:t}=n("poPE");t.onRequestShow()}` | 2 |
| hide | async (fire&forget, still invoke) | invoke | `hide-shared-worker` | `hide:e=>{const{sharedWorkerManager:t}=n("poPE");t.onRequestHide()}` | 0 |
| start | async (fire&forget, still invoke) | invoke | `shared-worker-start` | `start:e=>{const{sharedWorkerManager:t}=n("poPE");t.onStartup(e)}` | 1 |
| register | async (fire&forget, still invoke) | invoke | `shared-worker-handle` | `register:(e,t)=>{const{sharedWorkerManager:r}=n("poPE");r.onRegisterHandle(e,t)}` | 1 |
| ping | async (fire&forget, still invoke) | invoke | `shared-worker-ping` | `ping:e=>{const{sharedWorkerManager:t}=n("poPE");t.onReceivePing()}` | 2 |
| dispose | async (fire&forget, still invoke) | invoke | `shared-worker-dispose` | `dispose:e=>{const{sharedWorkerManager:t}=n("poPE");t.onDispose()}` | 1 |
| updateProgress | async (fire&forget, still invoke) | invoke | `shared-worker-progress` | `updateProgress:(e,t)=>{const{sharedWorkerManager:r}=n("poPE");r.onUpdateProgress(t)}` | 1 |
| onReceiveUpdateProgress | event on | on | `shared-worker-progress` | push (no direct send-site found; may be sent by helper/never) | 1 |
| removeListenUpdateProgress | event off (removeAll) | removeAllListeners | `shared-worker-progress` | local only | 0 |
| responseResult | async (fire&forget, still invoke) | invoke | `shared-worker-resp` | `responseResult:(e,t)=>{const{sharedWorkerManager:r}=n("poPE");r.onReceiveResp(t)}` | 3 |
| onReceiveResult | event on | on | `shared-worker-resp` | push (no direct send-site found; may be sent by helper/never) | 1 |
| removeListenResult | event off (removeAll) | removeAllListeners | `shared-worker-resp` | local only | 0 |
| runTask | async (fire&forget, still invoke) | invoke | `shared-worker-run` | `runTask:(e,t)=>{const{sharedWorkerManager:r}=n("poPE");r.onRequestRunTask(e,t)}` | 1 |
| onRequestRunTask | event on | on | `shared-worker-run` | push (no direct send-site found; may be sent by helper/never) | 1 |
| removeListenRunTask | event off (removeAll) | removeAllListeners | `shared-worker-run` | local only | 0 |
| abortTask | async (fire&forget, still invoke) | invoke | `shared-worker-abort` | `abortTask:(e,t)=>{const{sharedWorkerManager:r}=n("poPE");r.onRequestAbortTask(e,t)}` | 2 |
| onRequestAbortTask | event on | on | `shared-worker-abort` | push (no direct send-site found; may be sent by helper/never) | 1 |
| removeListenAbortTask | event off (removeAll) | removeAllListeners | `shared-worker-abort` | local only | 0 |
| updateTaskParams | async (fire&forget, still invoke) | invoke | `shared-worker-update-params` | `updateTaskParams:(e,t)=>{const{sharedWorkerManager:r}=n("poPE");r.onUpdateTaskParams(e,t)}` | 1 |
| onRequestUpdateTaskParams | event on | on | `shared-worker-update-params` | push (no direct send-site found; may be sent by helper/never) | 1 |
| removeListenUpdateTaskParams | event off (removeAll) | removeAllListeners | `shared-worker-update-params` | local only | 0 |
| onUnloadZLog | event on | on | `unload-zlog` | push (no direct send-site found; may be sent by helper/never) | 1 |
| removeListenUnloadZLog | event off (removeAll) | removeAllListeners | `unload-zlog` | local only | 1 |
| updateRemoteConfig | async (fire&forget, still invoke) | invoke | `shared-worker-remote-config-change` | `updateRemoteConfig:(e,t)=>{const{sharedWorkerManager:r}=n("poPE");r.updateRemoteConfig(t.config)}` | 3 |
| onRemoteConfigChange | event on | on | `shared-worker-remote-config-change` | main → renderer push (2 send-sites found) | 1 |
| removeListenRemoteConfigChange | event off (removeAll) | removeAllListeners | `shared-worker-remote-config-change` | local only | 0 |

### `$zelectron`

| member | kind | ipc | channel | main side | uses |
|---|---|---|---|---|---|
| getAppPath | async | invoke | `_electron_get-app-path` | `getAppPath:e=>{const{app:t}=n("NLsH");return t.getAppPath()}` | 2 |
| getAppPathSync | **sync** | sendSync | `_electron_get-app-path-sync` | 4opB `e.returnValue=app.getAppPath()` | 2 |
| getPath | async | invoke | `_electron_get-path` | `getPath(name)`: `"db"`→IpzU.getDbPathRoot(), else `app.getPath(name)` | 6 |
| getPathSync | **sync** | sendSync | `_electron_get-path-sync` | 4opB `ipcMain.on(GET_PATH_SYNC,(e,t)=>{e.returnValue=app.getPath(t)})` | 10 |
| getAppVersion | async | invoke | `_electron_get-app-version` | `app.getVersion()` → "26.10.20" | 16 |
| setCookie | async | invoke | `_electron_set-cookie` | `(name,value,url,domain)` → cookies.set httpOnly secure exp now+365d; flush | 4 |
| setAppCookie | async | invoke | `_electron_set-app-cookie` | sets cookie `zpw_sek=<v>` httpOnly secure sameSite=None exp now+7d on zaloapp.com, zalo.me, chat.zalo.me; flushStore | 12 |
| clearCookie | async | invoke | `_electron_clear-cookie` | `session.clearStorageData({storages:["cookies"]})` | 8 |
| clearHostResolverCache | async | invoke | `_electron_clear-host-cache` | `clearHostResolverCache:e=>l.fromPartition("persist:zalo").clearHostResolverCache()` | 0 |
| clearSessionStorageData | async | invoke | `_electron_clear-session-storage` | `clearSessionStorageData:(e,t)=>l.fromPartition("persist:zalo").clearStorageData({storages:t})` | 0 |
| clearSessionCache | async | invoke | `_electron_clear-session-cache` | `clearSessionCache:e=>l.fromPartition("persist:zalo").clearCache()` | 0 |
| openDevTool | async | invoke | `_electron_open-devtool` | `openDevTool:e=>{var t;const{BrowserWindow:r}=n("NLsH");null===(t=r.getFocusedWindow())\|\|void 0===t\|\|t.webContents.openDevTools()}` | 12 |
| enableWinContextMenu | async | invoke | `_electron_enable-win-context-menu` | `enableWinContextMenu:e=>{const{BrowserWindow:t}=n("NLsH");t.getFocusedWindow()}` | 4 |
| takeHeapSnapshotAndZip | async | invoke | `_electron_take-heap-snapshot-and-zip` | `takeHeapSnapshotAndZip:async e=>{try{const{takeHeapSnapshotAndZip:e}=n("IpTV");return await e()}catch(t){return log(),[]}}` | 4 |
| getInfoScreenOfMouseSync | **sync** | sendSync | `_electron_get-info-screen-of-mouse-sync` | 4opB `e.returnValue=focusedWindowId||MAIN_WINDOW_ID` | 1 |

### `$zuri`

| member | kind | ipc | channel | main side | uses |
|---|---|---|---|---|---|
| onNewRequest | event on | on | `z-uri-request` | main → renderer push (5 send-sites found) | 1 |
| removeListenNewRequest | event off (removeAll) | removeAllListeners | `z-uri-request` | local only | 1 |
| onRequestOpenConv | event on | on | `z-uri-open-conv` | main → renderer push (3 send-sites found) | 1 |
| removeListenRequestOpenConv | event off (removeAll) | removeAllListeners | `z-uri-open-conv` | local only | 1 |
| checkOpenConvReq | async | invoke | `check-startup-open-conv-request` | `checkOpenConvReq:e=>{const{checkStartupOpenConvReq:t}=n("j6F3");t()}` | 4 |
| checkArgvLink | send (no reply) | send | `check-arg-link` | j6F3: if launched with `zalo://<apiDomain>…` argv, `send("z-uri-request",link)`. No-op | 4 |

### `$zscreencap`

| member | kind | ipc | channel | main side | uses |
|---|---|---|---|---|---|
| start | async | invoke | `screen-capture` | `start:(e,t,n)=>{xe.startScreenshot(t,n),e.sender.send(Pe.START_SCREEN_CAPTURE,{params:t,convId:n})}` | 8 |
| getClipboard | async | invoke | `get-clipboard` | `getClipboard:async(e,t)=>{try{const e=await xe.startGetClipboard(t);if(e&&e.content){const t=e.content.split("\|");for(const e of t)if(e)try{R.a.statSync(e),Object(c.setT…` | 28 |
| restart | async | invoke | `restart-cap` | `restart:(e,t)=>{"darwin"===process.platform?log():xe.restartCap(t)}` | 0 |
| rewriteClipboard | async | invoke | `rewrite-clipboard` | `rewriteClipboard:(e,t)=>xe.startRewriteClipboard(t)` | 4 |
| onChangeStatus | event on | on | `change-screencap-status` | main → renderer push (1 send-sites found) | 5 |
| removeListenChangeStatus | event off (removeAll) | removeAllListeners | `change-screencap-status` | local only | 5 |
| onScreenshotShortcut | event on | on | `screenshot-shortcut-result` | main → renderer push (1 send-sites found) | 4 |
| removeScreenshotShortcut | event off (removeAll) | removeAllListeners | `screenshot-shortcut-result` | local only | 4 |
| onStartScreenCapture | event on | on | `start-screen-capture` | main → renderer push (1 send-sites found) | 4 |
| removeListenStartScreenCapture | event off (removeAll) | removeAllListeners | `start-screen-capture` | local only | 0 |
| onScreenCapture | event on | on | `screen-capture-shortcut` | main → renderer push (1 send-sites found) | 4 |
| removeListenScreenCapture | event off (removeAll) | removeAllListeners | `screen-capture-shortcut` | local only | 4 |
| onCaptureAccept | event on | on | `screen-capture-response-accept` | push (no direct send-site found; may be sent by helper/never) | 4 |
| removeListenCaptureAccept | event off (removeAll) | removeAllListeners | `screen-capture-response-accept` | local only | 4 |
| onCaptureNoPermission | event on | on | `screen-capture-response-no-permission` | main → renderer push (1 send-sites found) | 4 |
| removeListenCaptureNoPermission | event off (removeAll) | removeAllListeners | `screen-capture-response-no-permission` | local only | 4 |
| onEventOs | event on | on | `event-os-changed` | main → renderer push (5 send-sites found) | 4 |
| removeListenEventOs | event off (removeAll) | removeAllListeners | `event-os-changed` | local only | 0 |
| onSend2Me | event on | on | `screen-capture-response-send2me` | push (no direct send-site found; may be sent by helper/never) | 4 |
| removeListenSend2Me | event off (removeAll) | removeAllListeners | `screen-capture-response-send2me` | local only | 4 |
| onForwardScreencap | event on | on | `forward_screencap` | main → renderer push (1 send-sites found) | 4 |
| removeListenForwardScreencap | event off (removeAll) | removeAllListeners | `forward_screencap` | local only | 4 |
| onForwardScreencapText | event on | on | `forward_screencap_text` | main → renderer push (1 send-sites found) | 4 |
| removeListenForwardScreencapText | event off (removeAll) | removeAllListeners | `forward_screencap_text` | local only | 4 |
| onWarningInstallRosetta | event on | on | `warning_install_rosetta` | main → renderer push (2 send-sites found) | 4 |
| removeListenWarningInstallRosetta | event off (removeAll) | removeAllListeners | `warning_install_rosetta` | local only | 0 |

### `$zlogin`

| member | kind | ipc | channel | main side | uses |
|---|---|---|---|---|---|
| login | send (no reply) | send | `login` | j6F3 `.on("login",(e,t=-999)=>{…logQos 91062…; restart call svc; rt.onLogOut(); closeAllChild(); sn()})` → **logout: loads login.html** (sn) and on did-finish-load sends `signal_USER_NOT_LOGGED_IN` | 8 |
| updateLoginStep | send (no reply) | send | `login-step` | j6F3 `.on("login-step",(e,t)=>{Ue=t})` – remembers step for GA on quit. No-op OK | 0 |
| loginAfterInstall | send (no reply) | send | `login-after-install` | j6F3 `{Be=!0,He=t}` install-source bookkeeping. No-op | 0 |
| onUserNotLogged | event on | on | `signal_USER_NOT_LOGGED_IN` | main → renderer push (1 send-sites found) | 4 |
| removeListenUserNotLogged | event off (removeAll) | removeAllListeners | `signal_USER_NOT_LOGGED_IN` | local only | 0 |
| notifyLoginSuccess | async | invoke | `login-success` | `onLoginSuccess()` → loadURL(index.html?…&already_login=y&new_install_success=…&install_source=…); on did-finish-load `send("login-success")` | 1 |
| onLoginSuccess | event on | on | `login-success` | main → renderer push (1 send-sites found) | 4 |
| removeListenLoginSuccess | event off (removeAll) | removeAllListeners | `login-success` | local only | 0 |
| onRequestShowAbout | event on | on | `about` | main → renderer push (2 send-sites found) | 1 |
| removeListenShowAbout | event off (removeAll) | removeAllListeners | `about` | local only | 0 |

### `$zperf`

| member | kind | ipc | channel | main side | uses |
|---|---|---|---|---|---|
| getCpuInfos | async | invoke | `get-cpu-infos` | `getCpuInfos:e=>{const t=n("NLsH"),r=n("T7kW");return t.app.getAppMetrics().map((e=>{const t=r.getName(e.pid)\|\|"";return{cpu:{percentCPUUsage:e.cpu.percentCPUUsage},pid:…` | 10 |
| getProcessInfos | async | invoke | `get-process-info` | `getProcessInfos:e=>n("T7kW")._reverse` | 4 |
| crash | async | invoke | `z-simulate-crash-main` | `crash:(e,t=1)=>{switch(t){case 1:process.crash();break;case 2:({}).undefinedFunc()}}` | 8 |

### `$zconfig`

| member | kind | ipc | channel | main side | uses |
|---|---|---|---|---|---|
| checkAutoLaunchEnable | async | invoke | `check-auto-launch` | auto-launch status → false | 4 |
| toggleAutoLaunch | async | invoke | `toggle-auto-launch` | `toggleAutoLaunch:(e,t)=>{const{appConfig:r}=n("ZQzv"),{getZaloLauncher:i}=n("Wsuc"),o=i();t?($log(),o.enable(),r.set("autolaunch",!0)):($log(),o.disable(),r.set("autolaun…` | 4 |
| updateScreenshotShortcut | async | invoke | `update-screenshot-shortcut` | `updateScreenshotShortcut:(e,t,r)=>{const{registerScreenshotShortcut:i,idxShortcut:o}=n("j6F3");i(t,r?o.shortcut_screenshot:o.shortcut_screenshot_withoutZ,r,!1)}` | 8 |
| updateThemeConfig | async | invoke | `update-theme-conf` | store theme + set bg color | 4 |
| updateRemoteConfigs | async (fire&forget, still invoke) | invoke | `update-remote-configs` | `updateRemoteConfigs:(e,t)=>{Object(We.a)(null==t?void 0:t.config)}` | 1 |
| getThemeConfig | async | invoke | `get-theme-conf` | appConfig "app_theme" | 5 |
| getZaloInstalledTime | async | invoke | `get-zalo-installed-time` | appConfig "zalo_installed" (ms) | 0 |

### `$zFileManager`

| member | kind | ipc | channel | main side | uses |
|---|---|---|---|---|---|
| isTrustPath | async | invoke | `is_trust_path` | `isTrustPath(path.resolve(p))` — whitelist of dirs/dialog-picked paths → return true for app-owned dirs | 0 |
| trustPathFromBlob | async | invoke | `trust_path_from_blob` | `trustPathFromBlob:function(e,t){Object(o.setTrustPath)(t)}` | 0 |
| requestFlushZLog | async (fire&forget, still invoke) | invoke | `request_flush_zlog` | `requestFlushZLog:function(e){c.a.requestFlushZLog()}` | 1 |
| setReadonlyFile | async | invoke | `set_readonly_file` | `setReadonlyFile:async function(e,t){await f(t)}` | 4 |
| verifyZaloPCHardlinkSupport | async | invoke | `verify_zalo_pc_hardlink_support` | `verifyZaloPCHardlinkSupport:function(){const{checkZaloPCDirHardlinkSupport:e}=n("kPHX");return e()}` | 4 |

### `$zFeatures.zaloCall`

| member | kind | ipc | channel | main side | uses |
|---|---|---|---|---|---|
| requestCompressedLogFile | async | invoke | `request-compressed-log-file` | `requestCompressedLogFile:()=>On()` | 8 |

### `$zFeatures.kikiAssistant`

| member | kind | ipc | channel | main side | uses |
|---|---|---|---|---|---|
| openOAuthWindow | async | invoke | `kiki-open-oauth-window` | `openOAuthWindow:async(e,t)=>{const n=await(async(e,t)=>ai.openOAuthWindow(e,t))(t,e);return n}` | 4 |
| onOAuthCompleted | event on | on | `kiki-oauth-completed` | main → renderer push (1 send-sites found) | 4 |
| removeListenerOAuthCompleted | event off (removeAll) | removeAllListeners | `kiki-remove-oauth-completed` | local only | 12 |
| onOAuthFailed | event on | on | `kiki-oauth-failed` | main → renderer push (1 send-sites found) | 4 |
| removeListenerOAuthFailed | event off (removeAll) | removeAllListeners | `kiki-remove-oauth-failed` | local only | 4 |
| startCSPMonitor | async | invoke | `kiki-start-csp-monitor` | `startCSPMonitor:async e=>{var t;t=e.sender,ai.setupCSPMonitor(t)}` | 4 |
| stopCSPMonitor | async | invoke | `kiki-stop-csp-monitor` | `stopCSPMonitor:async e=>{ai.stopCSPMonitor()}` | 16 |
| onCSPBlocked | event on | on | `kiki-csp-blocked` | main → renderer push (1 send-sites found) | 4 |
| removeListenerCSPBlocked | event off (removeAll) | removeAllListeners | `kiki-remove-csp-blocked` | local only | 4 |

### `$zFeatures.mainless`

| member | kind | ipc | channel | main side | uses |
|---|---|---|---|---|---|
| cancel | async | invoke | `cancel` | `async cancel(e,t){const n=Ln.get(t);n&&await(null==n?void 0:n.cancel())}` | 1 |
| execRaw | async | invoke | `exec_raw` | same as exec (raw result) | 1 |
| exec | async | invoke | `exec` | mainless worker_threads pool: run node method (zip/unzip/md5/getDirSize/parseLink/parseBank/…) → result or `{error}`; progress via `remote_events` | 0 |
| onRemoteEvents | event on | on | `remote_events` | main → renderer push (2 send-sites found) | 1 |

### `$zFeatures.activeDeactive`

| member | kind | ipc | channel | main side | uses |
|---|---|---|---|---|---|
| getIdleTime | async | invoke | `active-deactive:get-idle-time` | `getIdleTime:function(e){return Object(xn.getIdleTime)()}` | 1 |
| setup | async (fire&forget, still invoke) | invoke | `active-deactive:setup` | `setup:function(e,t){Object(xn.changeConfig)(e,t)}` | 1 |
| createTimer | async (fire&forget, still invoke) | invoke | `active-deactive:create-timer` | `createTimer:function(e,t){Object(xn.createTimer)(e,t)}` | 1 |
| clearTimer | async (fire&forget, still invoke) | invoke | `active-deactive:clear-timer` | `clearTimer:function(e,t){Object(xn.clearTimer)(e,t)}` | 2 |
| onActiveFromBackground | event on | on | `active-deactive:active` | main → renderer push (1 send-sites found) | 1 |
| onDeactiveFromBackground | event on | on | `active-deactive:deactive` | main → renderer push (1 send-sites found) | 1 |
| offActiveFromBackground | event off (removeAll) | removeAllListeners | `active-deactive:active` | local only | 1 |
| offDeactiveFromBackground | event off (removeAll) | removeAllListeners | `active-deactive:deactive` | local only | 1 |

### `$zFeatures.migrateDB`

| member | kind | ipc | channel | main side | uses |
|---|---|---|---|---|---|
| signalDoneFullMigrate | async (fire&forget, still invoke) | invoke | `migratedb:signal_done` | `signalDoneFullMigrate:function(e){me.default.onDoneMigrateFull()}` | 2 |
| checkNeedWaitBackup | async | invoke | `migratedb:check_need_wait_bu` | `!canMigrateWithCurrBUStatus(n)` → return false | 1 |
| signalRestartAppToMigrate | async (fire&forget, still invoke) | invoke | `migratedb:signal_restart` | relaunch app with `--restart-app-to-migrate`-style arg (RESTART_APP_ARGS) → **no-op** | 3 |
| getMigrateLocalInfo | async | invoke | `get-migrate-local-info` | `(version,key)` → stored `{…}` from appConfig or default R; return `{disable_migrate:true}` to suppress IDB→SQLite migration | 1 |
| updateMigrateLocalInfo | async | invoke | `update-migrate-local-info` | `updateMigrateLocalInfo:function(e,t,n,r){return me.default.updateMigrateLocalConfig(t,n,r)}` | 1 |
| devOnly_resetMigrateState | async (fire&forget, still invoke) | invoke | `dev-only-reset-migrate-state` | `devOnly_resetMigrateState:function(e){return me.default.devOnly_resetMigrateState()}` | 0 |
| isMigrateFullDone | async | invoke | `is-migrate-full-done` | `FKO5.migrateFullyDone` (bool) → **return false** | 18 |

### `$zFeatures.transfer`

| member | kind | ipc | channel | main side | uses |
|---|---|---|---|---|---|
| notifyReceiveMediaMsgs | async (fire&forget, still invoke) | invoke | `noti-receive-media-msg` | `notifyReceiveMediaMsgs:(e,t)=>{const{sendMediaMsgsToRenderer:r}=n("j6F3");r(t)}` | 3 |

### `$zFeatures.syncDownload`

| member | kind | ipc | channel | main side | uses |
|---|---|---|---|---|---|
| onRequestTriggerAutoDownload | event on | on | `trigger-auto-download` | main → renderer push (1 send-sites found) | 8 |
| removeListenTriggerAutoDownload | event off (removeAll) | removeAllListeners | `trigger-auto-download` | local only | 4 |

### `$zFeatures.genThumb`

| member | kind | ipc | channel | main side | uses |
|---|---|---|---|---|---|
| writeSavePathFilePhoto | async | invoke | `gen-thumb_write-savepath-file-photo` | `writeSavePathFilePhoto:(e,t,n,r,i)=>((e,t,n,r)=>new Promise(((i,o)=>{const a=Object(Ur.a)(r,{userId:e,fallbackName:t}),s=J.a.join(Object(T.getZaloDownloadsFileThumbDirSyn…` | 4 |

### `$zFeatures.zwalker`

| member | kind | ipc | channel | main side | uses |
|---|---|---|---|---|---|
| collectDirectoryStats | async | invoke | `zwalker-collect-dir-stats` | `collectDirectoryStats:async(e,t,r=[])=>{const i=n("oyvS"),o=n("EXGp"),a=i.resolve(t),s=await o.zwalker();try{var c,l;const e=await s.scanDirectory(a,r);return{fileNumber:…` | 1 |
| updateFileStats | async | invoke | `zwalker-update-file-stats` | `updateFileStats:async(e,t,r)=>{const i=n("oyvS"),o=n("EXGp"),a=i.resolve(t),s=await o.zwalker();try{var c;const e=await s.updateReferenceMessageId(a,r);return{updateCount…` | 1 |
| deleteUnmarkedFiles | async | invoke | `zwalker-del-unmarked-files` | `deleteUnmarkedFiles:async(e,t,r,i=[],o=!0)=>{const a=n("oyvS"),s=n("EXGp"),c=a.resolve(t),l=await s.zwalker();try{var d,u,p,h;const e=await l.deleteHomelessFiles(c,r,i,o)…` | 1 |
| statUnmarkedFiles | async | invoke | `zwalker-stat-unmarked-files` | `statUnmarkedFiles:async(e,t,r,i=[],o=[])=>{const a=n("oyvS"),s=n("EXGp"),c=a.resolve(t),l=await s.zwalker();try{var d,u;const e=await l.statUnmarkedFiles(c,r,i,o);return{…` | 1 |
| deleteEmptyFolders | async | invoke | `zwalker-delete-empty-folders` | `deleteEmptyFolders:async(e,t)=>{const r=n("oyvS"),i=n("EXGp"),o=r.resolve(t),a=await i.zwalker();try{var s;return null!==(s=await a.deleteEmptyFolders(o))&&void 0!==s?s:{…` | 1 |

### `$zFeatures.fileWalkerStream`

| member | kind | ipc | channel | main side | uses |
|---|---|---|---|---|---|
| startStream | async | invoke | `file-walker-stream-start` | `startStream:async(e,t)=>{const n='${Date.now()}-${Math.random().toString(36).slice(2,8)}';return log(),Qr.set(n,{id:n,senderId:e.sender.id,canceled:!1}),async function(e,…` | 0 |
| ackStreamChunk | send (no reply) | send | `file-walker-stream-ack` | FEqq `Object(zr.b)(jr.ACK,…)` ipcMain.on → stream back-pressure ack | 0 |
| cancelStream | async | invoke | `file-walker-stream-cancel` | `cancelStream:async(e,t)=>{const n=Qr.get(t.streamId);if(n){var r;if(n.canceled=!0,null!==(r=n.stream)&&void 0!==r&&r.destroy)try{n.stream.destroy()}catch(i){log()}n.strea…` | 0 |
| buildInodeIndex | async | invoke | `file-walker-stream-build-index` | `buildInodeIndex:async(e,t)=>qr(t,Zr)` | 0 |
| onStreamChunk | event on | on | `file-walker-stream-chunk` | main → renderer push (1 send-sites found) | 0 |
| removeStreamChunk | event off (removeAll) | removeAllListeners | `file-walker-stream-chunk` | local only | 0 |
| onStreamEnd | event on | on | `file-walker-stream-end` | main → renderer push (1 send-sites found) | 0 |
| removeStreamEnd | event off (removeAll) | removeAllListeners | `file-walker-stream-end` | local only | 0 |
| onStreamError | event on | on | `file-walker-stream-error` | main → renderer push (3 send-sites found) | 0 |
| removeStreamError | event off (removeAll) | removeAllListeners | `file-walker-stream-error` | local only | 0 |

### `$zFeatures.ocr`

| member | kind | ipc | channel | main side | uses |
|---|---|---|---|---|---|
| recognize | async | invoke | `ocr_recognize` | `recognize:async(e,t,n)=>{try{return{success:!0,result:await Object(di.recognize)(t,n)}}catch(r){return{success:!1,error:{message:r instanceof Error?r.message:String(r),co…` | 4 |
| isSupported | async | invoke | `ocr_is-supported` | `isSupported:e=>Object(di.isOcrAvailable)()` | 4 |
| prewarm | async | invoke | `ocr_prewarm` | `prewarm:e=>Object(di.prewarmOcrEngine)()` | 4 |

### `$zFeatures.languageDetector`

| member | kind | ipc | channel | main side | uses |
|---|---|---|---|---|---|
| detect | async | invoke | `language-detector_detect` | `detect:async(e,t)=>{try{return{success:!0,result:await Di({text:t.text,options:t.options})}}catch(n){return{success:!1,error:Ni(n)}}}` | 1 |
| dominantLanguage | async | invoke | `language-detector_dominant-language` | `dominantLanguage:async(e,t)=>{try{return{success:!0,result:await Ci(t)}}catch(n){return{success:!1,error:Ni(n)}}}` | 1 |
| isSupported | async | invoke | `language-detector_is-supported` | `isSupported:e=>function(){const e=bi();return e?e.availability():{supported:!1,reason:"native-binding-missing"}}()` | 1 |
| info | async | invoke | `language-detector_info` | `info:e=>function(){const e=bi();return e?e.info():{backend:"none",scoreKind:"none",version:null,platform:'${process.platform}-${process.arch}',loadError:Ri?Ri.message:"th…` | 1 |

### `$zMetric`

| member | kind | ipc | channel | main side | uses |
|---|---|---|---|---|---|
| sendMessage | async (fire&forget, still invoke) | invoke | `send-metrics` | Metricz transport → no-op | 3 |
| onMessage | event on | on | `response-metrics` | main → renderer push (1 send-sites found) | 3 |

### `$zcloud`

| member | kind | ipc | channel | main side | uses |
|---|---|---|---|---|---|
| getHeap | async | invoke | `gett-heap` | `getHeap:(e,t)=>n("vLI4").memoryUsage().heapUsed\|\|0` | 0 |
| writeHeap | async (fire&forget, still invoke) | invoke | `write-heap` | `writeHeap:e=>{n("Cqa+").writeHeapSnapshot()}` | 0 |
| denoiseFile | async | invoke | `denoise-file` | `denoiseFile:(e,t)=>{if(!t)return;let{src:n,dest:r,checksum:i}=t;return async function(e,t,n){if(!mt("denoiseFile",e,t))throw new Error("denoiseFile: untrusted path");let …` | 8 |
| noiseFile | async | invoke | `noise-file` | `noiseFile:(e,t)=>{if(!t)return{savePath:""};let{src:n,userId:r,checksum:i,isGroup:o}=t;return async function(e,t,n,r=!1){return new Promise(((i,o)=>{if(!t)return o(Error(…` | 0 |
| removeFile | async | invoke | `remove-file` | `removeFile:(e,t)=>It(t)` | 12 |
| writeBufferToFile | async | invoke | `write-blob-to-file` | `writeBufferToFile:(e,t)=>async function(e,t){if(!Pt("writeBufferToFile",t))throw new Error("Untrusted file path");await Lt.promises.writeFile(t,e)}(t.buffer,t.outputPath)` | 8 |
| matchChecksum | async | invoke | `match-checksum` | `matchChecksum:(e,t)=>{let{checksum:n,filePath:r}=t;return async function(e,t){return Mt(t,e)}(n,r)}` | 4 |
| cloneAndMatchChecksum | async | invoke | `clone-and-match-checksum` | `cloneAndMatchChecksum:(e,t)=>{let{checksum:n,filePath:r}=t;return Ht(n,r)}` | 4 |
| AppendLog | async | invoke | `append-file` | `AppendLog:(e,t)=>Wt(t.data,t.uid)` | 0 |

### `$zMsgChannel`

| member | kind | ipc | channel | main side | uses |
|---|---|---|---|---|---|
| onChannelEstablished | event on | on | `channel-established` | push (no direct send-site found; may be sent by helper/never) | 5 |
| removeListenChannelEstablished | event off (removeAll) | removeAllListeners | `channel-established` | local only | 5 |
| onChannelDisconnected | event on | on | `channel-disconnected` | push (no direct send-site found; may be sent by helper/never) | 5 |
| removeListenChannelDisconnected | event off (removeAll) | removeAllListeners | `channel-disconnected` | local only | 5 |
| onChannelTerminated | event on | on | `channel-terminated` | push (no direct send-site found; may be sent by helper/never) | 1 |
| removeListenChannelTerminated | event off (removeAll) | removeAllListeners | `channel-terminated` | local only | 1 |
| onReceiveTransferredPort | event on | on | `port-transferred` | push (no direct send-site found; may be sent by helper/never) | 0 |
| removeListenReceiveTransferredPort | event off (removeAll) | removeAllListeners | `port-transferred` | local only | 0 |
| onReceiveTransferredPortV2 | event on + MessagePort | on+postMessage | `port-transferred-v2` | push (no direct send-site found; may be sent by helper/never) | 5 |
| removeListenReceiveTransferredPortV2 | event off (removeAll) | removeAllListeners | `port-transferred-v2` | local only | 5 |
| notifyPortDelivered | async (fire&forget, still invoke) | invoke | `port-delivered` | `notifyPortDelivered:function(e,t,n,r,i){U.ModuleContainer.resolve(cn.b).onPortDelivered(t,n,r,i)}` | 5 |
| requestOpenChannelTo | async (fire&forget, still invoke) | invoke | `open-channel-to` | MsgChannel broker: create MessageChannelMain between scripts, deliver ports with `port-transferred(-v2)` | 5 |

### `$zscript`

| member | kind | ipc | channel | main side | uses |
|---|---|---|---|---|---|
| notifyScriptConnected | async (fire&forget, still invoke) | invoke | `script-connected` | register script unit (bundle,processId) for MessagePort brokering | 5 |
| notifyScriptTerminated | async (fire&forget, still invoke) | invoke | `script-terminated` | `notifyScriptTerminated:function(e,t){const n=U.ModuleContainer.resolve(Zt.b),r=n.getScriptUnitIfExists(t);r&&n.onScriptTerminated(r)}` | 4 |

### `$zbackup`

| member | kind | ipc | channel | main side | uses |
|---|---|---|---|---|---|
| createBackup | async | invoke | `create-backup` | `createBackup:function(e,t,n){return zn.default.getInstance().createBackup(t,n)}` | 1 |
| destroyBackup | async | invoke | `destroy-backup` | `destroyBackup:function(e,t){return zn.default.getInstance().destroyBackup(t)}` | 1 |
| abortCreatingBackup | async | invoke | `abort-creating-backup` | `abortCreatingBackup:function(e,t,n,r){return zn.default.getInstance().abortCreatingBackup(t,n,r)}` | 1 |
| enableCreatingBackup | async (fire&forget, still invoke) | invoke | `enable-creating-backup` | `enableCreatingBackup:function(e,t){zn.default.getInstance().enableCreatingBackup(t)}` | 1 |
| disableCreatingBackup | async (fire&forget, still invoke) | invoke | `disable-creating-backup` | `disableCreatingBackup:function(e,t){zn.default.getInstance().disableCreatingBackup(t)}` | 1 |
| restartAndRestoreBackup | async | invoke | `restart-and-restore-backup` | `restartAndRestoreBackup:function(e,t){zn.default.getInstance().restartAndRestoreBackup(t)}` | 2 |
| restartWithoutRestoringBackup | async | invoke | `restart-without-restoring-backup` | `restartWithoutRestoringBackup:function(e){zn.default.getInstance().restartWithoutRestoringBackup()}` | 2 |
| rejectCurrentBackup | async (fire&forget, still invoke) | invoke | `reject-current-backup` | `rejectCurrentBackup:function(e,t){zn.default.getInstance().rejectCurrentBackup(t)}` | 2 |
| changeBuInterval | async (fire&forget, still invoke) | invoke | `change-bu-interval` | `changeBuInterval:function(e,t){zn.default.getInstance().changeIntervalBU(t)}` | 1 |
| onWriteLatestBackUpLog | event on | on | `write-latest-back-up-log` | push (no direct send-site found; may be sent by helper/never) | 1 |
| removeOnWriteLatestBackUpLog | event off (removeAll) | removeAllListeners | `write-latest-back-up-log` | local only | 0 |

### `$zInAppPayment`

| member | kind | ipc | channel | main side | uses |
|---|---|---|---|---|---|
| openUrl | async | invoke | `open-in-app-payment` | `openUrl:async(e,t,n)=>await En(t,n,e)` | 4 |
| closeInAppPayment | async | invoke | `close-in-app-payment` | `closeInAppPayment:async e=>{mn.inAppBrowser.close()}` | 1 |
| onInAppWindowEvent | event on | on | `event-in-app-payment` | main → renderer push (1 send-sites found) | 4 |
| removeListenerInAppWindowEvent | event off (removeAll) | removeAllListeners | `remove-event-in-app-payment` | local only | 4 |

### `$capp`

| member | kind | ipc | channel | main side | uses |
|---|---|---|---|---|---|
| launchCompactApp | async | invoke | `_electron_launch-compact-app` | `launchCompactApp:(e,t,r,i)=>{const{launchCompactApp:o}=n("Vsvh");o(t,r,i)}` | 4 |
| getRelaunchState | async | invoke | `_electron_get-relaunch-state` | `getRelaunchState:(e,t)=>{const{getRelaunchState:r}=n("Vsvh");return r(t)}` | 0 |

### `$zsqlitebw`

| member | kind | ipc | channel | main side | uses |
|---|---|---|---|---|---|
| ping | async (fire&forget, still invoke) | invoke | `SQLITE_BW/PING` | `ping:e=>{n("zeLT").onReceivePing()}` | 0 |
| dispose | async (fire&forget, still invoke) | invoke | `SQLITE_BW/DISPOSE` | `dispose:e=>{n("zeLT").onDispose()}` | 0 |
| reload | async | invoke | `SQLITE_BW/RELOAD` | `reload:async(e,t)=>{n("zeLT").reload(t)}` | 4 |

### `$zsafeStorage`

| member | kind | ipc | channel | main side | uses |
|---|---|---|---|---|---|
| execute | async | invoke | `zsafestorage-execute` | `execute(method,...args)` method∈{encryptString,decryptString,get,set}; store electron-store "zsafe-storage", key `zsskd.<key>`; cipher = AES-256-CBC (CryptoJS) key "d9c07b9de9915af401607d3f360211ac", fixed IV, base64 (unless `zsskv`=="1" → Electron safeStorage) | 4 |

### `$zMigrateDrive`

| member | kind | ipc | channel | main side | uses |
|---|---|---|---|---|---|
| getEstimatedCopyTime | async | invoke | `GET_ESTIMATED_COPY_TIME` | `getEstimatedCopyTime:async(e,t,n,r)=>r*(await hr(t,n)/1048576)/1e3` | 0 |
| writePathToRegistry | async | invoke | `None` | **apiKey undefined in preload (enum key missing) → invoke(undefined) throws** | 0 |
| getPathFromRegistry | async | invoke | `None` | **apiKey undefined in preload (enum key missing) → invoke(undefined) throws** | 0 |
| writeCurrentDrivePathToFile | async | invoke | `WRITE_CURRENT_DRIVE_PATH_TO_FILE` | `writeCurrentDrivePathToFile:async e=>Object(cr.b)()` | 4 |
| getCurrentDrivePathFromFile | async | invoke | `GET_CURRENT_DRIVE_PATH_FROM_FILE` | `getCurrentDrivePathFromFile:async e=>Object(cr.a)()` | 4 |

### `$zTFModels.ss`

| member | kind | ipc | channel | main side | uses |
|---|---|---|---|---|---|
| initSSResource | async (fire&forget, still invoke) | invoke | `tf-models:ss:resource:init` | `initSSResource:function(e,t){U.ModuleContainer.resolve($n.b).init(t)}` | 1 |
| getSticker2Score | async | invoke | `tf-models:ss:sticker-2-score:get` | `getSticker2Score:function(e){return U.ModuleContainer.resolve($n.b).sticker2Score.get()}` | 1 |
| setSticker2Score | async | invoke | `tf-models:ss:sticker-2-score:set` | `setSticker2Score:function(e,t){return U.ModuleContainer.resolve($n.b).sticker2Score.set(t)}` | 1 |
| getKwd2Sticker | async | invoke | `tf-models:ss:kwd-2-stickers:get` | `getKwd2Sticker:function(){return U.ModuleContainer.resolve($n.b).kwd2Stickers.get()}` | 1 |
| setKwd2Sticker | async | invoke | `tf-models:ss:kwd-2-stickers:set` | `setKwd2Sticker:function(e,t){return U.ModuleContainer.resolve($n.b).kwd2Stickers.set(t)}` | 1 |
| getSSConfig | async | invoke | `tf-models:ss:config:get` | `getSSConfig:function(){return U.ModuleContainer.resolve($n.b).config.get()}` | 1 |
| setSSConfig | async | invoke | `tf-models:ss:config:set` | `setSSConfig:function(e,t){return U.ModuleContainer.resolve($n.b).config.set(t)}` | 1 |
| getItem2Sticker | async | invoke | `tf-models:ss:item-2-sticker:get` | `getItem2Sticker:function(){return U.ModuleContainer.resolve($n.b).item2Sticker.get()}` | 1 |
| setItem2Sticker | async | invoke | `tf-models:ss:item-2-sticker:set` | `setItem2Sticker:function(e,t){return U.ModuleContainer.resolve($n.b).item2Sticker.set(t)}` | 1 |

### `$znetwork`

| member | kind | ipc | channel | main side | uses |
|---|---|---|---|---|---|
| startMonitor | async (fire&forget, still invoke) | invoke | `net-start-monitor` | `startMonitor:function(e,t,r){const{NetworkMonitor:i}=n("05Su");i.Instance().monitor(t,r)}` | 4 |
| stopMonitor | async (fire&forget, still invoke) | invoke | `net-stop-monitor` | `stopMonitor:function(e){const{NetworkMonitor:t}=n("05Su");t.Instance().stopMonitor()}` | 4 |
| onMonitorData | event on | on | `net-on-monitor-data` | main → renderer push (1 send-sites found) | 4 |
| removeListenOnMonitorData | event off (removeAll) | removeAllListeners | `net-on-monitor-data` | local only | 4 |
| updateNetErrorConfig | async (fire&forget, still invoke) | invoke | `net-update-net-error-config` | `updateNetErrorConfig:function(e,t){const{NetErrorMonitor:r}=n("IKDA");r.Instance().updateConfig(t)}` | 1 |
| collectNetErrorInfo | async (fire&forget, still invoke) | invoke | `net-collect-net-error-info` | `collectNetErrorInfo:function(e,t){const{NetErrorMonitor:r}=n("IKDA");return r.Instance().collectInfo(t)}` | 4 |

### `$zprotocol`

| member | kind | ipc | channel | main side | uses |
|---|---|---|---|---|---|
| encryptWithKeychain | async | invoke | `zproto-encrypt-with-keychain` | `(identifier:string, plaintexts:Uint8Array[], enableKeychain?)` → Buffer[]; format `[type 1B][iv16][salt16][AES-256-CBC ct][HMAC-SHA256 32]`, HKDF-SHA256(secret,salt,"ZprotocolSecureKDF",64) | 1 |
| decryptWithKeychain | async | invoke | `zproto-decrypt-with-keychain` | `(identifier, ciphers:Uint8Array[])` → Buffer[] (inverse of above; type 0x4B keychain / 0x49 raw) | 1 |
| syncConfigToMain | async (fire&forget, still invoke) | invoke | `zproto-config-sync-to-main` | `{isEnableKeychainEnc}` → SecureCipher.setEnableKeychainEnc | 1 |

### `$znoti`

| member | kind | ipc | channel | main side | uses |
|---|---|---|---|---|---|
| isSupported | async | invoke | `_noti_is-supported` | Electron Notification.isSupported() | 0 |
| createNotification | async | invoke | `_noti_create` | create native Notification; returns id; pushes `_noti_on-click/_noti_on-show/_noti_on-close` | 4 |
| closeNotification | async | invoke | `_noti_close` | `closeNotification:(e,t)=>{var n;null===(n=br.get(t))\|\|void 0===n\|\|n.close()}` | 8 |
| onNotificationClick | event on | on | `_noti_on-click` | main → renderer push (1 send-sites found) | 4 |
| removeListenNotificationClick | event off (removeAll) | removeAllListeners | `_noti_on-click` | local only | 0 |
| onNotificationShow | event on | on | `_noti_on-show` | main → renderer push (1 send-sites found) | 4 |
| removeListenNotificationShow | event off (removeAll) | removeAllListeners | `_noti_on-show` | local only | 0 |
| onNotificationClose | event on | on | `_noti_on-close` | main → renderer push (1 send-sites found) | 4 |
| removeListenNotificationClose | event off (removeAll) | removeAllListeners | `_noti_on-close` | local only | 0 |
## Calls (zcall-v2) — SwiftZalo implementation

Main module "3Zc2" → `ZaloRuntime/CallBridge.swift`; wire format → `CallTransport.swift`; preload shim + status → `HostScripts/call-adapter.js`.

- Two UNIX sockets (private 0700 dir under `$TMPDIR`, paths passed as argv `[recvPath, sendPath]` to `Zalo.app/Contents/ZaloHelper.app/Contents/MacOS/ZaloCall`). recv: helper → main; send: main → helper.
- Frame: `hex(AES-128-CBC(json))` + `$`. Key = base64 `callV2TransportAesKey` (module "5NUA"), IV = 16 zero bytes (module "vqv6"). main → helper payloads > 4000 chars are cut into `<chunk>#<seq>#<count>#<index>#$` (module "4KIH"); one chunk in flight, the helper acknowledges each by writing anything on the send socket.
- helper → main `type`: `update` (`native-ready` → send stored init data, then the queue; else renderer `call-update(command, data)`), `sendSignal` → `call-send-signal`, `request` (`killMe` → SIGINT + restart; else `call-request`), `response` → `call-response-<command>`. Socket end / exit → `call-update('callState', {state:'free'})`.
- Renderer → main: `call-send-to-native` (starts the helper unless `_optional`), `call-init` (stored). Gates (`enable_mac_call`, `enable_ipc_call`, `enableCall`, `enableVideoCall`) come from the renderer's own config/server settings; nothing is overridden.

### Group calls (participant picker) — `call-adapter.js` §5, `ZaloEngine+GroupCall.swift`, `Views/GroupCallPickerSheet.swift`

Offsets are in `pc-dist/compact-app-pc.06caa1ffa528545b8f43.js`.

- **Header gate** (`fl`, ~10971400; helpers `pl`/`gl` ~10970700): `isSupport()`, not OA, not own cloud; groups: remote config `call.visibility.{group_member_threshold (default 20), community_member_threshold (-1)}` (class `go` ~10941900, private to module `VLvn`; value = remote-configs-cache entry `getCache('call')`, DI token "remote-configs-cache") vs `groupInfo.totalMember`; `-2` = shown but disabled, `-1`/below = hidden. Only the **video** button exists for groups (`pl` is `!isGroup`). `makeCall` also needs `enable_group_call_for_user` (call helper ~8133700). `canMakeCallAgain` (~4882600) uses the older `enable_group_call_entry_for_group` flags and is not what the header uses.
- **Outgoing**: header click = `chatBoxController.makeCall(true)` = `_videoCall` (~4827000): `isSupport`, `isCalling`, then `ModalManagerV2.openModal({name:'GROUP_CALL', params:{conversation, data:{isVideo, generateCallMessage, maxUsers: group_call_max_users (default 5)}}})`.
- **Add participant**: native request `addUser` / `addFriend` → `call-request` → helper `handleRequest` (~8131700) → `_processAddUserToGroupCall` (~8140400): `getNoisedUids(partners,[groupId])`, `getGroupInfo`, then the same modal with `data:{existingCalleeIds, isAddUser:true, isAddUserFromFriendList:(cmd==='addFriend'), maxUsers}`; answer = `sendAddUserResponse(groupId, [{userId, avatar}])` → `{type:'response', command:'addUser', data:{groupId, calleeIds}}` (cancel: empty list).
- **The modal** (module "Sh/d", class `g`, ~9027400; list base class "jlVM" ~15804900): `loadData` = group list entry's `topMember` minus me, `isZaloBot`, and (with `group_privacy.hide_member.enable` + `isLockViewMember` and I am not owner/admin) non-admins; mapped through `getProfileFriendSync`; sorted by `getDName` (vi). Limit `max_mem = maxUsers ? maxUsers-1 : 10` (toast `STR_MAX_MEM_INVITE_TOAST`); no select-all; `existingCalleeIds` are ticked + disabled. `onConfirm`: `callHelper.makeCall(selectedIds, isVideo, true, e => generateCallMessage({lastSmsLocalId, displayName, userId}, e), {id: groupId.slice(1), name, avatar, maxUsers})` — or, for add-user, `sendAddUserResponse`. `setCallRuning(false)` closes the modal (call ended).
- **SwiftZalo**: `ModalManagerV2.openModal` / `closeModal` (module `h0sc`) are wrapped; a `GROUP_CALL` open is posted to Swift as `{kind:'picker', token, add, video, group, max, existing, note, members}` (the renderer's invisible modal is not opened), `closeModal(GROUP_CALL)` → `{kind:'pickerClosed', token}`. Swift answers with `__zaloCall.pickerConfirm(token, ids)` / `pickerCancel(token)`, which run the modal's `onConfirm` / `onCancel` above (ids re-validated against the member list and `max`). A second add-user request declines the first.
- **Incoming group call**: control event `act:'group_request'` (`isIncomingCallEvent`); the group name/avatar are looked up in `data.groupName|groupAvatar|groupId` (also inside a nested `data`) and the official group service; the banner shows the group name with "<caller> đang gọi".
