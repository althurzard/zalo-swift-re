import AppKit
import Network
import WebKit
import UniformTypeIdentifiers
import os

private let hostLog = Logger(subsystem: "app.olaz", category: "host")

/// Runs the official Zalo renderer (read from the Zalo runtime Olaz installs, `ZaloRuntime`) headless in
/// a WKWebView. Swift supplies what Electron's preload/main process supplied —
/// the `$z*` bridge, networking, storage — and drives the SwiftUI interface from
/// the renderer's state. The renderer's own DOM is never shown to users (a debug
/// window can display it while developing).
@MainActor
final class OfficialClientHost: NSObject {
    enum Page: String {
        case login = "login.html"
        case main = "index.html"
        /// Electron's hidden `dbTask` window: runs the background task handlers (cloud scan, offline sync…).
        case sharedWorker = "shared-worker.html"
    }

    static let scheme = "zalo-app"
    /// Development hook: receives host diagnostics (missing files, crashes).
    nonisolated(unsafe) static var diagnostics: ((String) -> Void)?

    let install: OfficialZaloInstall.Info
    let bridge = ZaloBridge()
    let network: NetworkProxy
    let webView: WKWebView
    private let schemeHandler: AsarSchemeHandler
    private let consoleHandler = ConsoleHandler()
    private let stateHandler = StateHandler()

    /// Snapshots posted by `state-adapter.js`.
    var onState: (([String: Any]) -> Void)? {
        get { stateHandler.sink }
        set { stateHandler.sink = newValue }
    }
    private var debugWindow: NSWindow?
    private let pathMonitor = NWPathMonitor()
    private(set) var currentPage: Page?

    /// Renderer console output and uncaught errors.
    var onConsole: ((String) -> Void)? {
        get { consoleHandler.sink }
        set { consoleHandler.sink = newValue }
    }

    /// Navigation callbacks (Electron's did-start-loading / did-finish-load).
    var onPageEvent: ((PageEvent) -> Void)?
    /// Files the next open panel of the page is answered with (composer-adapter.js clicks a hidden file input); taken once.
    private var pendingOpenPanel: (id: UUID, urls: [URL])?
    private var openPanelBusy = false
    private var openPanelWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishedPicks: Set<UUID> = []
    enum PageEvent {
        case startedLoading
        case finishedLoading(Page)
        case failed(Error)
    }

    /// Main sets the whole UA to `"ZaloPC-" + platform + "-" + type + "v" + clientVersion`
    /// (spec §5). The renderer derives the device id from md5(navigator.userAgent).
    static func userAgent(clientType: String, clientVersion: String) -> String {
        "ZaloPC-darwin-\(clientType)v\(clientVersion)"
    }

    init(install: OfficialZaloInstall.Info, userAgent ua: String, configureBridge: (ZaloBridge) -> Void) {
        self.install = install
        network = NetworkProxy(userAgent: ua)
        schemeHandler = AsarSchemeHandler(asar: install.asar, root: "pc-dist")

        configureBridge(bridge)

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.inactiveSchedulingPolicy = .none
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.setURLSchemeHandler(schemeHandler, forURLScheme: Self.scheme)
        let content = config.userContentController
        content.add(consoleHandler, name: ConsoleHandler.name)
        content.add(stateHandler, name: StateHandler.name)
        content.addScriptMessageHandler(network, contentWorld: .page, name: NetworkProxy.handlerName)
        content.addScriptMessageHandler(bridge, contentWorld: .page, name: ZaloBridge.handlerName)
        let diagnostics = ProcessInfo.processInfo.environment["OLAZ_TRACE_WORKERS"] != nil ? "window.__zaloTraceWorkers = true;" : ""
        for script in [diagnostics, ConsoleHandler.script, Self.hostScript("network-shim"), bridge.specScript(), Self.hostScript("local-modules"), Self.hostScript("bridge"), Self.hostScript("sqlite-host"), Self.hostScript("state-adapter"), Self.hostScript("chat-adapter"), Self.hostScript("media-store-adapter"), Self.hostScript("card-actions-adapter"), Self.hostScript("sticker-adapter"), Self.hostScript("composer-adapter"), Self.hostScript("message-actions-adapter"), Self.hostScript("transfer-adapter"), Self.hostScript("conversations-adapter"), Self.hostScript("conversation-actions-adapter"), Self.hostScript("contacts-adapter"), Self.hostScript("group-create-adapter"), Self.hostScript("notification-adapter"), Self.hostScript("zcloud-adapter"), Self.hostScript("poll-adapter"), Self.hostScript("call-adapter")] {
            content.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }

        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 720), configuration: config)
        webView.customUserAgent = ua
        webView.isInspectable = true
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        startPathMonitor()
        schemeHandler.bridge = bridge
        network.webView = webView
        bridge.webView = webView
    }

    static func hostScript(_ name: String) -> String {
        guard let url = ResourceLocator.url(for: "\(name).js", in: "HostScripts"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            hostLog.fault("missing host script \(name, privacy: .public)")
            return ""
        }
        #if DEBUG
        return source + "\n//# sourceURL=olaz-\(name).js"
        #else
        // Release: no sourceURL. The renderer's error stacks (which its log collector can upload)
        // must not name third-party scripts; without it our frames show up anonymous.
        return source
        #endif
    }

    func load(_ page: Page, query: [String: String]) {
        currentPage = page
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "local"
        components.path = "/" + page.rawValue
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        hostLog.info("loading \(page.rawValue, privacy: .public)")
        webView.load(URLRequest(url: components.url!))
    }

    /// Feeds the `navigator.connection` polyfill with the real network path.
    private func startPathMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let type = path.usesInterfaceType(.wifi) ? "wifi" : path.usesInterfaceType(.wiredEthernet) ? "ethernet"
                : path.usesInterfaceType(.cellular) ? "cellular" : path.status == .satisfied ? "other" : "none"
            let info: [String: Any] = [
                "type": type,
                "effectiveType": path.status == .satisfied ? (path.isConstrained ? "3g" : "4g") : "slow-2g",
                "saveData": path.isConstrained,
            ]
            Task { @MainActor in
                _ = try? await self?.webView.callAsyncJavaScript(
                    "window.__zaloNet && window.__zaloNet.connectionChanged(info)",
                    arguments: ["info": info], contentWorld: .page)
            }
        }
        pathMonitor.start(queue: .main)
    }

    func evaluate(_ script: String) async -> Any? {
        try? await webView.callAsyncJavaScript(script, contentWorld: .page)
    }

    /// Runs `script`, answering the open panel it opens (a file input clicked synchronously in it) with `urls`: the page
    /// then holds disk-backed `File`s for exactly the files the user picked, like a browser's `<input type=file>`.
    /// One pick at a time: the next waits until WebKit took this one's files (or the script ended without asking for them).
    func evaluate(_ script: String, providingFiles urls: [URL]) async -> Any? {
        while openPanelBusy { await withCheckedContinuation { openPanelWaiters.append($0) } }
        openPanelBusy = true
        let id = UUID()
        let token = id.uuidString
        let resolvedURLs = urls.map { $0.resolvingSymlinksInPath() }
        pendingOpenPanel = (id, resolvedURLs)
        schemeHandler.pendingFiles = resolvedURLs
        schemeHandler.pendingBatches[token] = resolvedURLs
        let taggedScript = "window.__olazPendingPickToken = \"\(token)\"; \(script)"
        let run = Task {
            let value = await self.evaluate(taggedScript)
            self.finishedPicks.insert(id)
            return JSBox(value: value)
        }
        let deadline = Date().addingTimeInterval(15)
        while pendingOpenPanel?.id == id, !finishedPicks.contains(id), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        if pendingOpenPanel?.id == id { pendingOpenPanel = nil }
        openPanelBusy = false
        if !openPanelWaiters.isEmpty { openPanelWaiters.removeFirst().resume() }
        let result = await run.value.value
        schemeHandler.pendingBatches.removeValue(forKey: token)
        if schemeHandler.pendingBatches.isEmpty { schemeHandler.pendingFiles = [] }
        finishedPicks.remove(id)
        return result
    }

    func shutdown() {
        pathMonitor.cancel()
        network.closeAllSockets()
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    /// Shows the renderer's own DOM in a separate window (development aid only).
    func showDebugWindow() {
        if debugWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = "Zalo renderer (debug)"
            window.isReleasedWhenClosed = false
            window.contentView = webView
            window.center()
            debugWindow = window
        }
        debugWindow?.makeKeyAndOrderFront(nil)
    }
}

extension OfficialClientHost: WKUIDelegate {
    /// The page never shows its own file dialog: only a pick Swift made (`evaluate(_:providingFiles:)`) answers it.
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        let urls = pendingOpenPanel?.urls
        pendingOpenPanel = nil
        guard let urls, !urls.isEmpty else { completionHandler(nil); return }
        completionHandler(parameters.allowsMultipleSelection ? urls : Array(urls.prefix(1)))
    }
}

extension OfficialClientHost: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        onPageEvent?(.startedLoading)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let currentPage { onPageEvent?(.finishedLoading(currentPage)) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onPageEvent?(.failed(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        onPageEvent?(.failed(error))
    }

    /// Only the renderer's own pages load in this view; links open in the browser.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        if url.scheme == Self.scheme || url.scheme == "about" || url.scheme == "blob" || url.scheme == "data" { return .allow }
        if action.targetFrame?.isMainFrame == false { return .allow }
        if ["http", "https"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
        return .cancel
    }

    /// Electron's renderer process can crash; WebKit's content process too. Reload.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        hostLog.error("web content process terminated — reloading")
        webView.reload()
    }
}

// MARK: - Serving pc-dist out of app.asar

final class AsarSchemeHandler: NSObject, WKURLSchemeHandler {
    static let bridgeSyncPath = "/__olaz/bridge-sync"
    static let pendingFilesPath = "/__olaz/pending-files"
    static let pendingFilesPrefix = "/__olaz/pending-files/"
    static let pendingFilePrefix = "/__olaz/pending-file/"
    let asar: AsarArchive
    let root: String
    weak var bridge: ZaloBridge?
    var pendingFiles: [URL] = []
    var pendingBatches: [String: [URL]] = [:]

    init(asar: AsarArchive, root: String) {
        self.asar = asar
        self.root = root
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        // Same-origin endpoint: index.html's CSP (`connect-src 'self' …`) blocks other hosts.
        if url.path() == Self.bridgeSyncPath {
            let body = task.request.httpBody ?? Data()
            let data = MainActor.assumeIsolated { bridge?.handleSyncRequest(body) } ?? Data("{}".utf8)
            respond(task, url: url, data: data, mime: "application/json")
            return
        }
        if url.path() == Self.pendingFilesPath || url.path().hasPrefix(Self.pendingFilesPrefix) {
            let token = url.path().hasPrefix(Self.pendingFilesPrefix)
                ? String(url.path().dropFirst(Self.pendingFilesPrefix.count))
                : ""
            let urls = MainActor.assumeIsolated {
                token.isEmpty ? pendingFiles : (pendingBatches[token] ?? pendingFiles)
            }
            let list: [[String: Any]] = urls.enumerated().map { index, fileURL in
                let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
                let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
                let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                return [
                    "index": index,
                    "name": fileURL.lastPathComponent,
                    "path": fileURL.resolvingSymlinksInPath().path,
                    "mime": Self.mime(for: fileURL.path),
                    "size": size,
                    "lastModified": Int64((mtime * 1000).rounded())
                ]
            }
            let data = (try? JSONSerialization.data(withJSONObject: list)) ?? Data("[]".utf8)
            respond(task, url: url, data: data, mime: "application/json")
            return
        }
        if url.path().hasPrefix(Self.pendingFilePrefix) {
            let tail = String(url.path().dropFirst(Self.pendingFilePrefix.count))
            let parts = tail.split(separator: "/", omittingEmptySubsequences: true)
            let urls: [URL]
            let indexOpt: Int?
            if parts.count == 2 {
                let token = String(parts[0])
                indexOpt = Int(parts[1])
                urls = MainActor.assumeIsolated { pendingBatches[token] ?? pendingFiles }
            } else {
                indexOpt = Int(tail)
                urls = MainActor.assumeIsolated { pendingFiles }
            }
            if let index = indexOpt, urls.indices.contains(index),
               let data = try? Data(contentsOf: urls[index]) {
                respond(task, url: url, data: data, mime: Self.mime(for: urls[index].path))
                return
            }
            task.didReceive(HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!)
            task.didFinish()
            return
        }
        let path = url.path()
        let candidates = ["\(root)\(path)", String(path.dropFirst())]
        guard let data = candidates.lazy.compactMap({ self.asar.read($0) }).first else {
            hostLog.error("404 \(path, privacy: .public)")
            OfficialClientHost.diagnostics?("[404] \(path)")
            task.didReceive(HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!)
            task.didFinish()
            return
        }
        // The DAL worker hosts the sync-v2 sub-worker (DB writes); see `workerPrelude`.
        var body = data
        if (path.hasPrefix("/dal-worker.") || path.hasPrefix("/mainless-worker.")), path.hasSuffix(".js") {
            body = Data(Self.workerPrelude.utf8) + data
        }
        if path.hasPrefix("/sync-v2-sub-worker."), path.hasSuffix(".js") { body = Self.exposeWebpackRequire(in: body) }
        if path.hasPrefix("/lazy/main-startup."), path.hasSuffix(".js") { body = Self.patchSyncGlobalIdResolver(in: body) }
        #if DEBUG
        // Debug builds only: surface the sub-worker's swallowed import error (the official log
        // sink for this worker is not persisted) — a forwarding call is added next to its logger.
        if path.hasPrefix("/sync-v2-sub-worker."), path.hasSuffix(".js"),
           let range = body.range(of: Data("return this.logger.zsymb(18,\"CytfSU\",".utf8)) {
            body.insert(contentsOf: Data("self.__zhostFwd&&self.__zhostFwd('insertToDb-failed',e&&((e.name||'')+': '+(e.message||e)+' | '+String(e.stack||'').split('\\n').slice(0,6).join(' < ')));".utf8), at: range.lowerBound)
        }
        #endif
        respond(task, url: url, data: body, mime: Self.mime(for: path))
    }


    /// DEVIATION FROM OFFICIAL (sync-v2 `GET_GLOBAL_NOISED_IDS`, main renderer chunk `lazy/main-startup.*.js`).
    ///
    /// The task maps a 1-1 conversation's user id to the global noised id of the phone's backup with
    /// `<svc>.resolveWithRetry(ids, ids => <friendMgr>.default.getGlobalIdsFromUserIds(ids))`, which is
    /// backed only by the `getminiprofiles` API. That API replies "Successful." with an empty map for
    /// users it returns no profile for (valid accounts all the same: `/api/gid/encrypt` maps them and
    /// `/api/gid/decrypt` round-trips). Every such conversation then fails with PC_GET_NOISED_ID_FAILED,
    /// counts against remote config `max_batch_fail` and aborts the sync with EXCEEDED_MAX_BATCH_FAIL.
    /// Official Zalo normally never gets here because its conversation phase fills the worker's id cache
    /// in the same session; resuming ranges persisted by an earlier run has no such cache.
    ///
    /// The patch makes the lookup callback ask `window.__swzGlobalIdFallback` (transfer-adapter.js: the
    /// official global-id service, `/api/gid/encrypt`) for exactly the ids the profile lookup left
    /// unmapped, and merges the answer. Unmapped ids remain unmapped (same failure as before); the hook is
    /// optional (`typeof` guarded) and errors are swallowed, so the worst case equals official behaviour.
    /// Only patches an unambiguous single occurrence of the callback shape; otherwise serves the original.
    static func patchSyncGlobalIdResolver(in data: Data) -> Data {
        func unpatched(_ why: String) -> Data {
            hostLog.error("main-startup served without global-id fallback: \(why, privacy: .public)")
            Task { @MainActor in EngineLog.shared.write("host: main-startup served without global-id fallback (\(why)) — unmappable 1-1 conversations will fail sync") }
            return data
        }
        guard let source = String(data: data, encoding: .utf8) else { return unpatched("not utf8") }
        let ident = #"[A-Za-z_$][A-Za-z0-9_$]*"#
        let pattern = #"(\#(ident))\.resolveWithRetry\((\#(ident)),\((\#(ident))=>(\#(ident))\.default\.getGlobalIdsFromUserIds\(\3\)\)\)"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return unpatched("bad pattern") }
        let whole = NSRange(source.startIndex..., in: source)
        let matches = re.matches(in: source, range: whole)
        guard matches.count == 1, let m = matches.first else { return unpatched(matches.isEmpty ? "resolver shape not found" : "resolver shape ambiguous") }
        func group(_ i: Int) -> String { String(source[Range(m.range(at: i), in: source)!]) }
        let (svc, ids, arg, mgr) = (group(1), group(2), group(3), group(4))
        let replacement =
            "\(svc).resolveWithRetry(\(ids),(async \(arg)=>{let __r=await \(mgr).default.getGlobalIdsFromUserIds(\(arg))||{};" +
            "const __m=\(arg).filter(__i=>!__r[__i]),__f=window.__swzGlobalIdFallback;" +
            "if(__m.length&&typeof __f===\"function\")try{__r=Object.assign({},__r,await __f(__m))}catch(__e){}return __r}))"
        var out = source
        out.replaceSubrange(Range(m.range, in: source)!, with: replacement)
        return Data(out.utf8)
    }

    /// The sub-worker bundle keeps its webpack `require` private; the prelude needs it to finish the
    /// worker's database-client setup (see `workerPrelude`). Adds `self.__swReq = <require>` in front of
    /// the runtime's `<require>.e = function (chunkId) { var promises = [], installedChunkData = … }`.
    /// Only patches when the shape is unambiguous (single occurrence, plain identifier, statement
    /// boundary before it); otherwise the original bytes are served and the fact is logged.
    static func exposeWebpackRequire(in data: Data) -> Data {
        let tail = Data("=function(e){var t=[],n=a[e]".utf8)
        func unpatched(_ why: String) -> Data {
            hostLog.error("sync-v2-sub-worker served unpatched: \(why, privacy: .public)")
            Task { @MainActor in EngineLog.shared.write("host: sync-v2-sub-worker served unpatched (\(why)) — DAL imports may fail") }
            return data
        }
        guard let range = data.range(of: tail) else { return unpatched("runtime shape not found") }
        if data.range(of: tail, in: range.upperBound..<data.endIndex) != nil { return unpatched("runtime shape ambiguous") }
        // `<ident>.e=function…`: walk back over the identifier, expecting ".e" right before the match.
        let start = data.startIndex
        guard range.lowerBound - 2 >= start,
              data[range.lowerBound - 1] == UInt8(ascii: "e"), data[range.lowerBound - 2] == UInt8(ascii: ".") else {
            return unpatched("no .e accessor")
        }
        func isIdent(_ c: UInt8) -> Bool {
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c == 0x24
        }
        var identStart = range.lowerBound - 2
        while identStart > start, isIdent(data[identStart - 1]) { identStart -= 1 }
        guard identStart < range.lowerBound - 2, !(data[identStart] >= 0x30 && data[identStart] <= 0x39),
              identStart > start, data[identStart - 1] == UInt8(ascii: "}") || data[identStart - 1] == UInt8(ascii: ";") else {
            return unpatched("not at a statement boundary")
        }
        let ident = String(decoding: data[identStart..<(range.lowerBound - 2)], as: UTF8.self)
        var out = data
        out.insert(contentsOf: Data("self.__swReq=\(ident);".utf8), at: identStart)
        return out
    }

    /// Prepended to `dal-worker*.js`: finishes the sub-worker's DB-client setup (below) and forwards uncaught errors, console warnings/errors and
    /// IndexedDB request/transaction failures (name + message, no record data) to the page
    /// (`network-shim.js` logs `__zhostLog` messages).
    static let workerPrelude: String = {
        var script = workerPreludeBase
        #if DEBUG
        script = script.replacingOccurrences(of: "/*DEBUG_EVAL*/", with: workerDebugEval)
        #endif
        return script
    }()

    static let workerDebugEval = """
      // Debug builds: a probe worker created from the dev eval channel can run code in this scope.
      self.addEventListener('message', async (e) => {
        const d = e.data;
        if (!d || typeof d !== 'object' || typeof d.__zhostEval !== 'string') return;
        e.stopImmediatePropagation();
        try { const r = await (0, eval)(d.__zhostEval); self.postMessage({ __zhostEvalResult: JSON.stringify(r === undefined ? null : r) }); }
        catch (err) { self.postMessage({ __zhostEvalResult: JSON.stringify({ error: errText(err) }) }); }
      });
    """

    static let workerPreludeBase = """
    (() => {
      const fwd = (k, v) => { try { self.postMessage({ __zhostLog: k + ' ' + String(v).slice(0, 300) }); } catch {} };
      self.__zhostFwd = fwd;
      /*DEBUG_EVAL*/
      const errText = (e) => e ? (e.name || '') + ': ' + (e.message || e) : String(e);
      self.addEventListener('error', (e) => fwd('error', e.message));
      self.addEventListener('unhandledrejection', (e) => fwd('unhandledrejection', errText(e.reason)));
      for (const lvl of ['warn', 'error']) { const o = console[lvl]; console[lvl] = (...a) => { fwd('console.' + lvl, a.map((x) => x instanceof Error ? errText(x) : (typeof x === 'string' ? x : '')).join(' ')); return o.apply(console, a); }; }
      // The sync-v2 sub-worker writes imported messages through its "lite IDB" path, whose
      // encryption-state store needs the DB client (`database-manager.createQueryBuilder`).
      // Zalo's own SQLite-migrated clients never take this path and nothing in a web worker
      // creates the client (Application lifecycle is unsupported there), so create it once after
      // the sub-worker script has loaded — through its official singleton accessor.
      const ensureDatabaseClient = () => {
        try {
          const req = self.__swReq;
          if (!req || !req.c) { fwd('webpack require not exposed', ''); return; }
          for (const id of Object.keys(req.c)) {
            try {
              const d = req.c[id] && req.c[id].exports && req.c[id].exports.default;
              if (d && typeof d.getInstance === 'function' && String(d.getInstance).includes('createQueryBuilder')) { d.getInstance(); fwd('database client ready', id); return; }
            } catch (e) { /* a throwing export getter must not abort the search */ }
          }
          fwd('database client accessor not found', '');
        } catch (e) { fwd('database client setup failed', errText(e)); }
      };
      if (typeof self.importScripts === 'function') {
        const imp = self.importScripts;
        self.importScripts = function (...urls) { const r = imp.apply(this, urls); if (urls.some((u) => /sync-v2-sub-worker/.test(String(u)))) ensureDatabaseClient(); return r; };
      }
      if (typeof IDBDatabase !== 'undefined') {
        const tx = IDBDatabase.prototype.transaction;
        IDBDatabase.prototype.transaction = function (...a) {
          const t = tx.apply(this, a);
          t.addEventListener('abort', () => fwd('idb-abort', errText(t.error)));
          return t;
        };
        for (const m of ['add', 'put']) {
          const o = IDBObjectStore.prototype[m];
          IDBObjectStore.prototype[m] = function (...a) {
            try { const r = o.apply(this, a); r.addEventListener('error', () => fwd('idb-' + m + '-error', this.name + ' ' + errText(r.error))); return r; }
            catch (e) { fwd('idb-' + m + '-throw', this.name + ' ' + errText(e)); throw e; }
          };
        }
        const open = IDBFactory.prototype.open;
        IDBFactory.prototype.open = function (...a) {
          const r = open.apply(this, a);
          r.addEventListener('error', () => fwd('idb-open-error', errText(r.error)));
          r.addEventListener('blocked', () => fwd('idb-open-blocked', ''));
          return r;
        };
      }
    })();

    """

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    private func respond(_ task: any WKURLSchemeTask, url: URL, data: Data, mime: String) {
        let headers = [
            "Content-Type": mime,
            "Content-Length": "\(data.count)",
            "Access-Control-Allow-Origin": "*",
            "Cache-Control": "no-cache",
        ]
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!)
        task.didReceive(data)
        task.didFinish()
    }

    static func mime(for path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "js", "jsapi": return "text/javascript; charset=utf-8"
        case "wasm": return "application/wasm"
        case "json": return "application/json"
        case "html": return "text/html; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        default: return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        }
    }
}

// MARK: - Console / error capture

private final class ConsoleHandler: NSObject, WKScriptMessageHandler {
    static let name = "zlog"
    static let script = """
    (() => {
      const post = (lvl, a) => { try { webkit.messageHandlers.zlog.postMessage(lvl + ' ' + a.map(x => { try { return typeof x === 'string' ? x : (x instanceof Error ? x.message + ' | ' + (x.stack || '').split('\\n').slice(0, 3).join(' < ') : JSON.stringify(x)); } catch { return String(x); } }).join(' ').slice(0, 1200)); } catch {} };
      for (const lvl of ['log','warn','error','info']) { const o = console[lvl]; console[lvl] = (...a) => { post('[' + lvl + ']', a); return o.apply(console, a); }; }
      addEventListener('error', e => post('[uncaught]', [e.message + ' @ ' + e.filename + ':' + e.lineno + ':' + e.colno]));
      addEventListener('unhandledrejection', e => post('[unhandled]', [e.reason instanceof Error ? e.reason : (() => { try { const j = JSON.stringify(e.reason, (k, v) => typeof v === 'string' && v.length > 60 ? v.slice(0, 60) + '…' : v); return j && j !== '{}' ? j.slice(0, 400) : String(e.reason); } catch { return String(e.reason); } })()]));
    })();
    """
    var sink: ((String) -> Void)?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let line = "\(message.body)"
        hostLog.debug("\(line, privacy: .private)")
        sink?(line)
    }
}

private final class StateHandler: NSObject, WKScriptMessageHandler {
    static let name = "zstate"
    var sink: (([String: Any]) -> Void)?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let state = message.body as? [String: Any] { sink?(state) }
    }
}
