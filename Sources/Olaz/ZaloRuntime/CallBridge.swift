import AppKit
import Foundation
import os

private let callLog = Logger(subsystem: "app.olaz", category: "calls")

/// A running (or fake, in tests) native call helper.
@MainActor
protocol CallProcess: AnyObject {
    var isRunning: Bool { get }
    /// `SIGINT` — what main sends on `killMe`.
    func interrupt()
    /// `SIGTERM` — `child.kill()`.
    func terminate()
    func forceKill()
    var pid: Int32? { get }
}

/// Swift stand-in for the call part of the Electron main process (module "3Zc2" of `main-dist/main.js`,
/// "zcall-v2"): hosts the two UNIX-socket servers the native helper (`ZaloCall`, a Qt app shipped inside
/// Zalo.app) connects to, starts and restarts it, and relays between it and the renderer.
///
///   renderer ──`call-send-to-native` / `call-init`──▶ here ──encrypt, chunk──▶ send socket ──▶ ZaloCall
///   renderer ◀──`call-update` / `call-send-signal` / `call-request` / `call-response-<cmd>`── recv socket ◀── ZaloCall
///
/// Frames in both directions are `hex(AES-128-CBC(json))` terminated by `$` (see `CallTransport.swift`).
/// Payloads carry tokens and ids: only command names are ever logged.
@MainActor
final class CallBridge {
    enum Event: Equatable {
        /// Zalo.app / the helper is missing or could not start.
        case helperUnavailable(String)
        case helperStarted(pid: Int32?)
        /// The helper connected and announced `native-ready`.
        case ready
        case exited(Int32)
        /// Native `update`/`callState` (`free`, `incall`, …).
        case callState(String)
        /// Native `request`/`popup` — the official renderer shows it as a confirm dialog (invisible here).
        case popup(header: String, content: String)
    }

    typealias Spawn = @MainActor (_ recvPath: String, _ sendPath: String, _ onExit: @escaping @MainActor (Int32) -> Void) throws -> any CallProcess

    /// Where Zalo.app keeps the helper (`dirname(exe)/../ZaloHelper.app/Contents/MacOS/ZaloCall`), in Olaz's copy of it.
    nonisolated static func helperExecutable(appURL: URL = OfficialZaloInstall.defaultAppURL) -> URL {
        appURL.appendingPathComponent("Contents/ZaloHelper.app/Contents/MacOS/ZaloCall")
    }

    nonisolated static func isHelperInstalled(appURL: URL = OfficialZaloInstall.defaultAppURL) -> Bool {
        FileManager.default.isExecutableFile(atPath: helperExecutable(appURL: appURL).path)
    }

    // MARK: State (names follow main's module: U, F, L, M, D, P, x)

    private let executable: URL?
    private let socketBase: URL
    private let key: Data
    private let spawn: Spawn
    private let emit: (String, [Any]) -> Void
    private let log: (String) -> Void
    private let verify: (URL) throws -> Void
    private let reapOrphans: () -> Void
    private var reapedOrphans = false

    var onEvent: ((Event) -> Void)?

    private var recvServer: UnixSocketServer?
    private var sendServer: UnixSocketServer?
    private var socketDirectory: URL?
    private(set) var recvPath = ""
    private(set) var sendPath = ""

    private var process: (any CallProcess)?
    private var processToken = UUID()
    /// `L`: the helper has been started and has not exited.
    private(set) var started = false
    /// `M`: restart after the next exit (set by `killMe`).
    private var restartAfterExit = false
    private var shutDown = false
    private var lastUnavailable: String?

    /// `D`: the last `call-init` payload (JSON text), sent on every `native-ready`.
    private var initJSON: String?
    /// `P`: messages (JSON text) waiting for a ready helper.
    private var pending: [String] = []
    /// `U`: connection id of the helper on the send socket.
    private var sendConnection: Int?
    private(set) var nativeReady = false
    var hasSendConnection: Bool { sendConnection != nil }
    private var flushedForReady = false
    private var chunker = CallChunker()
    /// `x`: encrypted chunks waiting for the helper's acknowledgement.
    private var chunkQueue: [String] = []
    /// `F`: a chunk is on the wire; the helper acknowledges by writing anything back.
    private var awaitingAck = false
    private var decoders: [Int: CallFrameDecoder] = [:]
    /// Bumped whenever a helper is started or dropped. Socket connections are tagged with the generation current
    /// when they connected: the late EOF of a previous helper's sockets must not reset the next helper's state.
    private var generation = 0
    private var recvGenerations: [Int: Int] = [:]
    private var sendGenerations: [Int: Int] = [:]
    private(set) var droppedFrames = 0

    static let maxPending = 500

    init(executable: URL? = CallBridge.helperExecutable(),
         socketBase: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
         key: Data = CallTransportCrypto.defaultKey,
         spawn: Spawn? = nil,
         verify: ((URL) throws -> Void)? = nil,
         reapOrphans: (() -> Void)? = nil,
         emit: @escaping (String, [Any]) -> Void,
         log: @escaping (String) -> Void = { callLog.info("\($0, privacy: .public)") }) {
        self.executable = executable
        self.socketBase = socketBase
        self.key = key
        self.spawn = spawn ?? { recv, send, onExit in
            guard let executable else { throw UnixSocketServer.SocketError(message: "ZaloCall not found") }
            return try SystemCallProcess.launch(executable, arguments: [recv, send], log: log, onExit: onExit)
        }
        self.emit = emit
        self.log = log
        self.verify = verify ?? { try CallHelperSignature.verify(executable: $0) }
        self.reapOrphans = reapOrphans ?? {
            if let executable { CallOrphans.reap(helperExecutable: executable) }
        }
    }

    /// pid of the running helper (for bringing its window forward).
    var helperPID: Int32? { process?.pid }

    // MARK: Renderer → main (`ipcMain.on`)

    /// `call-send-to-native`: `_optional` messages are queued without starting the helper; others start it.
    /// `json` is the message exactly as main would `JSON.stringify` it (the preload shim strips `_optional`).
    func sendToNative(json: String, optional: Bool) {
        guard !shutDown else { return }
        if !optional { startNative() }
        deliver(json)
    }

    /// `call-init`: remembered and sent to the helper on every `native-ready`.
    func setInit(json: String?) {
        initJSON = json
    }

    /// Account change: stop the helper and forget everything addressed to the previous account.
    func reset() {
        restartAfterExit = false
        initJSON = nil
        pending.removeAll()
        generation += 1
        if let old = process {
            // Invalidate the pending exit callback: a new login may start a fresh helper right away.
            processToken = UUID()
            process = nil
            started = false
            old.terminate()
            recvServer?.disconnectAll()
            sendServer?.disconnectAll()
            Task { [weak old] in
                try? await Task.sleep(for: .seconds(1))
                if let old, old.isRunning { old.forceKill() }
            }
        }
        resetConnectionState()
    }

    /// App quit (`stop()` in main): kill the helper, close the servers, remove the socket directory.
    func shutdown() {
        shutDown = true
        restartAfterExit = false
        if let process, process.isRunning {
            // SIGTERM, up to ~1 s of grace, then SIGKILL.
            process.terminate()
            for _ in 0..<20 where process.isRunning { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning { process.forceKill() }
        }
        process = nil
        recvServer?.stop()
        sendServer?.stop()
        recvServer = nil
        sendServer = nil
        if let socketDirectory { try? FileManager.default.removeItem(at: socketDirectory) }
        socketDirectory = nil
    }

    /// IPC arguments of `call-send-to-native` / `call-init`: `[json, optional]` from the preload shim
    /// (`HostScripts/call-adapter.js`), or the message object itself when the table-driven preload member ran.
    static func decode(_ args: [Any]) -> (json: String, optional: Bool)? {
        if let json = args.string(0) { return (json, args.bool(1) ?? false) }
        guard var object = args.dict(0) else { return nil }
        // main: `t._optional ? delete t._optional : K()`
        let optional = (object["_optional"] as? NSNumber)?.boolValue ?? false
        if optional { object.removeValue(forKey: "_optional") }
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return (json, optional)
    }

    func handleSendToNative(_ args: [Any]) {
        guard let (json, optional) = Self.decode(args) else { return }
        sendToNative(json: json, optional: optional)
    }

    func handleInit(_ args: [Any]) {
        setInit(json: Self.decode(args)?.json)
    }

    // MARK: Helper process (`K()`)

    func startNative() {
        guard !shutDown else { return }
        if started {
            log("call: native already started")
            return
        }
        guard let executable, FileManager.default.isExecutableFile(atPath: executable.path) else {
            fail("Không tìm thấy trình gọi của Zalo (ZaloHelper.app/Contents/MacOS/ZaloCall). Hãy mở lại ứng dụng để cài lại.")
            return
        }
        // A ZaloCall left behind by a crashed Olaz (its argv points into our dead socket directory).
        if !reapedOrphans {
            reapedOrphans = true
            reapOrphans()
        }
        // Only ever run a helper that is validly signed by Zalo's publisher.
        do { try verify(executable) } catch {
            fail(error.localizedDescription)
            return
        }
        started = true
        generation += 1
        do {
            try prepareSockets()
            let token = UUID()
            processToken = token
            process = try spawn(recvPath, sendPath) { [weak self] status in
                guard let self, self.processToken == token else { return }
                self.processExited(status)
            }
            lastUnavailable = nil
            log("call: native started")
            onEvent?(.helperStarted(pid: process?.pid))
        } catch {
            started = false
            fail("Không khởi động được trình gọi: \(error.localizedDescription)")
        }
    }

    private func fail(_ reason: String) {
        log("call: helper unavailable")
        guard lastUnavailable != reason else { return }
        lastUnavailable = reason
        onEvent?(.helperUnavailable(reason))
    }

    private func processExited(_ status: Int32) {
        log("call: native exit \(status)")
        process = nil
        started = false
        resetConnectionState()
        emit("call-update", ["callState", ["state": "free"]])
        onEvent?(.exited(status))
        if restartAfterExit {
            restartAfterExit = false
            log("call: native restart")
            startNative()
        }
    }

    // MARK: Sockets

    private func prepareSockets() throws {
        guard recvServer == nil || sendServer == nil else { return }
        let directory = try makeSocketDirectory()
        socketDirectory = directory
        recvPath = directory.appendingPathComponent("recv").path
        sendPath = directory.appendingPathComponent("send").path

        let recv = UnixSocketServer(path: recvPath)
        recv.onConnect = { [weak self] id in
            guard let self else { return }
            self.decoders[id] = CallFrameDecoder()
            self.recvGenerations[id] = self.generation
            self.log("call: recv connection")
        }
        recv.onData = { [weak self] id, data in
            // Late bytes of a previous helper's connection are stale.
            guard let self, self.recvGenerations[id] == self.generation else { return }
            self.received(data, from: id)
        }
        recv.onEnd = { [weak self] id in
            guard let self else { return }
            self.decoders[id] = nil
            let ended = self.recvGenerations.removeValue(forKey: id)
            self.log("call: recv end")
            // A connection of a previous helper going away says nothing about the current one
            // (its exit was already handled by `processExited` / `reset`).
            guard ended == self.generation else { return }
            // Another connection of this helper may remain: only the last one going away resets.
            if !self.recvGenerations.values.contains(self.generation) { self.resetConnectionState() }
            self.emit("call-update", ["callState", ["state": "free"]])
        }
        let send = UnixSocketServer(path: sendPath)
        send.onConnect = { [weak self] id in
            guard let self else { return }
            self.log("call: send connection")
            self.sendGenerations[id] = self.generation
            self.sendConnection = id
            // A new connection starts clean: nothing half-sent to a previous helper.
            self.awaitingAck = false
            self.chunkQueue.removeAll()
            self.flushIfReady()
        }
        send.onData = { [weak self] id, _ in
            // Only the helper currently on the send socket acknowledges chunks.
            guard let self, self.sendConnection == id else { return }
            self.acknowledged()
        }
        send.onEnd = { [weak self] id in
            guard let self else { return }
            let ended = self.sendGenerations.removeValue(forKey: id)
            guard self.sendConnection == id, ended == self.generation else { return }
            self.log("call: send end")
            self.resetConnectionState()
            self.emit("call-update", ["callState", ["state": "free"]])
        }
        try recv.start()
        do { try send.start() } catch {
            recv.stop()
            throw error
        }
        recvServer = recv
        sendServer = send
    }

    /// A fresh private directory made with `mkdtemp` (0700, fails when the name exists): `$TMPDIR` is already
    /// per-user; a short `/tmp` name is the fallback when the path would not fit `sockaddr_un`.
    private func makeSocketDirectory() throws -> URL {
        Self.removeStaleDirectories(in: socketBase)
        Self.removeStaleDirectories(in: URL(fileURLWithPath: "/tmp", isDirectory: true))
        let pid = getpid()
        let templates = [socketBase.path + "/olaz-call-\(pid)-XXXXXX", "/tmp/szc-\(pid)-XXXXXX"]
        for template in templates where template.utf8.count + "/recv".utf8.count <= UnixSocketServer.maxPathLength {
            var bytes = Array(template.utf8CString)
            guard mkdtemp(&bytes) != nil else { continue }
            return URL(fileURLWithPath: String(cString: bytes), isDirectory: true)
        }
        throw UnixSocketServer.SocketError(message: "socket path too long")
    }

    /// Directories of Olaz processes that no longer exist (crash / force quit).
    static func removeStaleDirectories(in base: URL) {
        let fm = FileManager.default
        for url in (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [] {
            guard let pid = CallOrphans.ownerPID(ofDirectoryNamed: url.lastPathComponent),
                  pid != getpid(), kill(pid, 0) != 0, errno == ESRCH else { continue }
            // Only our own directories (never follow a link or remove someone else's).
            var info = stat()
            guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else { continue }
            try? fm.removeItem(at: url)
        }
    }

    // MARK: main → helper

    /// Official `O`: before the helper connects to the send socket messages wait (and go out on `native-ready`,
    /// after the init data); once connected they are sent immediately.
    private func deliver(_ json: String) {
        if sendConnection != nil {
            transmit(json)
        } else {
            pending.append(json)
            if pending.count > Self.maxPending { pending.removeFirst(pending.count - Self.maxPending) }
        }
    }

    /// `G(e, t)`: encrypt, split, queue, send one chunk.
    private func transmit(_ json: String) {
        guard let hex = try? CallTransportCrypto.encrypt(json, key: key) else {
            log("call: encrypt failed")
            return
        }
        chunkQueue.append(contentsOf: chunker.chunks(of: hex))
        pump()
    }

    /// `W(e)`: one chunk at a time; the next goes out when the helper writes something back.
    private func pump() {
        guard let id = sendConnection, let server = sendServer, !awaitingAck, !chunkQueue.isEmpty else { return }
        let chunk = chunkQueue.removeFirst()
        awaitingAck = true
        server.write(Data(chunk.utf8), to: id)
    }

    private func acknowledged() {
        awaitingAck = false
        pump()
    }

    /// `native-ready`: send the init data first, then everything that was waiting.
    private func flushIfReady() {
        guard nativeReady, sendConnection != nil, !flushedForReady else { return }
        flushedForReady = true
        if let initJSON {
            log("call: sending init data")
            transmit(initJSON)
        }
        let queued = pending
        pending.removeAll()
        for json in queued { transmit(json) }
    }

    /// `H()`: the connection (and anything half-sent) is gone; queued messages stay for the next helper.
    private func resetConnectionState() {
        sendConnection = nil
        nativeReady = false
        flushedForReady = false
        awaitingAck = false
        chunkQueue.removeAll()
    }

    // MARK: helper → main (`Y` / `z`)

    private func received(_ data: Data, from id: Int) {
        var decoder = decoders[id] ?? CallFrameDecoder()
        var dropped = 0
        let messages = decoder.feed(data, key: key, dropped: &dropped)
        decoders[id] = decoder
        if dropped > 0 {
            droppedFrames += dropped
            log("call: cannot parse payload ×\(dropped)")
        }
        for message in messages { route(message) }
    }

    private func route(_ message: [String: Any]) {
        let type = message["type"] as? String ?? ""
        // `command` is a string for most messages but a number for `sendSignal` (401, 402, …): pass it on as is.
        let rawCommand = message["command"]
        let command = rawCommand as? String
        let data: Any = message["data"] ?? ["__undefined": true]
        let name: Any = rawCommand ?? ["__undefined": true]
        log("call: native → \(type)/\(rawCommand.map { "\($0)" } ?? "-")")
        switch type {
        case "update":
            if command == "native-ready" {
                nativeReady = true
                flushedForReady = false
                onEvent?(.ready)
                flushIfReady()
            } else {
                emit("call-update", [name, data])
                if command == "callState", let state = (message["data"] as? [String: Any])?["state"] as? String {
                    onEvent?(.callState(state))
                }
            }
        case "sendSignal":
            emit("call-send-signal", [name, data])
        case "request":
            if command == "killMe" {
                guard let process else { return }
                restartAfterExit = true
                process.interrupt()
                log("call: kill native")
                escalate(process)
            } else {
                emit("call-request", [name, data])
                if command == "popup", let body = message["data"] as? [String: Any] {
                    onEvent?(.popup(header: body["header"] as? String ?? "", content: body["content"] as? String ?? ""))
                }
            }
        case "response":
            emit("call-response-" + (rawCommand.map { "\($0)" } ?? "undefined"), [data])
        default:
            break
        }
    }

    /// SIGINT is a polite request; make sure the helper really goes (and restarts).
    private func escalate(_ target: any CallProcess) {
        Task { [weak self, weak target] in
            try? await Task.sleep(for: .seconds(3))
            guard let target, self?.process === target, target.isRunning else { return }
            target.terminate()
            try? await Task.sleep(for: .seconds(2))
            if target.isRunning { target.forceKill() }
        }
    }
}

// MARK: - Production process

/// `child_process.spawn(ZaloCall, [recvPath, sendPath])`. stdout / stderr are drained and never logged
/// verbatim; a sanitized last line of stderr is logged on an abnormal exit.
@MainActor
final class SystemCallProcess: CallProcess {
    private let process: Process

    /// stderr is only counted: the helper's output can carry ids and tokens.
    private final class ByteCount: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func add(_ n: Int) { lock.lock(); value += n; lock.unlock() }
        var total: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    static func launch(_ executable: URL, arguments: [String], log: @escaping (String) -> Void,
                       onExit: @escaping @MainActor (Int32) -> Void) throws -> SystemCallProcess {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let errorBytes = ByteCount()
        // Only ever called on the main actor (see below).
        nonisolated(unsafe) let log = log
        nonisolated(unsafe) let onExit = onExit
        // Drain both pipes (a full pipe would block the helper); an empty read means EOF.
        out.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { errorBytes.add(data.count) }
        }
        process.terminationHandler = { finished in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            let status = finished.terminationStatus
            let count = errorBytes.total
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    log("call: native exit status \(status), stderr \(count) bytes")
                    onExit(status)
                }
            }
        }
        try process.run()
        return SystemCallProcess(process: process)
    }

    private init(process: Process) {
        self.process = process
    }

    var isRunning: Bool { process.isRunning }
    var pid: Int32? { process.isRunning ? process.processIdentifier : nil }
    func interrupt() { process.interrupt() }
    func terminate() { process.terminate() }
    func forceKill() { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
}
