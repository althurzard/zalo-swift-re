import Foundation
import WebKit
import os

private let netLog = Logger(subsystem: "app.olaz", category: "network")

/// Performs the official renderer's http(s) and ws(s) traffic (see `network-shim.js`).
///
/// Swift owns the transport: one persistent cookie jar, the client user agent,
/// and no CORS (the Electron renderer had none either — it ran from file://).
@MainActor
final class NetworkProxy: NSObject, WKScriptMessageHandlerWithReply {
    static let handlerName = "znet"
    static let websocketOrigin = "file://"

    let session: URLSession
    /// WebSockets use a delegate session so `open` fires on the real handshake.
    private let socketSession: URLSession
    private let socketEvents = WebSocketEvents()
    private var openedSockets: Set<Int> = []
    /// One realtime socket: either the fingerprint helper's session or (fallback) URLSession's.
    enum LiveSocket {
        case urlSession(URLSessionWebSocketTask)
        case helper
    }
    private let userAgent: String
    private var sockets: [Int: LiveSocket] = [:]
    weak var webView: WKWebView?

    /// Optional observer for diagnostics (method, url, status).
    var onRequestCompleted: ((String, URL, Int) -> Void)?
    /// Observes response bodies for selected URLs (e.g. the QR login long-polls).
    var responseObserver: ((URL, Int, Data) -> Void)?
    /// Realtime-channel diagnostics: lifecycle + frame headers only (never payloads).
    var socketTrace: ((String) -> Void)?
    private var frameCounts: [Int: Int] = [:]

    /// Zalo realtime frames start with `[version u8][cmd u16 LE][subCmd u8]`.
    private func describeFrame(_ data: Data) -> String {
        guard data.count >= 4 else { return "len=\(data.count)" }
        let b = [UInt8](data.prefix(4))
        let cmd = Int(b[1]) | Int(b[2]) << 8
        return "v=\(b[0]) cmd=\(cmd) sub=\(b[3]) len=\(data.count)"
    }

    private func traceFrame(_ id: Int, _ direction: String, _ data: Data) {
        let n = frameCounts[id, default: 0] + 1
        frameCounts[id] = n
        if n <= 80 { socketTrace?("ws#\(id) \(direction) \(describeFrame(data))") }
    }

    init(userAgent: String, cookieStorage: HTTPCookieStorage = .shared) {
        self.userAgent = userAgent
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = cookieStorage
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        session = URLSession(configuration: config)
        socketSession = URLSession(configuration: config, delegate: socketEvents, delegateQueue: nil)
        super.init()
        socketEvents.onOpen = { [weak self] taskID, proto in
            Task { @MainActor in self?.socketDidOpen(taskID: taskID, protocol: proto) }
        }
        socketEvents.onClose = { [weak self] taskID, code, reason in
            Task { @MainActor in self?.socketDidClose(taskID: taskID, code: code, reason: reason) }
        }
    }

    private func socketID(forTask taskID: Int) -> Int? {
        sockets.first { entry in
            if case .urlSession(let task) = entry.value { return task.taskIdentifier == taskID }
            return false
        }?.key
    }

    private func socketDidOpen(taskID: Int, protocol proto: String?) {
        guard let id = socketID(forTask: taskID) else { return }
        openedSockets.insert(id)
        socketTrace?("ws#\(id) handshake ok")
        emit(id, "open", ["protocol": proto ?? ""])
    }

    private func socketDidClose(taskID: Int, code: Int, reason: String) {
        guard let id = socketID(forTask: taskID) else { return }
        sockets.removeValue(forKey: id)
        openedSockets.remove(id)
        socketTrace?("ws#\(id) closed by server code=\(code) reason=\(reason.prefix(80))")
        emit(id, "close", ["code": code, "reason": reason, "wasClean": true])
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        guard let body = message.body as? [String: Any], let op = body["op"] as? String else {
            replyHandler(nil, "bad message")
            return
        }
        switch op {
        case "http":
            Task { replyHandler(await self.performHTTP(body), nil) }
        case "ws.open":
            openSocket(body)
            replyHandler(nil, nil)
        case "ws.send":
            sendSocket(body)
            replyHandler(nil, nil)
        case "ws.close":
            closeSocket(body)
            replyHandler(nil, nil)
        default:
            replyHandler(nil, "unknown op \(op)")
        }
    }

    // MARK: HTTP

    private func performHTTP(_ body: [String: Any]) async -> [String: Any] {
        guard let urlString = body["url"] as? String, let url = URL(string: urlString) else {
            return ["error": "bad url"]
        }
        var request = URLRequest(url: url)
        request.httpMethod = body["method"] as? String ?? "GET"
        if let timeout = (body["timeout"] as? NSNumber)?.doubleValue, timeout > 0 {
            request.timeoutInterval = timeout / 1000
        }
        for (key, value) in body["headers"] as? [String: String] ?? [:] {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let encoded = body["body"] as? [String: Any] {
            Self.apply(encoded, to: &request)
        }
        Self.applyClientHeaders(to: &request)

        // The fingerprint helper first: Chromium 108's TLS + HTTP/2 instead of Apple's.
        // Only helper-unavailability falls through to URLSession; an upstream failure is a
        // real answer (retrying it on the other stack would change the fingerprint).
        if await FingerprintProxy.shared.ready(seconds: 3) {
            do {
                return try await performViaHelper(request: request, url: url)
            } catch FingerprintProxy.Error.unavailable, FingerprintProxy.Error.connectionLost {
                netLog.error("fingerprint helper unavailable — this request uses URLSession")
            } catch FingerprintProxy.Error.tooLarge {
                return ["error": "body too large"]
            } catch let FingerprintProxy.Error.requestFailed(message, status) {
                let timedOut = status == 0 && message.lowercased().contains("timeout")
                onRequestCompleted?(request.httpMethod ?? "GET", url, -1)
                return ["error": message, "timedOut": timedOut]
            } catch is CancellationError {
                return ["error": "cancelled"]
            } catch {
                return ["error": error.localizedDescription]
            }
        }

        do {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            var headers: [String: String] = [:]
            for (k, v) in http?.allHeaderFields ?? [:] {
                headers[String(describing: k).lowercased()] = String(describing: v)
            }
            let status = http?.statusCode ?? 200
            onRequestCompleted?(request.httpMethod ?? "GET", url, status)
            responseObserver?(url, status, data)
            return [
                "status": status,
                "statusText": HTTPURLResponse.localizedString(forStatusCode: status),
                "headers": headers,
                "url": response.url?.absoluteString ?? urlString,
                "body": data.base64EncodedString(),
            ]
        } catch let error as URLError {
            netLog.error("\(request.httpMethod ?? "GET", privacy: .public) \(url.host() ?? "", privacy: .public)\(url.path(), privacy: .public) failed: \(error.code.rawValue)")
            onRequestCompleted?(request.httpMethod ?? "GET", url, -error.code.rawValue)
            return ["error": error.localizedDescription, "timedOut": error.code == .timedOut]
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    /// One request through the fingerprint helper. Cookies: attached from (and Set-Cookie
    /// harvested into) the shared jar, which is what URLSession did implicitly.
    private func performViaHelper(request: URLRequest, url: URL) async throws -> [String: Any] {
        var helperRequest = FingerprintProxy.Request(url: url)
        helperRequest.method = request.httpMethod ?? "GET"
        helperRequest.body = request.httpBody
        let timeout = request.timeoutInterval
        if timeout > 0, timeout < 600 {
            helperRequest.timeoutMs = Int(timeout * 1000)
        }
        // Chromium order: the page's headers, then the browser's defaults, then cookies.
        var headers: [(String, String)] = request.allHTTPHeaderFields?.map { ($0.key, $0.value) } ?? []
        for name in ["User-Agent", "sec-ch-ua", "sec-ch-ua-mobile", "sec-ch-ua-platform",
                     "sec-fetch-dest", "sec-fetch-mode", "sec-fetch-site",
                     "accept-language", "accept-encoding"] where request.value(forHTTPHeaderField: name) == nil {
            headers.append((name, Self.defaultValue(for: name)))
        }
        if let cookies = HTTPCookieStorage.shared.cookies(for: url), !cookies.isEmpty {
            for (name, value) in HTTPCookie.requestHeaderFields(with: cookies) {
                headers.append((name, value))
            }
        }
        helperRequest.headers = headers

        let response = try await FingerprintProxy.shared.perform(helperRequest)
        Self.storeCookies(from: response.head.headers, url: url)
        var responseHeaders: [String: String] = [:]
        for (name, value) in response.head.headers {
            responseHeaders[name.lowercased()] = value
        }
        let status = response.head.status
        onRequestCompleted?(helperRequest.method, url, status)
        responseObserver?(url, status, response.body)
        return [
            "status": status,
            "statusText": response.head.statusText.isEmpty
                ? HTTPURLResponse.localizedString(forStatusCode: status) : response.head.statusText,
            "headers": responseHeaders,
            "url": response.head.url.isEmpty ? url.absoluteString : response.head.url,
            "body": response.body.base64EncodedString(),
        ]
    }

    /// The captured default for a Chromium header the page did not set (see `applyClientHeaders`).
    private static func defaultValue(for name: String) -> String {
        switch name {
        case "User-Agent": return ClientFingerprint.userAgent
        case "sec-ch-ua": return ClientFingerprint.secCHUA
        case "sec-ch-ua-mobile": return ClientFingerprint.secCHUAMobile
        case "sec-ch-ua-platform": return ClientFingerprint.secCHUAPlatform
        case "sec-fetch-dest": return "empty"
        case "sec-fetch-mode": return "cors"
        case "sec-fetch-site": return "cross-site"
        case "accept-language": return ClientFingerprint.acceptLanguage()
        case "accept-encoding": return ClientFingerprint.acceptEncoding
        default: return ""
        }
    }

    /// `Set-Cookie` lines of a helper response → the shared cookie jar (http(s) only, like
    /// URLSession did implicitly). The helper delivers each Set-Cookie as its own header.
    private static func storeCookies(from headers: [(String, String)], url: URL) {
        guard url.scheme?.lowercased() == "https" || url.scheme?.lowercased() == "http" else { return }
        for (name, value) in headers where name.lowercased() == "set-cookie" {
            if let cookie = cookie(fromSetCookie: value, url: url) {
                HTTPCookieStorage.shared.setCookie(cookie)
            }
        }
    }

    /// RFC 6265 §5.2 for the attribute set Zalo's servers emit (`name=value; Domain; Path;
    /// Expires; Max-Age; Secure; HttpOnly; SameSite`). The SDK's cookie-from-header-fields
    /// helper is gone on this toolchain, and `HTTPCookie(properties:)` still does the storage
    /// semantics (domain vs host-only cookies) this app relies on.
    static func cookie(fromSetCookie value: String, url: URL) -> HTTPCookie? {
        let parts = value.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let pair = parts.first, let equals = pair.firstIndex(of: "=") else { return nil }
        let name = String(pair[..<equals]).trimmingCharacters(in: .whitespaces)
        let cookieValue = String(pair[pair.index(after: equals)...])
        guard !name.isEmpty else { return nil }
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: cookieValue,
            .path: "/",
            .domain: url.host() ?? "",
        ]
        for attribute in parts.dropFirst() {
            let pieces = attribute.split(separator: "=", maxSplits: 1).map(String.init)
            switch pieces[0].lowercased() {
            case "domain" where pieces.count > 1 && !pieces[1].isEmpty:
                // A leading dot is what makes a domain (not host-only) cookie.
                properties[.domain] = pieces[1].hasPrefix(".") ? pieces[1] : "." + pieces[1]
            case "path" where pieces.count > 1 && !pieces[1].isEmpty:
                properties[.path] = pieces[1]
            case "expires" where pieces.count > 1:
                if let date = expiresDate(pieces[1]) { properties[.expires] = date }
            case "max-age" where pieces.count > 1:
                if let seconds = Int(pieces[1]) { properties[.maximumAge] = seconds }
            case "secure":
                properties[.secure] = "TRUE"
            case "httponly":
                break // HTTPCookiePropertyKey cannot represent it; irrelevant for an in-process jar
            case "samesite" where pieces.count > 1:
                switch pieces[1].lowercased() {
                case "none": properties[.sameSitePolicy] = "none"
                case "lax": properties[.sameSitePolicy] = "lax"
                case "strict": properties[.sameSitePolicy] = "strict"
                default: break
                }
            default:
                break
            }
        }
        return HTTPCookie(properties: properties)
    }

    private static let expiresFormats: [String] = [
        "EEE, dd MMM yyyy HH:mm:ss zzz",     // RFC 1123 (what Zalo sends)
        "EEE, dd MMM yyyy HH:mm:ss 'GMT'",
        "EEEE, dd-MMM-yy HH:mm:ss zzz",      // RFC 850
        "EEE MMM d HH:mm:ss yyyy",            // asctime
    ]

    private static func expiresDate(_ text: String) -> Date? {
        for format in expiresFormats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    /// Chromium's own multipart boundary: `----WebKitFormBoundary` + 16 chars of `[0-9A-Za-z]`
    /// (Blink's `MultiPartBody` alphabet). The label is server-visible, so it must be the
    /// official client's, not a Zalo-recognisable one of ours.
    private nonisolated static let boundaryAlphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
    nonisolated static func chromiumFormBoundary() -> String {
        "----WebKitFormBoundary" + String((0..<16).map { _ in boundaryAlphabet.randomElement()! })
    }

    /// Headers Chromium 108 adds to every renderer request, which URLSession does not send at all
    /// (and whose own Accept-Language/Accept-Encoding formats differ from Chromium's). The official
    /// client sent exactly these on its API XHRs — notably **no** `Origin` and no `Referer`.
    /// Values: `reanalysis/wire-fingerprint.md`.
    nonisolated static func applyClientHeaders(to request: inout URLRequest) {
        func setDefault(_ name: String, _ value: String) {
            if request.value(forHTTPHeaderField: name) == nil { request.setValue(value, forHTTPHeaderField: name) }
        }
        setDefault("sec-ch-ua", ClientFingerprint.secCHUA)
        setDefault("sec-ch-ua-mobile", ClientFingerprint.secCHUAMobile)
        setDefault("sec-ch-ua-platform", ClientFingerprint.secCHUAPlatform)
        setDefault("sec-fetch-dest", "empty")
        setDefault("sec-fetch-mode", "cors")
        setDefault("sec-fetch-site", "cross-site")
        setDefault("accept-language", ClientFingerprint.acceptLanguage())
        setDefault("accept-encoding", ClientFingerprint.acceptEncoding)
    }

    private static func apply(_ encoded: [String: Any], to request: inout URLRequest) {
        func setDefaultContentType(_ value: String) {
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue(value, forHTTPHeaderField: "Content-Type")
            }
        }
        if let contentType = encoded["contentType"] as? String { setDefaultContentType(contentType) }
        switch encoded["kind"] as? String {
        case "text":
            request.httpBody = Data((encoded["text"] as? String ?? "").utf8)
            setDefaultContentType("text/plain;charset=UTF-8")
        case "base64":
            request.httpBody = Data(base64Encoded: encoded["data"] as? String ?? "")
        case "formdata":
            let boundary = Self.chromiumFormBoundary()
            var data = Data()
            for part in encoded["parts"] as? [[String: Any]] ?? [] {
                let name = part["name"] as? String ?? ""
                data.append(Data("--\(boundary)\r\n".utf8))
                if let filename = part["filename"] as? String {
                    data.append(Data("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".utf8))
                    data.append(Data("Content-Type: \(part["type"] as? String ?? "application/octet-stream")\r\n\r\n".utf8))
                    data.append(Data(base64Encoded: part["data"] as? String ?? "") ?? Data())
                } else {
                    data.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
                    data.append(Data((part["value"] as? String ?? "").utf8))
                }
                data.append(Data("\r\n".utf8))
            }
            data.append(Data("--\(boundary)--\r\n".utf8))
            request.httpBody = data
            // multipart always overrides whatever the page guessed
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        default:
            break
        }
    }

    // MARK: WebSocket

    private func openSocket(_ body: [String: Any]) {
        guard let id = (body["id"] as? NSNumber)?.intValue,
              let urlString = body["url"] as? String, let url = URL(string: urlString) else { return }
        let params = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? []
        socketTrace?("ws#\(id) open \(url.host() ?? "")\(url.path()) params=\(params) open-sockets=\(sockets.count)")
        let protocols = body["protocols"] as? [String] ?? []
        // The fingerprint helper (Chromium's TLS on the upgrade) when it is up; a short wait
        // covers the engine-boot race where the page's first socket opens while it starts.
        Task {
            if await FingerprintProxy.shared.ready(seconds: 3) {
                self.openSocketViaHelper(id: id, url: url, protocols: protocols)
            } else {
                self.openSocketViaURLSession(id: id, url: url, protocols: protocols)
            }
        }
    }

    private func webSocketUpgradeHeaders(url: URL) -> [(String, String)] {
        var headers: [(String, String)] = [("User-Agent", userAgent)]
        // Browsers always send Origin on the upgrade; the Electron renderer was a
        // file:// page, which Chromium serialises as "file://".
        headers.append(("Origin", Self.websocketOrigin))
        // Cookie matching is scheme-based (http/https); attach the session cookies
        // (zpw_sek …) to the wss upgrade explicitly, as Chromium does.
        var httpsComponents = URLComponents(url: url, resolvingAgainstBaseURL: false)
        httpsComponents?.scheme = url.scheme == "ws" ? "http" : "https"
        if let cookieURL = httpsComponents?.url,
           let cookies = session.configuration.httpCookieStorage?.cookies(for: cookieURL), !cookies.isEmpty {
            headers.append(contentsOf: HTTPCookie.requestHeaderFields(with: cookies).map { ($0.key, $0.value) })
            socketTrace?("attaching \(cookies.count) cookies: \(cookies.map(\.name).sorted())")
        }
        return headers
    }

    private func openSocketViaHelper(id: Int, url: URL, protocols: [String]) {
        guard sockets[id] == nil else { return }
        let headers = webSocketUpgradeHeaders(url: url)
        sockets[id] = .helper
        FingerprintProxy.shared.setWebSocketHandler(id: id) { [weak self] event in
            self?.handleHelperSocketEvent(id, event)
        }
        Task {
            do {
                let negotiated = try await FingerprintProxy.shared.webSocketOpen(id: id, url: url, headers: headers, protocols: protocols)
                guard case .helper? = sockets[id] else { FingerprintProxy.shared.webSocketClose(id: id); return }
                openedSockets.insert(id)
                socketTrace?("ws#\(id) helper handshake ok (protocol \(negotiated))")
                emit(id, "open", ["protocol": negotiated])
            } catch let FingerprintProxy.Error.requestFailed(message, _) {
                // The upstream refused the upgrade: a real result, like a failed URLSession handshake.
                sockets.removeValue(forKey: id)
                FingerprintProxy.shared.removeWebSocketHandler(id: id)
                socketTrace?("ws#\(id) helper open failed: \(message.prefix(120))")
                emit(id, "error", [:])
                emit(id, "close", ["code": 1006, "reason": "", "wasClean": false])
            } catch {
                // The helper went away mid-open: fall back for this socket.
                guard case .helper? = sockets[id] else { return }
                FingerprintProxy.shared.removeWebSocketHandler(id: id)
                sockets.removeValue(forKey: id)
                socketTrace?("ws#\(id) helper unavailable at open — URLSession")
                openSocketViaURLSession(id: id, url: url, protocols: protocols)
            }
        }
    }

    private func handleHelperSocketEvent(_ id: Int, _ event: FingerprintProxy.WSEvent) {
        switch event {
        case .text(let text):
            emit(id, "text", ["text": text])
        case .binary(let data):
            traceFrame(id, "in ", data)
            emit(id, "binary", ["data": data.base64EncodedString()])
        case .closed(let code, let reason):
            sockets.removeValue(forKey: id)
            openedSockets.remove(id)
            socketTrace?("ws#\(id) closed by server code=\(code) reason=\(reason.prefix(80))")
            emit(id, "close", ["code": code, "reason": reason, "wasClean": code != 1006])
        case .error(let message):
            sockets.removeValue(forKey: id)
            openedSockets.remove(id)
            socketTrace?("ws#\(id) helper error: \(message.prefix(120))")
            emit(id, "error", [:])
            emit(id, "close", ["code": 1006, "reason": "", "wasClean": false])
        }
    }

    private func openSocketViaURLSession(id: Int, url: URL, protocols: [String]) {
        var request = URLRequest(url: url)
        for (name, value) in webSocketUpgradeHeaders(url: url) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if !protocols.isEmpty {
            request.setValue(protocols.joined(separator: ", "), forHTTPHeaderField: "Sec-WebSocket-Protocol")
        }
        let task = socketSession.webSocketTask(with: request)
        task.maximumMessageSize = 64 * 1024 * 1024
        sockets[id] = .urlSession(task)
        task.resume()
        // Reads queue until the handshake completes; `open` comes from the delegate.
        receive(id, task)
    }

    private func receive(_ id: Int, _ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, case .urlSession(task)? = self.sockets[id] else { return }
                switch result {
                case .success(.string(let text)):
                    self.emit(id, "text", ["text": text])
                    self.receive(id, task)
                case .success(.data(let data)):
                    self.traceFrame(id, "in ", data)
                    self.emit(id, "binary", ["data": data.base64EncodedString()])
                    self.receive(id, task)
                case .success:
                    self.receive(id, task)
                case .failure(let error):
                    self.socketFailed(id, error)
                }
            }
        }
    }

    private func socketFailed(_ id: Int, _ error: Error) {
        guard case .urlSession(let task)? = sockets.removeValue(forKey: id) else { return }
        openedSockets.remove(id)
        let code = task.closeCode == .invalid ? 1006 : task.closeCode.rawValue
        let reason = task.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let http = task.response as? HTTPURLResponse
        socketTrace?("ws#\(id) closed code=\(code) reason=\(reason.prefix(80)) http=\(http?.statusCode ?? 0) error=\(error.localizedDescription)")
        if code == 1006 { emit(id, "error", [:]) }
        emit(id, "close", ["code": code, "reason": reason, "wasClean": code != 1006])
        netLog.info("socket \(id) closed \(code): \(error.localizedDescription, privacy: .public)")
    }

    private func sendSocket(_ body: [String: Any]) {
        guard let id = (body["id"] as? NSNumber)?.intValue, let socket = sockets[id] else { return }
        switch socket {
        case .helper:
            if let text = body["text"] as? String {
                FingerprintProxy.shared.webSocketSend(id: id, text: text)
            } else {
                let data = Data(base64Encoded: body["data"] as? String ?? "") ?? Data()
                traceFrame(id, "out", data)
                FingerprintProxy.shared.webSocketSend(id: id, data: data)
            }
        case .urlSession(let task):
            let message: URLSessionWebSocketTask.Message
            if let text = body["text"] as? String {
                message = .string(text)
            } else {
                let data = Data(base64Encoded: body["data"] as? String ?? "") ?? Data()
                traceFrame(id, "out", data)
                message = .data(data)
            }
            task.send(message) { [weak self] error in
                if let error { Task { @MainActor in self?.socketFailed(id, error) } }
            }
        }
    }

    private func closeSocket(_ body: [String: Any]) {
        guard let id = (body["id"] as? NSNumber)?.intValue, let socket = sockets.removeValue(forKey: id) else { return }
        let code = (body["code"] as? NSNumber)?.intValue ?? 1000
        socketTrace?("ws#\(id) closed-by-client code=\(code)")
        switch socket {
        case .helper:
            // Drop the handler first so the helper's WSCLOSED echo is not re-emitted.
            FingerprintProxy.shared.removeWebSocketHandler(id: id)
            FingerprintProxy.shared.webSocketClose(id: id, code: code)
        case .urlSession(let task):
            task.cancel(with: URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure,
                        reason: (body["reason"] as? String).map { Data($0.utf8) })
        }
        emit(id, "close", ["code": code, "reason": body["reason"] as? String ?? "", "wasClean": true])
    }

    func closeAllSockets() {
        for (id, socket) in sockets {
            switch socket {
            case .helper:
                FingerprintProxy.shared.removeWebSocketHandler(id: id)
                FingerprintProxy.shared.webSocketClose(id: id, code: 1001)
            case .urlSession(let task):
                task.cancel(with: .goingAway, reason: nil)
            }
        }
        sockets.removeAll()
    }

    private func emit(_ id: Int, _ type: String, _ payload: [String: Any]) {
        webView?.callAsyncJavaScript(
            "window.__zaloNet && window.__zaloNet.socketEvent(id, type, payload)",
            arguments: ["id": id, "type": type, "payload": payload],
            in: nil, in: .page, completionHandler: nil
        )
    }
}

/// Bridges URLSession WebSocket delegate callbacks (background queue) to the proxy.
private final class WebSocketEvents: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    var onOpen: (@Sendable (Int, String?) -> Void)?
    var onClose: (@Sendable (Int, Int, String) -> Void)?

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        onOpen?(webSocketTask.taskIdentifier, `protocol`)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        onClose?(webSocketTask.taskIdentifier, closeCode.rawValue, reason.flatMap { String(data: $0, encoding: .utf8) } ?? "")
    }
}
