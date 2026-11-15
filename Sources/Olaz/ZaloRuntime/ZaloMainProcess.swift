import AppKit
import CommonCrypto
import CryptoKit
import UniformTypeIdentifiers
import os

private let mainLog = Logger(subsystem: "app.olaz", category: "main-process")

/// What `__shell__` (Electron `shell.openPath`) may hand to `NSWorkspace.open`: folders and documents, never
/// something that runs code. Mirrors `FileCard.mayExecute` / `CloudFiles.mayExecute` (Views) and additionally
/// checks the item on disk (symlink target, real content type, application bundles, execute permission).
enum ShellOpenPolicy {
    static let blockedExtensions: Set<String> = [
        "command", "tool", "terminal", "fileloc", "webloc", "inetloc", "pkg", "mpkg", "app",
        "scpt", "scptd", "workflow", "action", "sh", "bash", "zsh", "csh", "ksh", "jar", "dylib", "bundle",
    ]

    static func typeMayExecute(_ type: UTType) -> Bool {
        let packageTypes = ["com.apple.installer-package-archive", "com.apple.finder.fileloc", "com.apple.terminal.shell-script",
                            "com.apple.web-internet-location", "com.apple.application-script-binary"].compactMap { UTType($0) }
        return type.conforms(to: .executable) || type.conforms(to: .applicationBundle) || type.conforms(to: .package)
            || type.conforms(to: .shellScript) || type.conforms(to: .script) || type.conforms(to: .internetLocation)
            || packageTypes.contains(where: { type.conforms(to: $0) })
    }

    static func extensionMayExecute(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        if blockedExtensions.contains(ext) { return true }
        return UTType(filenameExtension: ext).map(typeMayExecute) ?? false
    }

    static func mayOpen(_ url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory) else { return false }
        if extensionMayExecute(url) || extensionMayExecute(resolved) { return false }
        let values = try? resolved.resourceValues(forKeys: [.isApplicationKey, .isPackageKey, .contentTypeKey])
        if values?.isApplication == true || values?.isPackage == true { return false }
        if let type = values?.contentType, typeMayExecute(type) { return false }
        // A plain folder opens in Finder. A file with an execute bit (Mach-O / script without extension) would run in Terminal.
        if isDirectory.boolValue { return true }
        return !FileManager.default.isExecutableFile(atPath: resolved.path)
    }
}

/// Swift stand-in for the Electron **main process** of Zalo PC.
///
/// The official preload maps each bridge member to an IPC channel
/// (`reanalysis/bridge-table.json`); this class answers those channels with the
/// semantics of `main-dist/main.js` (`reanalysis/bridge-spec.md` §2), pushes the
/// main → renderer events, and drives page navigation (login ⇄ main window).
@MainActor
final class ZaloMainProcess {
    enum Event {
        /// The renderer finished QR login; the main page is loading.
        case loginSucceeded
        /// The renderer asked to go back to the login page (logout, session expiry).
        case loggedOut
        case badge(Int)
    }

    let platform: ZaloPlatform
    weak var host: OfficialClientHost?
    var onEvent: ((Event) -> Void)?

    /// Where the official client's data access layer keeps its databases.
    enum StorageBackend: String, Sendable {
        /// The official "migration disabled" branch: IndexedDB in WebKit (Olaz before the SQLite host).
        case indexedDB = "idb"
        /// Native SQLite through `sqlite-host.js` + `SQLiteHost`, as Zalo PC 26.10 runs after its migration.
        case sqlite
    }
    /// Chosen once per install (`olaz-storage.json`): installs that already hold IndexedDB data stay on it (the
    /// official IndexedDB → SQLite migration needs Electron's SQLite window), fresh installs start on SQLite, and
    /// `OLAZ_STORAGE=idb|sqlite` overrides for a run. `switchStorage` moves an install (its data starts over).
    let storage: StorageBackend
    /// The native SQLite executor behind `$znode.sqliteHost.*` (SQLite backend only).
    let sqlite: SQLiteHost?

    /// Hidden `shared-worker.html` window (Electron's `dbTask` process) and the task router between windows.
    let sharedWorker = SharedWorkerRouter()
    /// Download manager of the main process (`new-download-channel`).
    lazy var downloads = DownloadManager(platform: platform)
    private(set) var workerHost: OfficialClientHost?
    /// Windows that announced `db-client-connected` (they receive `db-authenticated` broadcasts).
    private var dbClients: [WeakBridge] = []
    private final class WeakBridge { weak var bridge: ZaloBridge?; init(_ b: ZaloBridge) { bridge = b } }

    private var scripts: [WeakBridge] = []
    private var announcedSession: Any?
    private var viewerKey: Any?
    private var session: Any?
    private var pendingCloseDBs: [CheckedContinuation<Void, Never>] = []
    private var pushLoginSuccessAfterLoad = false

    /// Auth domain whose `zpw_sek` cookie means "logged in" (main: `XPAe.DEFAULT_AUTH_DOMAIN`).
    static let authDomain = URL(string: "https://wpa.zaloapp.com")!
    static let sessionCookieDomains = ["zaloapp.com", "zalo.me", "chat.zalo.me"]

    /// Native call transport (main's "zcall-v2" module); created on first use.
    private var callBridge: CallBridge?
    var calls: CallBridge {
        if let callBridge { return callBridge }
        let created = CallBridge(emit: { [weak self] channel, args in self?.host?.bridge.send(channel, args) },
                                 log: { EngineLog.shared.write($0) })
        callBridge = created
        return created
    }
    private var terminationObserver: NSObjectProtocol?

    init(platform: ZaloPlatform) {
        self.platform = platform
        storage = Self.chooseStorage(platform: platform)
        sqlite = storage == .sqlite ? SQLiteHost(root: platform.userData.appendingPathComponent("sqlite/_production", isDirectory: true)) : nil
        mainLog.notice("storage backend: \(self.storage.rawValue, privacy: .public)")
        // main `stop()`: the call helper and the fingerprint helper do not outlive the app.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.callBridge?.shutdown()
                FingerprintProxy.shared.shutdown()
            }
        }
    }

    // MARK: Session / navigation

    var hasSession: Bool {
        HTTPCookieStorage.shared.cookies(for: Self.authDomain)?.contains { $0.name == "zpw_sek" && !$0.value.isEmpty } ?? false
    }

    // MARK: Storage backend

    private static let storageStoreName = "olaz-storage"

    static func chooseStorage(platform: ZaloPlatform) -> StorageBackend {
        if let forced = ProcessInfo.processInfo.environment["OLAZ_STORAGE"].flatMap(StorageBackend.init(rawValue:)) { return forced }
        let store = platform.readStore(storageStoreName)
        if let saved = (store["backend"] as? String).flatMap(StorageBackend.init(rawValue:)) { return saved }
        // An install that already ran the official client holds its data in IndexedDB; keep it readable.
        let existing = FileManager.default.fileExists(atPath: platform.storeURL("database-config").path)
        let chosen: StorageBackend = existing ? .indexedDB : .sqlite
        try? platform.writeStore(storageStoreName, ["backend": chosen.rawValue, "chosenAt": Date().timeIntervalSince1970 * 1000])
        return chosen
    }

    /// Records `backend` for the next launch. The official client then meets empty databases (the account's data is
    /// not migrated between backends): the caller logs the account out so it starts over.
    func switchStorage(_ backend: StorageBackend) {
        try? platform.writeStore(Self.storageStoreName, ["backend": backend.rawValue, "chosenAt": Date().timeIntervalSince1970 * 1000])
        var store = platform.readStore("database-config")
        for key in store.keys where key.hasSuffix("adp-st") || key.localizedCaseInsensitiveContains("upgradeRequired") { store.removeValue(forKey: key) }
        try? platform.writeStore("database-config", store)
    }

    /// Query string main appends to pages (`j6F3.qt`, spec §2.4).
    func pageQuery(alreadyLogin: Bool = false) -> [String: String] {
        var query = [
            "type": platform.identity.clientType,
            "client_version": platform.identity.clientVersion,
            "app_version": platform.appVersion,
            "about_version": "",
            "new_install": "0",
            // No native sqlite3 in this host: the renderer must use IndexedDB.
            "fail_sqlite3": "true",
            "mode_lang": "",
        ]
        if alreadyLogin { query["already_login"] = "y" }
        return query
    }

    func start() {
        guard let host else { return }
        normalizeDatabaseAdapterState()
        if hasSession { startSharedWorker() }
        host.load(hasSession ? .main : .login, query: pageQuery())
    }

    /// Electron main creates the hidden shared-worker window together with the main window.
    func startSharedWorker() {
        guard let host else { return }
        stopSharedWorker()
        // Diagnostic A/B switch: run without the hidden shared-worker window.
        if ProcessInfo.processInfo.environment["OLAZ_NO_SHARED_WORKER"] != nil { return }
        let platform = self.platform
        let ua = OfficialClientHost.userAgent(clientType: platform.identity.clientType,
                                              clientVersion: platform.identity.clientVersion)
        let worker = OfficialClientHost(install: host.install, userAgent: ua) { [weak self] bridge in
            guard let self else { return }
            BridgeImplementation.install(on: bridge, platform: platform, mainProcess: self)
        }
        let log = EngineLog.shared
        worker.onConsole = { line in
            // Same policy as the main window: official log/info lines can carry payloads.
            let official = line.hasPrefix("[log]") || line.hasPrefix("[info]")
            if line.contains("do open indexeddb") { return }
            if !official || line.contains("[adapter]") || line.contains("[chat]") || line.contains("[transfer]") {
                log.write("sw-console " + String(line.prefix(300)))
            }
        }
        worker.bridge.trace = { key, args in
            guard !key.contains("ZLog"), !key.hasPrefix("$zelectron.store"), !key.hasPrefix("$znode.sqliteHost") else { return }
            log.write("sw-bridge \(key)\(EngineLog.shape(args))")
        }
        worker.bridge.onHandlerError = { key, error in log.write("sw-bridge-error \(key): \(error.localizedDescription)") }
        worker.network.onRequestCompleted = { method, url, status in
            log.write("sw-net \(status) \(method) \(url.host() ?? "")\(url.path())")
        }
        worker.network.socketTrace = { log.write("sw-" + $0) }
        worker.onPageEvent = { [weak self, weak worker] event in
            log.write("sw-page \(event)")
            if case .finishedLoading = event, let worker {
                self?.sharedWorker.workerDidFinishLoad()
                if let key = self?.viewerKey { worker.bridge.send("receive-viewerkey", [key]) }
            }
        }
        sharedWorker.trace = { log.write("sw-router " + $0) }
        sharedWorker.registerWorker(worker.bridge)
        workerHost = worker
        worker.load(.sharedWorker, query: pageQuery(alreadyLogin: true))
        startWorkerDevEvalIfEnabled()
    }

    /// Dev aid (same switch as the main eval channel): runs `<data>/dev/worker-eval.js` in the
    /// shared-worker window and writes `worker-eval.out.json`.
    private func startWorkerDevEvalIfEnabled() {
        #if DEBUG
        guard UserDefaults.standard.bool(forKey: "OlazDevEval"), workerEvalTask == nil else { return }
        let dir = ZaloPlatform.defaultUserData.deletingLastPathComponent().appendingPathComponent("dev", isDirectory: true)
        let input = dir.appendingPathComponent("worker-eval.js"), output = dir.appendingPathComponent("worker-eval.out.json")
        workerEvalTask = Task { [weak self] in
            var lastModified = Date.distantPast
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let date = (try? FileManager.default.attributesOfItem(atPath: input.path))?[.modificationDate] as? Date,
                      date > lastModified, let source = try? String(contentsOf: input, encoding: .utf8) else { continue }
                lastModified = date
                let wrapped = "try { const __r = await (async () => { \(source) })(); return JSON.stringify({ok: true, value: __r}, (k, v) => typeof v === 'bigint' ? String(v) : v, 1); } catch (e) { return JSON.stringify({ok: false, error: String(e && e.stack || e)}); }"
                let result = await self.workerHost?.evaluate(wrapped) as? String ?? "{\"ok\":false,\"error\":\"no result\"}"
                try? result.write(to: output, atomically: true, encoding: .utf8)
            }
        }
        #endif
    }
    private var workerEvalTask: Task<Void, Never>?

    func stopSharedWorker() {
        guard let worker = workerHost else { return }
        dbClients.removeAll { $0.bridge == nil || $0.bridge === worker.bridge }
        scripts.removeAll { $0.bridge == nil || $0.bridge === worker.bridge }
        sharedWorker.resetWorker(worker.bridge)
        worker.shutdown()
        workerHost = nil
    }

    /// No SQLite backend in this host: keep every account on IndexedDB
    /// (`database-config` → `*adp-st`: `IDB = 0`, `SQLite = 1`) and drop
    /// `upgradeRequired`, which would force a migration.
    func normalizeDatabaseAdapterState() {
        // SQLite backend: the renderer moves every adapter state to SQLite itself (`isMigrateFullDone` is true).
        guard storage == .indexedDB else { return }
        var store = platform.readStore("database-config")
        var changed = false
        for (key, value) in store {
            if key.hasSuffix("adp-st"), let json = value as? String,
               let data = json.data(using: .utf8),
               var states = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                if states.values.contains(where: { ($0 as? NSNumber)?.intValue != 0 }) {
                    for k in states.keys { states[k] = 0 }
                    if let encoded = try? JSONSerialization.data(withJSONObject: states) {
                        store[key] = String(decoding: encoded, as: UTF8.self)
                        changed = true
                    }
                }
            } else if key.localizedCaseInsensitiveContains("upgradeRequired") {
                store.removeValue(forKey: key)
                changed = true
            }
        }
        if changed {
            mainLog.notice("database-config: reset adapter state to IndexedDB")
            try? platform.writeStore("database-config", store)
        }
    }

    /// Navigation callbacks from the host (did-start-loading / did-finish-load).
    func pageDidStartLoading() {
        host?.bridge.send("unload-zlog")
    }

    func pageDidFinishLoading(_ page: OfficialClientHost.Page) {
        guard let bridge = host?.bridge else { return }
        bridge.send("visibility-change", ["show"])
        bridge.send("visibility-change", ["focus", "1"])
        if page == .main, pushLoginSuccessAfterLoad {
            pushLoginSuccessAfterLoad = false
            bridge.send("login-success")
        }
    }

    // MARK: IPC handlers

    func install(on bridge: ZaloBridge) {
        if let url = ResourceLocator.url(for: "bridge-table.json", in: "Resources"),
           let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let raw = json["table"] as? [String: [String: Any]] {
            // A few entries have no channel in the official preload itself; skip those.
            let table = raw.compactMapValues { entry -> [String: String]? in
                guard let channel = entry["channel"] as? String, let type = entry["type"] as? String else { return nil }
                return ["channel": channel, "type": type]
            }
            bridge.loadIPCTable(table)
        } else {
            mainLog.fault("bridge-table.json missing — bridge will not match the official preload")
        }

        let platform = self.platform

        // App / paths (spec §2.3)
        bridge.handle("_electron_get-path") { args in platform.path(args.string(0) ?? "userData") }
        bridge.handleSync("_electron_get-path-sync") { args in platform.path(args.string(0) ?? "userData") }
        bridge.handle("_electron_get-app-version") { _ in platform.appVersion }
        bridge.handle("_electron_get-app-path") { _ in platform.userData.path }
        bridge.handleSync("_electron_get-app-path-sync") { _ in platform.userData.path }
        bridge.handleSync("electron-store-get-data") { _ in ["defaultCwd": platform.userData.path, "appVersion": platform.appVersion] }
        bridge.handle("get-child-url") { _ in "\(OfficialClientHost.scheme)://local/child.html" }
        bridge.handle("get-photo-viewer-url") { _ in "\(OfficialClientHost.scheme)://local/popup-viewer.html" }
        bridge.handle("get-resource-dir") { _ in "\(OfficialClientHost.scheme)://local/" }

        // Storage selection (spec §2.2, §4). SQLite backend: the official "migration fully done" state, so every
        // database adapter is SQLite and the DAL channel targets the utility process that sqlite-host.js plays.
        // IndexedDB backend: the official "migration disabled" branch. `fail-load-sqlite3` stays true in both: the
        // legacy message search index runs in its web worker (the native search binding is not provided).
        let sqliteBackend = storage == .sqlite
        bridge.handle("sqlite-available") { _ in sqliteBackend }
        bridge.handle("fail-load-sqlite3") { _ in true }
        bridge.handle("is-migrate-full-done") { _ in sqliteBackend }
        bridge.handle("get-migrate-local-info") { _ in ["disable_migrate": true] }
        bridge.handle("migratedb:check_need_wait_bu") { _ in false }
        bridge.handle("z-db-corruption-detector") { _ in 0 }
        bridge.handle("get-name-of-target-script-for-dal-channel-from-host") { _ in sqliteBackend ? "utility-process-sqlite" : "preload-sqlite" }
        // Electron relaunches the app here; the equivalent is reloading the page
        // after resetting the adapter state (no SQLite backend to migrate to).
        bridge.handle("migratedb:signal_restart") { [weak self] _ in
            guard let self else { return nil }
            mainLog.notice("renderer requested restart for DB migration — reloading on \(self.storage.rawValue, privacy: .public)")
            self.normalizeDatabaseAdapterState()
            if self.hasSession { self.startSharedWorker() } else { self.stopSharedWorker() }
            self.host?.load(self.hasSession ? .main : .login, query: self.pageQuery())
            return nil
        }

        // Cookies (spec §2.1)
        bridge.handle("_electron_set-app-cookie") { args in
            guard let value = args.string(0) else { return nil }
            // Replace any previous session cookie (host-only or domain) so exactly one is sent.
            for cookie in HTTPCookieStorage.shared.cookies ?? [] where cookie.name == "zpw_sek" {
                HTTPCookieStorage.shared.deleteCookie(cookie)
            }
            for domain in Self.sessionCookieDomains {
                Self.setCookie(name: "zpw_sek", value: value, domain: domain, days: 7, httpOnly: true)
            }
            return nil
        }
        bridge.handle("_electron_set-cookie") { args in
            guard let name = args.string(0), let value = args.string(1) else { return nil }
            let domain = args.string(3) ?? URL(string: args.string(2) ?? "")?.host() ?? "zalo.me"
            Self.setCookie(name: name, value: value, domain: domain, days: 365, httpOnly: false)
            return nil
        }
        bridge.handle("_electron_clear-cookie") { _ in
            Self.clearCookies()
            return nil
        }

        // Login / session hand-off
        bridge.handle("login-success") { [weak self] _ in
            self?.loginSucceeded()
            return nil
        }
        bridge.handle("login") { [weak self] _ in
            self?.backToLogin()
            return nil
        }
        // ScriptCoordinator: every window announces itself with `script-connected`; a session
        // set by one window is broadcast to the others (and replayed to late joiners).
        bridge.handle("script-connected") { [weak self, weak bridge] _ in
            guard let self, let bridge else { return nil }
            self.scripts.removeAll { $0.bridge == nil }
            if !self.scripts.contains(where: { $0.bridge === bridge }) { self.scripts.append(WeakBridge(bridge)) }
            if let announced = self.announcedSession { bridge.send("new-session", [announced]) }
            return nil
        }
        bridge.handle("new-session") { [weak self, weak bridge] args in
            guard let self else { return nil }
            self.session = args.first
            let payload = args.first
            if payload == nil || payload is NSNull || (payload as? [String: Any])?.isEmpty == true {
                self.announcedSession = nil
            } else if let session = payload {
                self.announcedSession = session
                for script in self.scripts.compactMap(\.bridge) where script !== bridge {
                    script.send("new-session", [session])
                }
            }
            return nil
        }
        // MainDatabaseManager: authenticate → broadcast to every connected DB client window.
        bridge.handle("db-authenticated") { [weak self, weak bridge] args in
            guard let self else { return nil }
            self.session = args.first
            guard let session = args.first else { return nil }
            var targets = self.dbClients.compactMap(\.bridge)
            if let bridge, !targets.contains(where: { $0 === bridge }) { targets.append(bridge) }
            for target in targets { target.send("db-authenticated", [session]) }
            return nil
        }
        bridge.handle("db-client-connected") { [weak self, weak bridge] _ in
            guard let self, let bridge else { return nil }
            self.dbClients.removeAll { $0.bridge == nil }
            if !self.dbClients.contains(where: { $0.bridge === bridge }) { self.dbClients.append(WeakBridge(bridge)) }
            if let session = self.session { bridge.send("db-authenticated", [session]) }
            return nil
        }
        sharedWorker.install(on: bridge)
        downloads.install(on: bridge)
        // main `receiveViewerKeyListener`: the viewer key (decrypts the local data stores) is
        // relayed to the shared-worker window, whose SecureLocalStorage needs it.
        bridge.handle("receive-viewerkey") { [weak self] args in
            guard let self, let key = args.first else { return nil }
            self.viewerKey = key
            self.workerHost?.bridge.send("receive-viewerkey", [key])
            return nil
        }
        bridge.handle("db-start-close-dbs") { [weak self, weak bridge] args in
            bridge?.send("db-start-close-dbs", args)
            guard let self, bridge?.subscribedChannels.contains("db-start-close-dbs") == true else { return nil }
            await withCheckedContinuation { continuation in
                self.pendingCloseDBs.append(continuation)
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(5))
                    self.finishCloseDBs()
                }
            }
            return nil
        }
        bridge.handle("db-finish-close-dbs") { [weak self] _ in
            self?.finishCloseDBs()
            return nil
        }

        // Secure storage used by the trusted-device protocol
        bridge.handle("zsafestorage-execute") { args in
            try SafeStorage(platform: platform).execute(args.string(0) ?? "", Array(args.dropFirst()))
        }
        bridge.handle("zproto-encrypt-with-keychain") { args in
            let items = (args.count > 1 ? args[1] as? [Any] : nil)?.compactMap { $0 as? Data } ?? []
            return try KeychainCipher(platform: platform).encrypt(identifier: args.string(0) ?? "", items: items)
        }
        bridge.handle("zproto-decrypt-with-keychain") { args in
            let items = (args.count > 1 ? args[1] as? [Any] : nil)?.compactMap { $0 as? Data } ?? []
            return try KeychainCipher(platform: platform).decrypt(identifier: args.string(0) ?? "", items: items)
        }

        // Native helpers without a native module here: report "not supported" the
        // way main's mainless worker reports errors, so the renderer falls back.
        let unsupported: ZaloBridge.AsyncHandler = { _ in
            ["error": ["name": "NotSupported", "message": "Not supported", "code": "ENOTSUP"]]
        }
        bridge.handle("exec", unsupported)
        bridge.handle("exec_raw", unsupported)

        // $zperf.getCpuInfos → Electron app.getAppMetrics()
        bridge.handle("get-cpu-infos") { _ in
            let pid = Int(ProcessInfo.processInfo.processIdentifier)
            return [["pid": pid, "type": "Browser", "cpu": ["percentCPUUsage": 0, "idleWakeupsPerSecond": 0],
                     "memory": ["workingSetSize": 0, "peakWorkingSetSize": 0]]]
        }

        bridge.handle("badge-count") { [weak self] args in
            let count = args.int(0) ?? 0
            NSApp.dockTile.badgeLabel = count <= 0 ? nil : (count > 5 ? "5+" : "\(count)")
            self?.onEvent?(.badge(count))
            return nil
        }
        // `_noti_*` (Electron Notification, `$znoti`) → UNUserNotificationCenter (NativeNotifier.swift).
        NativeNotifier.installIPC(on: bridge)
        bridge.handle("__shell__") { args in
            let path = args.string(1) ?? ""
            guard !path.isEmpty else { return false }
            let url = URL(fileURLWithPath: path)
            switch args.string(0) {
            case "showItemInFolder": NSWorkspace.shared.activateFileViewerSelecting([url])
            default:
                // Issue #1.2: never launch code on the renderer's word (same rule as the native file card):
                // folders and documents open; apps, scripts, installers, executables are only revealed in Finder.
                guard ShellOpenPolicy.mayOpen(url) else {
                    mainLog.notice("shell.openPath refused (may run code): \(url.lastPathComponent, privacy: .private)")
                    if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    return false
                }
                return NSWorkspace.shared.open(url)
            }
            return true
        }
        bridge.handle("__child_process__") { _ in
            throw ZaloBridge.BridgeError(message: "EPERM: child_process is not available")
        }

        // Voice / video calls (`$zcall`): main's call module relays to the native helper (CallBridge.swift).
        bridge.handle("call-send-to-native") { [weak self] args in
            self?.calls.handleSendToNative(args)
            return nil
        }
        bridge.handle("call-init") { [weak self] args in
            self?.calls.handleInit(args)
            return nil
        }
        // `$zFeatures.zaloCall.requestCompressedLogFile` feeds the call-log upload to Zalo's QoS server;
        // answered with the official error shape so the renderer skips the upload.
        bridge.handle("request-compressed-log-file") { _ in
            ["status": 2, "data": ["message": "Not supported", "errorData": NSNull()]]
        }
    }

    private func loginSucceeded() {
        mainLog.info("login-success → loading main page")
        pushLoginSuccessAfterLoad = true
        startSharedWorker()
        host?.load(.main, query: pageQuery(alreadyLogin: true))
        onEvent?(.loginSucceeded)
    }

    /// Drops everything tied to the signed-in account: worker window, cached session, viewer key.
    /// Called on logout (renderer-initiated or from the UI) before the login page loads.
    func resetAccountState() {
        session = nil
        announcedSession = nil
        viewerKey = nil
        downloads.reset()
        callBridge?.reset()
        stopSharedWorker()
        sharedWorker.resetSession()
        if let sqlite { Task { await sqlite.closeAll() } }
    }

    private func backToLogin() {
        resetAccountState()
        host?.load(.login, query: pageQuery())
        onEvent?(.loggedOut)
    }

    private func finishCloseDBs() {
        let waiting = pendingCloseDBs
        pendingCloseDBs.removeAll()
        waiting.forEach { $0.resume() }
    }

    // MARK: Cookies

    /// Electron's `cookies.set({domain})` creates a *domain* cookie (sent to
    /// subdomains such as `ws5-msg.chat.zalo.me`); Foundation only does that when
    /// the domain has a leading dot — without it the cookie is host-only.
    static func setCookie(name: String, value: String, domain: String, days: Double, httpOnly: Bool,
                          storage: HTTPCookieStorage = .shared) {
        let domainCookie = domain.hasPrefix(".") ? domain : "." + domain
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name, .value: value, .domain: domainCookie, .path: "/",
            .secure: "TRUE", .expires: Date.now.addingTimeInterval(days * 86_400),
            .sameSitePolicy: "none",
        ]
        if httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if let cookie = HTTPCookie(properties: properties) { storage.setCookie(cookie) }
    }

    static func clearCookies() {
        let storage = HTTPCookieStorage.shared
        for cookie in storage.cookies ?? [] where Self.isZaloDomain(cookie.domain) {
            storage.deleteCookie(cookie)
        }
    }

    static func isZaloDomain(_ domain: String) -> Bool {
        let d = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        return ["zalo.me", "zaloapp.com", "zadn.vn", "zdn.vn", "zing.vn"].contains { d == $0 || d.hasSuffix("." + $0) }
    }
}

// MARK: - zsafe-storage (main `tGN0`, spec §2.1)

/// String vault backed by electron-store `zsafe-storage`: values at `zsskd.<key>`,
/// AES-256-CBC with main's fixed key/IV (cipher version `zsskv = "2"`).
@MainActor
struct SafeStorage {
    let platform: ZaloPlatform
    private static let key = Data("d9c07b9de9915af401607d3f360211ac".utf8)
    private static let iv = Data([155, 72, 37, 195, 9, 217, 80, 42, 145, 102, 171, 75, 214, 176, 134, 18])

    func execute(_ method: String, _ args: [Any]) throws -> Any? {
        switch method {
        case "encryptString": return try encrypt(args.string(0) ?? "")
        case "decryptString": return try decrypt(args.string(0) ?? "")
        case "get":
            guard let key = args.string(0), !key.contains(".") else { return nil }
            let store = platform.readStore("zsafe-storage")
            guard let sealed = (store["zsskd"] as? [String: Any])?[key] as? String else { return nil }
            return try? decrypt(sealed)
        case "set":
            guard let key = args.string(0), !key.contains(".") else { return nil }
            var store = platform.readStore("zsafe-storage")
            var values = store["zsskd"] as? [String: Any] ?? [:]
            if let value = args.string(1) { values[key] = try encrypt(value) } else { values.removeValue(forKey: key) }
            store["zsskd"] = values
            store["zsskv"] = "2"
            try platform.writeStore("zsafe-storage", store)
            return nil
        default:
            throw ZaloBridge.BridgeError(message: "zsafestorage: unknown method \(method)")
        }
    }

    private func encrypt(_ plain: String) throws -> String {
        try AESCBC.crypt(Data(plain.utf8), key: Self.key, iv: Self.iv, encrypt: true).base64EncodedString()
    }

    private func decrypt(_ sealed: String) throws -> String {
        let data = try AESCBC.crypt(Data(base64Encoded: sealed) ?? Data(), key: Self.key, iv: Self.iv, encrypt: false)
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - zprotocol keychain cipher (main SecureCipher, spec §2.1)

/// Seals the trusted-device protocol's secrets. Per identifier a 32-byte root key
/// is kept in the macOS Keychain; each item is `[0x49][iv16][salt16][ct][hmac32]`
/// with HKDF-SHA256(root, salt, "ZprotocolSecureKDF") → enc/mac keys, like main.
@MainActor
struct KeychainCipher {
    let platform: ZaloPlatform
    private static let info = Data("ZprotocolSecureKDF".utf8)
    private static let typeRaw: UInt8 = 0x49

    func encrypt(identifier: String, items: [Data]) throws -> [Data] {
        let root = try rootKey(identifier, create: true)
        return try items.map { plain in
            let salt = Self.random(16), iv = Self.random(16)
            let (enc, mac) = Self.derive(root, salt)
            let ct = try AESCBC.crypt(plain, key: enc, iv: iv, encrypt: true)
            let tag = Data(HMAC<SHA256>.authenticationCode(for: ct + iv + salt, using: SymmetricKey(data: mac)))
            return Data([Self.typeRaw]) + iv + salt + ct + tag
        }
    }

    func decrypt(identifier: String, items: [Data]) throws -> [Data] {
        let root = try rootKey(identifier, create: false)
        return try items.map { sealed in
            guard sealed.count >= 65 else { throw ZaloBridge.BridgeError(message: "Invalid encrypted data length") }
            let bytes = [UInt8](sealed)
            let iv = Data(bytes[1..<17]), salt = Data(bytes[17..<33])
            let ct = Data(bytes[33..<(bytes.count - 32)]), tag = Data(bytes.suffix(32))
            let (enc, mac) = Self.derive(root, salt)
            guard HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: ct + iv + salt, using: SymmetricKey(data: mac)) else {
                throw ZaloBridge.BridgeError(message: "Invalid MAC")
            }
            return try AESCBC.crypt(ct, key: enc, iv: iv, encrypt: false)
        }
    }

    private static func derive(_ root: Data, _ salt: Data) -> (Data, Data) {
        let okm = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: root), salt: salt, info: info, outputByteCount: 64)
        let bytes = okm.withUnsafeBytes { Data($0) }
        return (bytes.prefix(32), bytes.suffix(32))
    }

    private static func random(_ n: Int) -> Data {
        var data = Data(count: n)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, n, $0.baseAddress!) }
        return data
    }

    private func rootKey(_ identifier: String, create: Bool) throws -> Data {
        let account = "zprotocol.\(identifier.lowercased())"
        switch Keychain.read(account: account) {
        case .found(let existing): return existing
        // A key that exists but cannot be read now (locked keychain, denied access) must never be shadowed by a fresh one:
        // everything sealed with the old key would be lost for good.
        case .failed(let status): throw ZaloBridge.BridgeError(message: "Keychain read failed (\(status))")
        case .notFound: break
        }
        guard create else { throw ZaloBridge.BridgeError(message: "No secret for \(identifier)") }
        let key = Self.random(32)
        try Keychain.write(account: account, data: key)
        return key
    }
}

enum Keychain {
    static let service = "app.olaz.secure"
    /// Service of the SwiftZalo builds. Their root keys still decrypt the migrated client data, so a key the new `service`
    /// reports as not found is taken from there once and copied over (the legacy item is left for the old app).
    static let legacyService = "dev.swiftzalo.secure"

    enum Lookup {
        case found(Data)
        /// Neither service holds the item: the only answer that allows minting a new secret.
        case notFound
        /// The keychain could not tell (locked, access denied…): the item may well exist.
        case failed(OSStatus)
    }

    /// Reads from `service`, then from `legacyService`, but only when the first says `errSecItemNotFound`: any other
    /// failure stops there, so an unreadable item is never mistaken for a missing one.
    static func read(account: String) -> Lookup {
        let current = read(account: account, service: service)
        guard case .notFound = current else { return current }
        let legacy = read(account: account, service: legacyService)
        // Copied only after a successful read; a failed copy just means the next read finds the legacy item again.
        if case .found(let data) = legacy { try? write(account: account, data: data) }
        return legacy
    }

    private static func read(account: String, service: String) -> Lookup {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return (result as? Data).map(Lookup.found) ?? .failed(errSecDecode)
        case errSecItemNotFound: return .notFound
        default: return .failed(status)
        }
    }

    static func write(account: String, data: Data) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw ZaloBridge.BridgeError(message: "Keychain write failed (\(status))") }
    }

    /// Removes every secret, the legacy service's too: `read` would otherwise fall back to them and copy them over again.
    static func deleteAll() {
        for service in [service, legacyService] {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
        }
    }
}

enum AESCBC {
    static func crypt(_ input: Data, key: Data, iv: Data, encrypt: Bool) throws -> Data {
        var out = Data(count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let outCount = out.count
        let status = out.withUnsafeMutableBytes { o in
            input.withUnsafeBytes { i in
                key.withUnsafeBytes { k in
                    iv.withUnsafeBytes { v in
                        CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding), k.baseAddress, key.count, v.baseAddress,
                                i.baseAddress, input.count, o.baseAddress, outCount, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw ZaloBridge.BridgeError(message: "bad decrypt") }
        return out.prefix(moved)
    }
}
