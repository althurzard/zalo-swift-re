import Foundation
import os

private let fpLog = Logger(subsystem: "app.olaz", category: "fingerprint")

/// Performs Olaz's network requests through `olaz-fingerprint-helper`, so that the TLS and
/// HTTP/2 fingerprints of every connection are Chromium 108's — the official Zalo PC client's
/// (Electron 22.3.9) — instead of Apple's. See `FingerprintHelper/` and
/// `reanalysis/wire-fingerprint.md`.
///
/// The helper is a child process speaking the protocol documented in
/// `FingerprintHelper/protocol.go` over a unix socket. Callers fall back to the URLSession
/// paths only on `.unavailable`/`.connectionLost`; an upstream failure (timeout, HTTP error)
/// is a real result and is reported, not retried on the other stack — a retry that switched
/// fingerprint would be exactly what this class exists to avoid.
@MainActor
final class FingerprintProxy {
    static let shared = FingerprintProxy()

    struct Request {
        var method = "GET"
        var url: URL
        /// Sent in this order (Chromium sends JS-set headers before its own defaults).
        var headers: [(String, String)] = []
        var body: Data?
        var timeoutMs = 0
        var stream = false
        var follow = true
        var maxBytes: Int64 = 0
        var idleMs = 30_000
        var firstByteMs = 0
    }

    struct ResponseHead {
        var status: Int
        var statusText: String
        var headers: [(String, String)]
        var url: String
    }

    struct Response {
        var head: ResponseHead
        var body: Data
    }

    enum WSEvent {
        case text(String)
        case binary(Data)
        case closed(code: Int, reason: String)
        case error(String)
    }

    enum Error: Swift.Error {
        /// The helper is not running (and could not be started). Fall back.
        case unavailable(String)
        /// The socket died mid-request. Fall back for this request.
        case connectionLost(String)
        /// The upstream request itself failed — a real result, do not fall back.
        case requestFailed(String, status: Int)
        case tooLarge
    }

    private enum State {
        case idle
        case starting(Task<Connection?, Never>)
        case ready(Connection)
        case failed(String, retryAt: Date)
    }

    private var state: State = .idle
    private var process: Process?
    private var restartAttempts = 0
    /// Events for open websockets, by session id ("w<NetworkProxy id>").
    private var webSocketHandlers: [String: ((WSEvent) -> Void)] = [:]

    private init() {}

    // MARK: Lifecycle

    /// Starts the helper now if it is not running; call early (engine boot) so the first
    /// request does not wait for it.
    func warmUp() {
        Task { _ = await connection() }
    }

    private var helperURL: URL? {
        var candidates: [URL] = []
        if let executable = Bundle.main.executableURL {
            candidates.append(executable.deletingLastPathComponent().appendingPathComponent("olaz-fingerprint-helper"))
        }
        // Dev runs (`swift run`): the binary the build script leaves in the repo.
        candidates.append(URL(fileURLWithPath: #filePath) // …/Sources/Olaz/ZaloRuntime/FingerprintProxy.swift
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("FingerprintHelper/build/olaz-fingerprint-helper"))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func connection() async -> Connection? {
        switch state {
        case .ready(let connection):
            return connection
        case .starting(let task):
            return await task.value
        case .failed(_, let retryAt) where retryAt > Date():
            return nil
        case .idle, .failed:
            let task = Task { await start() }
            state = .starting(task)
            let connection = await task.value
            if case .starting = state {
                state = connection != nil
                    ? .ready(connection!)
                    : .failed("start failed", retryAt: Date().addingTimeInterval(retryDelay()))
            }
            return connection
        }
    }

    private func retryDelay() -> TimeInterval {
        min(60, pow(2, Double(min(restartAttempts, 6))))
    }

    private func start() async -> Connection? {
        guard let helper = helperURL else {
            fpLog.notice("fingerprint helper not bundled — requests use URLSession")
            return nil
        }
        let socketDirectory = URL(fileURLWithPath: ZaloPlatform.defaultUserData.path) // …/Olaz/ZaloData
            .deletingLastPathComponent()                                          // …/Olaz
        try? FileManager.default.createDirectory(at: socketDirectory, withIntermediateDirectories: true)
        sweepStaleSockets(in: socketDirectory)
        let socketPath = socketDirectory
            .appendingPathComponent("fp-helper-\(Int(ProcessInfo.processInfo.processIdentifier))-\(UUID().uuidString.prefix(8)).sock")
            .path

        let process = Process()
        process.executableURL = helper
        process.arguments = ["-socket", socketPath]
        // The helper outlives requests and must never inherit (or hold open) our own
        // stdout: a `swift test`/`swift run` pipe would wait for it forever.
        process.standardOutput = FileHandle.nullDevice
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        let stderrTail = OSAllocatedUnfairLock(initialState: [String]())
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let text = String(data: handle.availableData, encoding: .utf8) ?? ""
            guard !text.isEmpty else { return }
            stderrTail.withLock { tail in
                tail.append(contentsOf: text.split(separator: "\n").map(String.init).suffix(3))
                if tail.count > 6 { tail.removeFirst(tail.count - 6) }
            }
        }
        do {
            try process.run()
        } catch {
            fpLog.error("fingerprint helper spawn failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        self.process = process

        for _ in 0..<50 where !FileManager.default.fileExists(atPath: socketPath) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard FileManager.default.fileExists(atPath: socketPath), process.isRunning else {
            fpLog.error("fingerprint helper socket never appeared")
            process.terminate()
            return nil
        }
        guard let connection = Connection(path: socketPath) else {
            fpLog.error("fingerprint helper connect failed")
            process.terminate()
            return nil
        }
        connection.onFrame = { [weak self] frame in
            guard let self else { return }
            switch frame {
            case .closed:
                self.helperDied(stderrTail: stderrTail.withLock { $0 })
            case .wsEvent(let session, let event):
                self.handleWebSocketEvent(session, event)
            }
        }
        connection.startReading()
        let profile: String
        do {
            profile = try await withTimeout(seconds: 5) { try await connection.expectHello() }
        } catch {
            fpLog.error("fingerprint helper handshake failed: \(error.localizedDescription, privacy: .public)")
            connection.close()
            process.terminate()
            return nil
        }
        restartAttempts = 0
        fpLog.info("fingerprint helper ready (\(profile, privacy: .public))")
        return connection
    }

    private func helperDied(stderrTail: [String]) {
        let status = process?.terminationStatus.description ?? "?"
        fpLog.error("fingerprint helper exited (status \(status, privacy: .public)) \(stderrTail.joined(separator: " | "), privacy: .public)")
        if case .ready(let connection) = state {
            state = .failed("helper exited", retryAt: Date().addingTimeInterval(retryDelay()))
            connection.failAllPending(Error.connectionLost("helper exited"))
            for (_, handler) in webSocketHandlers { handler(.error("helper exited")) }
            webSocketHandlers.removeAll()
            restartAttempts += 1
        }
        process = nil
    }

    private func sweepStaleSockets(in directory: URL) {
        let fm = FileManager.default
        let stale = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in stale where name.hasPrefix("fp-helper-") && name.hasSuffix(".sock") {
            let pid = name.dropFirst("fp-helper-".count).prefix { $0.isNumber }
            if let pid = Int(pid), pid > 0, kill(pid_t(pid), 0) != 0 {
                try? fm.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }

    /// Ready right now (does not start anything).
    var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    /// Waits for readiness (starting the helper if needed) for at most `seconds`.
    func ready(seconds: Double) async -> Bool {
        guard let connection = try? await withTimeout(seconds: seconds, { await self.connection() }) else { return false }
        return connection.helloReceived.withLock { $0 }
    }

    // MARK: Requests

    /// A complete (non-streaming) request. Throws `.unavailable`/`.connectionLost` when the
    /// helper cannot serve it (fall back), `.requestFailed` when the upstream failed (do not).
    func perform(_ request: Request) async throws -> Response {
        let connection = try await liveConnection()
        let id = UUID().uuidString
        return try await withTaskCancellationHandler {
            try await connection.perform(request, id: id)
        } onCancel: {
            connection.cancel(id)
        }
    }

    /// A streaming request: the response head and the body stream (or a complete response
    /// when the helper did not stream — its no-redirect answer to a 3xx). Cancelling the
    /// consuming task cancels the upstream transfer.
    func stream(_ request: Request) async throws -> StreamStart {
        var streaming = request
        streaming.stream = true
        let connection = try await liveConnection()
        return try await connection.stream(streaming, id: UUID().uuidString)
    }

    private func liveConnection() async throws -> Connection {
        guard let connection = await connection() else {
            throw Error.unavailable("helper not running")
        }
        return connection
    }

    // MARK: WebSockets

    func webSocketOpen(id: Int, url: URL, headers: [(String, String)], protocols: [String]) async throws -> String {
        let connection = try await liveConnection()
        return try await connection.webSocketOpen(session: "w\(id)", url: url, headers: headers, protocols: protocols)
    }

    func webSocketSend(id: Int, text: String) {
        guard case .ready(let connection) = state else { return }
        connection.webSocketSend(session: "w\(id)", kind: "text", payload: Data(text.utf8))
    }

    func webSocketSend(id: Int, data: Data) {
        guard case .ready(let connection) = state else { return }
        connection.webSocketSend(session: "w\(id)", kind: "binary", payload: data)
    }

    func webSocketClose(id: Int, code: Int = 1000) {
        guard case .ready(let connection) = state else { return }
        connection.webSocketClose(session: "w\(id)", code: code)
    }

    func closeAllWebSockets() {
        for id in webSocketHandlers.keys.compactMap({ Int($0.dropFirst()) }) {
            webSocketClose(id: id)
        }
    }

    /// Registers the event handler for a websocket the caller is about to open with `id`.
    func setWebSocketHandler(id: Int, handler: @escaping ((WSEvent) -> Void)) {
        webSocketHandlers["w\(id)"] = handler
    }

    func removeWebSocketHandler(id: Int) {
        webSocketHandlers["w\(id)"] = nil
    }

    private func handleWebSocketEvent(_ session: String, _ event: WSEvent) {
        webSocketHandlers[session]?(event)
        switch event {
        case .closed, .error:
            webSocketHandlers[session] = nil
        default:
            break
        }
    }

    // MARK: Shutdown

    func shutdown() {
        guard case .ready(let connection) = state else { return }
        connection.shutdown()
        state = .failed("shut down", retryAt: .distantFuture)
        process?.terminate()
        process = nil
    }

    // MARK: Timeout helper

    /// Not a task group: a group awaits every child before returning, so a body that ignores cancellation (the
    /// HELLO continuation, a `start` in progress) held the caller past the deadline and `start()` never failed over
    /// to URLSession. Here whichever of body / timer finishes first resumes the caller; the body is cancelled and
    /// left to end on its own (the HELLO wait ends when `start` closes the connection and kills the helper).
    private func withTimeout<T: Sendable>(seconds: Double, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let gate = OSAllocatedUnfairLock<CheckedContinuation<T, Swift.Error>?>(initialState: nil)
        let take: @Sendable () -> CheckedContinuation<T, Swift.Error>? = {
            gate.withLock { pending in
                defer { pending = nil }
                return pending
            }
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Swift.Error>) in
            gate.withLock { $0 = continuation }
            let work = Task {
                let result: Result<T, Swift.Error>
                do { result = .success(try await body()) } catch { result = .failure(error) }
                take()?.resume(with: result)
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                guard let pending = take() else { return }
                work.cancel()
                pending.resume(throwing: Error.unavailable("timeout"))
            }
        }
    }
}
