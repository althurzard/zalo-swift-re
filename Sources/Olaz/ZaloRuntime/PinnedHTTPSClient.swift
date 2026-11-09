import Foundation
import Network
import Security

/// Minimal HTTP/1.1-over-TLS client that connects to a *given IP* while performing TLS with
/// the original hostname: SNI is the hostname and the server certificate is evaluated with
/// `SecPolicyCreateSSL(true, hostname)` (full chain + hostname validation, not trust-all).
/// Used for the DoH fallback, where URLSession cannot be told to skip DNS.
enum PinnedHTTPSClient {
    typealias Response = HTTPResponseParser.Response

    enum ClientError: Error, LocalizedError {
        case badURL, timedOut
        var errorDescription: String? {
            switch self {
            case .badURL: "Pinned HTTPS: unsupported URL"
            case .timedOut: "Pinned HTTPS: timed out"
            }
        }
    }

    /// The client's User-Agent — follows the installed runtime's API version
    /// (`ClientFingerprint.clientVersion`, set at boot).
    static var userAgent: String { ClientFingerprint.userAgent }

    /// GET `url` by connecting to each address in turn until one yields a response.
    /// `timeout` is per address attempt. `clientHeaders` are sent in addition to the
    /// Chromium defaults (media fetches pass the headers the official renderer would send).
    static func get(_ url: URL, addresses: [IPv4Address], timeout: TimeInterval = 10,
                    maxBody: Int = HTTPResponseParser.defaultMaxBody,
                    clientHeaders: [String: String] = [:]) async throws -> Response {
        guard url.scheme == "https", let host = url.host, !host.isEmpty else { throw ClientError.badURL }
        let port = UInt16(url.port ?? 443)
        var lastError: Error = ClientError.badURL
        for address in addresses.shuffled().prefix(4) {
            try Task.checkCancellation()
            do {
                return try await withThrowingTaskGroup(of: Response.self) { group in
                    group.addTask { try await fetch(url, host: host, address: address, port: port, maxBody: maxBody, clientHeaders: clientHeaders) }
                    group.addTask {
                        try await Task.sleep(for: .seconds(timeout))
                        throw ClientError.timedOut
                    }
                    defer { group.cancelAll() }
                    return try await group.next()!
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as HTTPResponseParser.ParseError where error == .tooLarge {
                throw error                              // not an address problem
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Streams the body of a 2xx response into `file` (created/truncated here) instead of buffering it.
    /// There is no total deadline: the transfer fails only when nothing is received for `idleTimeout`
    /// seconds, the body exceeds `maxBody`, the framing is violated, or the task is cancelled. On any
    /// failure `file` is deleted. The returned response carries `bodyLength` but an empty `body`; for
    /// non-2xx statuses (e.g. redirects) the body is discarded and `file` is left empty for the caller to
    /// remove. `progress` receives (bytes of body received, expected total if Content-Length was sent).
    /// Further addresses are tried only while no body byte has been received.
    static func download(_ url: URL, addresses: [IPv4Address], to file: URL,
                         idleTimeout: TimeInterval = 30,
                         maxBody: Int = HTTPResponseParser.defaultMaxBody,
                         clientHeaders: [String: String] = [:],
                         progress: (@Sendable (Int, Int?) -> Void)? = nil) async throws -> Response {
        guard url.scheme == "https", let host = url.host, !host.isEmpty else { throw ClientError.badURL }
        let port = UInt16(url.port ?? 443)
        var lastError: Error = ClientError.badURL
        do {
            for address in addresses.shuffled().prefix(4) {
                try Task.checkCancellation()
                let received = Counter()
                do {
                    guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw ClientError.badURL }
                    let handle = try FileHandle(forWritingTo: file)
                    defer { try? handle.close() }
                    return try await fetch(url, host: host, address: address, port: port, maxBody: maxBody,
                                           sink: handle, idleTimeout: idleTimeout, received: received, progress: progress,
                                           clientHeaders: clientHeaders)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if received.value > 0 { throw error }        // mid-body: do not silently restart elsewhere
                    if let parseError = error as? HTTPResponseParser.ParseError, parseError == .tooLarge { throw error }
                    lastError = error
                }
            }
            throw lastError
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        func set(_ newValue: Int) { lock.lock(); count = newValue; lock.unlock() }
    }

    private static func fetch(_ url: URL, host: String, address: IPv4Address, port: UInt16,
                              maxBody: Int, sink: FileHandle? = nil, idleTimeout: TimeInterval? = nil,
                              received: Counter? = nil,
                              progress: (@Sendable (Int, Int?) -> Void)? = nil,
                              clientHeaders: [String: String] = [:]) async throws -> Response {
        let connection = Connection(host: host, address: address, port: port)
        return try await withTaskCancellationHandler {
            defer { connection.cancel() }
            do {
                connection.armWatchdog(idleTimeout)
                try await connection.start()
                try await connection.send(requestBytes(for: url, host: host, clientHeaders: clientHeaders))
                var parser = HTTPResponseParser(maxBody: maxBody, sink: sink)
                while true {
                    try Task.checkCancellation()
                    connection.armWatchdog(idleTimeout)
                    // A receive error (incl. TLS close without close_notify) is never a clean EOF.
                    let (chunk, isComplete) = try await connection.receive()
                    connection.disarmWatchdog()
                    if let chunk, !chunk.isEmpty {
                        let done = try parser.feed(chunk)
                        received?.set(parser.bodyBytes)
                        if sink != nil, parser.bodyBytes > 0, (200..<300).contains(parser.status) { progress?(parser.bodyBytes, parser.expectedLength) }
                        if done, let response = parser.response { return response }
                    }
                    if isComplete { return try parser.finish() }
                }
            } catch {
                connection.disarmWatchdog()
                if Task.isCancelled { throw CancellationError() }
                if connection.watchdogFired { throw ClientError.timedOut }
                throw error
            }
        } onCancel: {
            connection.cancel()
        }
    }

    private static func requestBytes(for url: URL, host: String, clientHeaders: [String: String]) -> Data {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var target = components?.percentEncodedPath ?? "/"
        if target.isEmpty { target = "/" }
        if let query = components?.percentEncodedQuery { target += "?" + query }
        var hostHeader = host
        if let port = url.port, port != 443 { hostHeader += ":\(port)" }
        var headers = "User-Agent: \(userAgent)\r\n"
        for (name, value) in clientHeaders { headers += "\(name): \(value)\r\n" }
        // `identity`: this client parses the HTTP framing itself and cannot decode gzip/br.
        let text = "GET \(target) HTTP/1.1\r\nHost: \(hostHeader)\r\n\(headers)"
            + "Accept: */*\r\nAccept-Encoding: identity\r\nConnection: close\r\n\r\n"
        return Data(text.utf8)
    }

    // MARK: Connection

    /// NWConnection wrapper: TCP to `address`, TLS with SNI + trust evaluation for `host`.
    private final class Connection: @unchecked Sendable {
        private let connection: NWConnection
        private let queue = DispatchQueue(label: "olaz.pinned-https")
        private let lock = NSLock()
        private var cancelled = false
        private var startContinuation: CheckedContinuation<Void, Error>?
        private var watchdogTimer: DispatchSourceTimer?
        private var deadline: UInt64?          // DispatchTime uptime (ns) after which the connection is torn down
        private var fired = false

        /// True when the idle watchdog (not the caller) tore the connection down.
        var watchdogFired: Bool { lock.lock(); defer { lock.unlock() }; return fired }

        /// (Re)sets the idle deadline to `seconds` from now; nil = no watchdog. This only stores a timestamp
        /// (cheap per received chunk); a single repeating timer, created on first use, compares it.
        func armWatchdog(_ seconds: TimeInterval?) {
            guard let seconds else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            lock.lock()
            deadline = now + UInt64(seconds * 1_000_000_000)
            if watchdogTimer == nil && !cancelled {
                let timer = DispatchSource.makeTimerSource(queue: queue)
                let interval = min(1.0, max(0.05, seconds / 4))
                timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(Int(interval * 250)))
                timer.setEventHandler { [weak self] in self?.checkWatchdog() }
                watchdogTimer = timer
                timer.resume()
            }
            lock.unlock()
        }

        func disarmWatchdog() {
            lock.lock(); deadline = nil; lock.unlock()
        }

        private func checkWatchdog() {
            lock.lock()
            guard let deadline, DispatchTime.now().uptimeNanoseconds >= deadline, !fired else { lock.unlock(); return }
            fired = true
            lock.unlock()
            connection.cancel()
            resumeStart(.failure(ClientError.timedOut))
        }

        init(host: String, address: IPv4Address, port: UInt16) {
            let tls = NWProtocolTLS.Options()
            let options = tls.securityProtocolOptions
            sec_protocol_options_set_tls_server_name(options, host)
            sec_protocol_options_add_tls_application_protocol(options, "http/1.1")
            sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
            sec_protocol_options_set_verify_block(options, { _, trust, complete in
                let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                SecTrustSetPolicies(secTrust, SecPolicyCreateSSL(true, host as CFString))
                var error: CFError?
                complete(SecTrustEvaluateWithError(secTrust, &error))
            }, DispatchQueue(label: "olaz.pinned-https.verify"))
            let tcp = NWProtocolTCP.Options()
            tcp.connectionTimeout = 6
            tcp.noDelay = true
            let parameters = NWParameters(tls: tls, tcp: tcp)
            connection = NWConnection(host: .ipv4(address), port: NWEndpoint.Port(rawValue: port)!, using: parameters)
        }

        private func resumeStart(_ result: Result<Void, Error>) {
            lock.lock()
            let c = startContinuation
            startContinuation = nil
            lock.unlock()
            c?.resume(with: result)
        }

        /// Waits for `.ready`. Safe against cancellation landing before, during or after.
        func start() async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if cancelled || Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                startContinuation = continuation
                lock.unlock()
                connection.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready: self?.resumeStart(.success(()))
                    case .failed(let error): self?.resumeStart(.failure(error))
                    case .waiting(let error): self?.resumeStart(.failure(error))   // fail fast, try next address
                    case .cancelled: self?.resumeStart(.failure(CancellationError()))
                    default: break
                    }
                }
                connection.start(queue: queue)
            }
        }

        func send(_ data: Data) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
            }
        }

        func receive() async throws -> (Data?, Bool) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data?, Bool), Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: (data, isComplete)) }
                }
            }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            deadline = nil
            let timer = watchdogTimer
            watchdogTimer = nil
            lock.unlock()
            timer?.cancel()
            connection.cancel()
            resumeStart(.failure(CancellationError()))    // also covers cancel() before the handler was installed
        }
    }
}
