import Testing
import Foundation
import Darwin
@testable import Olaz

/// zcall-v2 transport: byte-exact against the Node functions of `main-dist/main.js` (modules "vqv6", "4KIH"),
/// then end to end against a fake native helper speaking the protocol over real UNIX sockets.
@Suite struct CallTransportParity {
    // Produced by Node with main's own `encrypt` (aes-128-cbc, key = base64 secret, zero IV) -> hex.
    static let readyPlain = #"{"type": "update", "command": "native-ready"}"#
    static let readyHex = "aa86e40365c48c1c63fe6b0e0ba67b1e6714eff63021aea7244d4a005c2af764eb549f87c9aa3970730fbe89426fdb22"
    static let makeCallPlain = #"{"type":"request","command":"makeCall","data":{"partner":[{"id":"123","name":"Nguyễn Văn Á 😀"}],"type":1}}"#
    static let makeCallHex = "4d8c2a9b25501aa04cb54e198212e58862cba9a3ebf2b085db3fae014058cc44934645a90f7b159785adfa1838e03fe7a31469c518d7a0b38e3753b51a932e02748a204ea14a71609d4cae6c4b61734608756225655836b743a8c3e7a3c175958342d42bdcfab6a5c055b10163783b98a9c38f30385fc2a0d7c812c19ed1944d"

    @Test func encryptMatchesNode() throws {
        #expect(try CallTransportCrypto.encrypt(Self.readyPlain) == Self.readyHex)
        #expect(try CallTransportCrypto.encrypt(Self.makeCallPlain) == Self.makeCallHex)
    }

    @Test func decryptMatchesNode() {
        #expect(CallTransportCrypto.decrypt(Self.readyHex) == Self.readyPlain)
        #expect(CallTransportCrypto.decrypt(Self.makeCallHex) == Self.makeCallPlain)
        // main's decrypt() throws on bad padding / non-hex; so do we (nil).
        #expect(CallTransportCrypto.decrypt("zz") == nil)
        #expect(CallTransportCrypto.decrypt(String(Self.readyHex.dropLast(2))) == nil)
        #expect(CallTransportCrypto.decrypt("") == nil)
    }

    @Test func roundTripLargeUnicode() throws {
        let text = String(repeating: "Xin chào 😀 Zalo — ", count: 500)
        #expect(CallTransportCrypto.decrypt(try CallTransportCrypto.encrypt(text)) == text)
    }

    @Test func keyIsSixteenBytes() {
        #expect(CallTransportCrypto.defaultKey.count == 16)
    }

    @Test func singleChunkIsPayloadAndDollar() {
        var chunker = CallChunker()
        #expect(chunker.chunks(of: "abcd") == ["abcd$"])
        #expect(chunker.chunks(of: String(repeating: "a", count: 4000)) == [String(repeating: "a", count: 4000) + "$"])
        #expect(chunker.chunks(of: "") == ["$"])
    }

    @Test func chunksMatchBuildListMsgs() {
        // Node: build(hex(10112 chars), 77) -> lengths [4009, 4009, 2121], suffixes "#77#3#<i>#$"
        var chunker = CallChunker()
        let payload = String(repeating: "0123456789abcdef", count: 632)   // 10112 chars
        let chunks = chunker.chunks(of: payload, now: Date(timeIntervalSince1970: 0.077))
        #expect(chunks.map(\.count) == [4009, 4009, 2121])
        #expect(chunks[0].hasSuffix("#77#3#0#$"))
        #expect(chunks[1].hasSuffix("#77#3#1#$"))
        #expect(chunks[2].hasSuffix("#77#3#2#$"))
        let rebuilt = chunks.map { String($0.dropLast("#77#3#0#$".count)) }.joined()
        #expect(rebuilt == payload)
        // Sequence is `max(r + 1, Date.now())`: strictly increasing even within one millisecond.
        let next = chunker.chunks(of: payload, now: Date(timeIntervalSince1970: 0.077))
        #expect(next[0].hasSuffix("#78#3#0#$"))
    }

    @Test func decoderHandlesSplitAndJoinedFrames() {
        var decoder = CallFrameDecoder()
        var dropped = 0
        let wire = Data((Self.readyHex + "$" + Self.makeCallHex + "$").utf8)
        // Delivered in awkward pieces: mid-frame cuts, then the rest at once.
        var messages = decoder.feed(wire.prefix(40), dropped: &dropped)
        #expect(messages.isEmpty)
        messages += decoder.feed(wire.dropFirst(40).prefix(100), dropped: &dropped)
        #expect(messages.count == 0 || messages.count == 1)
        messages += decoder.feed(wire.dropFirst(140), dropped: &dropped)
        #expect(messages.count == 2)
        #expect(messages[0]["command"] as? String == "native-ready")
        #expect(messages[1]["command"] as? String == "makeCall")
        #expect(dropped == 0)
    }

    @Test func decoderWaitsForTheTerminator() {
        var decoder = CallFrameDecoder()
        var dropped = 0
        #expect(decoder.feed(Data((Self.readyHex).utf8), dropped: &dropped).isEmpty)
        let messages = decoder.feed(Data("$".utf8), dropped: &dropped)
        #expect(messages.count == 1)
        #expect(messages.first?["type"] as? String == "update")
        // No plaintext fallback: main's decrypt() throws on it.
        #expect(decoder.feed(Data(#"{"type":"update"}$"#.utf8), dropped: &dropped).isEmpty)
        #expect(dropped == 1)
    }

    @Test func decoderDropsGarbageAndKeepsGoing() {
        var decoder = CallFrameDecoder()
        var dropped = 0
        let messages = decoder.feed(Data(("not-hex$" + Self.readyHex + "$$").utf8), dropped: &dropped)
        #expect(messages.count == 1)
        #expect(dropped == 1)
    }

    @Test func decoderStripsNulBytes() throws {
        // main: JSON.parse(plain.replace(/[\0]/g, ""))
        let hex = try CallTransportCrypto.encrypt("{\"type\":\"update\"\0,\"command\":\"x\"}\0")
        var decoder = CallFrameDecoder()
        var dropped = 0
        let messages = decoder.feed(Data((hex + "$").utf8), dropped: &dropped)
        #expect(messages.first?["command"] as? String == "x")
    }

    @Test @MainActor func ipcArgumentsDecode() {
        let a = CallBridge.decode(["{\"a\":1}", true])
        #expect(a?.json == "{\"a\":1}" && a?.optional == true)
        #expect(CallBridge.decode(["{\"a\":1}"])?.optional == false)
        // Structured object (table-driven preload member): `_optional` truthy is stripped, falsy stays.
        let b = CallBridge.decode([["type": "update", "_optional": true] as [String: Any]])
        #expect(b?.optional == true)
        #expect(b?.json.contains("_optional") == false)
        let c = CallBridge.decode([["type": "update", "_optional": false] as [String: Any]])
        #expect(c?.optional == false)
        #expect(c?.json.contains("_optional") == true)
        #expect(CallBridge.decode([]) == nil)
    }

    @Test func socketPathLimit() {
        let long = "/tmp/" + String(repeating: "a", count: 120)
        let server = UnixSocketServer(path: long)
        #expect(throws: (any Error).self) { try server.start() }
    }
}

// MARK: - Fake native helper

/// Plays `ZaloCall`: connects to both sockets, announces `native-ready`, acknowledges every chunk it reads
/// on the send socket, reassembles chunked messages and records them.
final class FakeNative: @unchecked Sendable {
    private let lock = NSLock()
    private var _received: [String] = []
    private var sendFD: Int32 = -1
    private var recvFD: Int32 = -1
    private var stopped = false
    private let ackEveryChunk: Bool
    /// When set, `run` connects the send socket, then waits for this gate before connecting the recv socket.
    var recvGate: DispatchSemaphore?
    private var holdRecv = false

    init(ackEveryChunk: Bool = true) { self.ackEveryChunk = ackEveryChunk }

    var received: [String] { lock.lock(); defer { lock.unlock() }; return _received }
    var isConnected: Bool { lock.lock(); defer { lock.unlock() }; return sendFD >= 0 && recvFD >= 0 }

    private static func connectUnix(_ path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in for (i, b) in path.utf8.enumerated() { raw[i] = b } }
        let result = withUnsafePointer(to: &address) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if result != 0 { close(fd); return -1 }
        return fd
    }

    /// argv[1] = recv path (helper writes to it), argv[2] = send path (helper reads from it).
    func run(recvPath: String, sendPath: String, announceReady: Bool = true) {
        Thread.detachNewThread { [self] in
            let send = Self.connectUnix(sendPath)
            recvGate?.wait()
            let recv = Self.connectUnix(recvPath)
            guard send >= 0, recv >= 0 else { return }
            lock.lock(); sendFD = send; recvFD = recv; lock.unlock()
            if announceReady { sendMessage(CallTransportParity.readyPlain) }
            var pending = Data()
            var parts: [Int: [Int: String]] = [:]
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let n = read(send, &buffer, buffer.count)
                if n <= 0 { break }
                pending.append(contentsOf: buffer[0..<n])
                while let end = pending.firstIndex(of: UInt8(ascii: "$")) {
                    let frame = String(decoding: pending[pending.startIndex..<end], as: UTF8.self)
                    pending.removeSubrange(pending.startIndex...end)
                    if ackEveryChunk { var b: UInt8 = 0x06; _ = write(send, &b, 1) }
                    if let hex = reassemble(frame, &parts), let plain = CallTransportCrypto.decrypt(hex) {
                        lock.lock(); _received.append(plain); lock.unlock()
                    }
                }
            }
            lock.lock(); let hold = holdRecv; lock.unlock()
            close(send)
            if !hold { close(recv) }
        }
    }

    /// `payload` or `payload#seq#count#index#`.
    private func reassemble(_ frame: String, _ parts: inout [Int: [Int: String]]) -> String? {
        guard frame.contains("#") else { return frame }
        let fields = frame.split(separator: "#", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 4 || fields.count == 5, let seq = Int(fields[1]), let count = Int(fields[2]),
              let index = Int(fields[3]) else { return nil }
        parts[seq, default: [:]][index] = fields[0]
        guard parts[seq]?.count == count else { return nil }
        let joined = (0..<count).compactMap { parts[seq]?[$0] }.joined()
        parts[seq] = nil
        return joined
    }

    /// helper → main: `hex(AES(json)) + "$"` on the recv socket.
    func sendMessage(_ json: String) {
        guard let hex = try? CallTransportCrypto.encrypt(json) else { return }
        lock.lock(); let fd = recvFD; lock.unlock()
        guard fd >= 0 else { return }
        let bytes = Array((hex + "$").utf8)
        _ = write(fd, bytes, bytes.count)
    }

    func disconnect(keepRecv: Bool = false) {
        lock.lock()
        holdRecv = keepRecv
        let fds = keepRecv ? [sendFD] : [sendFD, recvFD]
        sendFD = -1
        if !keepRecv { recvFD = -1 }
        lock.unlock()
        for fd in fds where fd >= 0 { shutdown(fd, SHUT_RDWR) }
    }

    /// Late EOF of the recv connection (after `disconnect(keepRecv: true)`).
    func closeRecv() {
        lock.lock(); let fd = recvFD; recvFD = -1; lock.unlock()
        if fd >= 0 { shutdown(fd, SHUT_RDWR) }
    }
}

@MainActor
final class FakeProcess: CallProcess {
    var isRunning = true
    var pid: Int32? { isRunning ? 4242 : nil }
    var interrupted = 0, terminated = 0
    let native: FakeNative
    private let onExit: @MainActor (Int32) -> Void
    /// Exit closes only the send socket; the test closes recv later with `native.closeRecv()`.
    var keepRecvOnExit = false
    init(native: FakeNative, onExit: @escaping @MainActor (Int32) -> Void) { self.native = native; self.onExit = onExit }
    func interrupt() { interrupted += 1; exit(2) }
    func terminate() { terminated += 1; exit(15) }
    func forceKill() { exit(9) }
    func exit(_ status: Int32) {
        guard isRunning else { return }
        isRunning = false
        native.disconnect(keepRecv: keepRecvOnExit)
        DispatchQueue.main.async { MainActor.assumeIsolated { self.onExit(status) } }
    }
}

@MainActor
private final class CallHarness {
    var emitted: [(channel: String, args: [Any])] = []
    var events: [CallBridge.Event] = []
    var processes: [FakeProcess] = []
    var natives: [FakeNative] = []
    var announceReady = true
    var ackEveryChunk = true
    /// Spawn index -> gate holding that helper's recv connection back.
    var recvGates: [Int: DispatchSemaphore] = [:]
    var keepRecvOnExit = false
    var logs: [String] = []
    let base: URL
    let bridge: CallBridge

    var verifyError: Error?
    var reaped = 0

    init(executableExists: Bool = true) {
        // Short path: sockaddr_un holds 103 bytes.
        base = URL(fileURLWithPath: "/tmp/szt-\(UInt32.random(in: 0..<1_000_000))", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var holder: CallHarness?
        var spawn: CallBridge.Spawn?
        spawn = { recv, send, onExit in
            guard let holder else { throw UnixSocketServer.SocketError(message: "gone") }
            let native = FakeNative(ackEveryChunk: holder.ackEveryChunk)
            native.recvGate = holder.recvGates[holder.natives.count]
            holder.natives.append(native)
            native.run(recvPath: recv, sendPath: send, announceReady: holder.announceReady)
            let process = FakeProcess(native: native, onExit: onExit)
            process.keepRecvOnExit = holder.keepRecvOnExit
            holder.processes.append(process)
            return process
        }
        let exe = executableExists ? URL(fileURLWithPath: "/bin/echo") : URL(fileURLWithPath: "/nonexistent/ZaloCall")
        var emitSink: ((String, [Any]) -> Void)?
        bridge = CallBridge(executable: exe, socketBase: base, spawn: spawn,
                            verify: { _ in if let e = holder?.verifyError { throw e } },
                            reapOrphans: { holder?.reaped += 1 }, emit: { emitSink?($0, $1) }, log: { holder?.logs.append($0) })
        holder = self
        emitSink = { [unowned self] channel, args in emitted.append((channel, args)) }
        bridge.onEvent = { [unowned self] in events.append($0) }
    }

    deinit { try? FileManager.default.removeItem(at: base) }

    func wait(_ what: String, timeout: Double = 5, _ condition: () -> Bool) async -> Bool {
        let end = Date.now.addingTimeInterval(timeout)
        while Date.now < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}

@MainActor
@Suite(.serialized) struct CallBridgeEndToEnd {
    @Test func startsHelperQueuesUntilReadyThenSendsInitFirst() async throws {
        let h = CallHarness()
        h.bridge.setInit(json: #"{"type":"update","command":"init","data":{"local":{"id":"1"}}}"#)
        // `_optional` messages never start the helper; they wait for it.
        h.bridge.sendToNative(json: #"{"type":"control","data":{"act":"x"}}"#, optional: true)
        #expect(h.processes.isEmpty)
        // A non-optional message starts it (and goes out after init and the queued control message).
        let big = #"{"type":"request","command":"makeCall","data":{"blob":"\#(String(repeating: "ê", count: 6000))"}}"#
        h.bridge.sendToNative(json: big, optional: false)
        #expect(h.processes.count == 1)

        let native = try #require(h.natives.first)
        let got = await h.wait("3 messages") { native.received.count >= 3 }
        #expect(got)
        let received = native.received
        // `#require`: on a slow machine the wait can time out with fewer messages; fail instead of indexing out of range.
        try #require(received.count == 3)
        #expect(received[0].contains("\"command\":\"init\""))
        #expect(received[1].contains("\"act\":\"x\""))
        #expect(received[2] == big)   // multi-chunk message arrives intact
        #expect(h.events.contains(.helperStarted(pid: 4242)))
        #expect(h.events.contains(.ready))
        // Starting again while running does not spawn a second helper.
        h.bridge.sendToNative(json: #"{"type":"request","command":"endCall","data":null}"#, optional: false)
        #expect(h.processes.count == 1)
        _ = await h.wait("endCall") { native.received.count >= 4 }
        #expect(native.received.last?.contains("endCall") == true)
        h.bridge.shutdown()
    }

    @Test func messagesFlowToTheRenderer() async throws {
        let h = CallHarness()
        h.bridge.sendToNative(json: "{}", optional: false)
        let native = try #require(h.natives.first)
        #expect(await h.wait("ready") { h.events.contains(.ready) })

        native.sendMessage(#"{"type":"update","command":"callState","data":{"state":"incall"}}"#)
        native.sendMessage(#"{"type":"sendSignal","command":401,"data":{"calleeId":"9","callId":"c"}}"#)
        native.sendMessage(#"{"type":"request","command":"serverTime","data":null}"#)
        native.sendMessage(#"{"type":"request","command":"popup","data":{"header":"H","content":"C"}}"#)
        native.sendMessage(#"{"type":"response","command":"listDevice","data":{"autoAudioInput":true}}"#)
        #expect(await h.wait("5 emits") { h.emitted.count >= 5 })
        let channels = h.emitted.map(\.channel)
        #expect(channels == ["call-update", "call-send-signal", "call-request", "call-request", "call-response-listDevice"])
        #expect(h.emitted[0].args[0] as? String == "callState")
        #expect((h.emitted[0].args[1] as? [String: Any])?["state"] as? String == "incall")
        #expect(h.emitted[1].args[0] as? Int == 401)   // numeric command kept numeric
        #expect(h.events.contains(.callState("incall")))
        #expect(h.events.contains(.popup(header: "H", content: "C")))
        h.bridge.shutdown()
    }

    @Test func nativeExitReportsFreeAndKillMeRestarts() async throws {
        let h = CallHarness()
        h.bridge.setInit(json: #"{"type":"update","command":"init","data":{}}"#)
        h.bridge.sendToNative(json: "{}", optional: false)
        let first = try #require(h.natives.first)
        #expect(await h.wait("ready") { h.events.contains(.ready) })

        first.sendMessage(#"{"type":"request","command":"killMe","data":null}"#)
        #expect(await h.wait("restart") { h.processes.count == 2 })
        #expect(h.processes[0].interrupted == 1)
        // The renderer is told the call state is free when the helper goes away.
        let frees = h.emitted.filter { $0.channel == "call-update" && ($0.args.first as? String) == "callState" }
        #expect(!frees.isEmpty)
        // The new helper gets the stored init data on its own native-ready.
        let second = try #require(h.natives.last)
        #expect(await h.wait("second ready") { second.received.contains { $0.contains("\"command\":\"init\"") } })
        h.bridge.shutdown()
    }

    /// Restart ordering seen under load: the new helper's send socket connects *before* the old helper's recv
    /// EOF is delivered (and before the new recv connects). The stale EOF must not reset the new connection.
    @Test func staleRecvEndDoesNotResetTheRestartedHelper() async throws {
        let h = CallHarness()
        h.keepRecvOnExit = true
        let gate = DispatchSemaphore(value: 0)
        h.recvGates[1] = gate
        h.bridge.setInit(json: #"{"type":"update","command":"init","data":{}}"#)
        h.bridge.sendToNative(json: "{}", optional: false)
        let first = try #require(h.natives.first)
        #expect(await h.wait("ready") { h.events.contains(.ready) })

        first.sendMessage(#"{"type":"request","command":"killMe","data":null}"#)
        #expect(await h.wait("restart") { h.processes.count == 2 })
        // New helper is on the send socket, its recv is held back; the old recv is still open.
        #expect(await h.wait("new send connection") { h.bridge.hasSendConnection })
        let recvEnds = h.logs.filter { $0 == "call: recv end" }.count
        first.closeRecv()
        #expect(await h.wait("old recv end") { h.logs.filter { $0 == "call: recv end" }.count > recvEnds })
        #expect(h.bridge.hasSendConnection)

        gate.signal()
        let second = try #require(h.natives.last)
        #expect(await h.wait("second init") { second.received.contains { $0.contains("\"command\":\"init\"") } })
        h.bridge.shutdown()
    }

    @Test func missingHelperFailsGracefully() async {
        let h = CallHarness(executableExists: false)
        h.bridge.sendToNative(json: "{}", optional: false)
        h.bridge.sendToNative(json: "{}", optional: false)
        #expect(h.processes.isEmpty)
        // Reported once, with a user-readable reason.
        let problems = h.events.compactMap { event -> String? in if case .helperUnavailable(let r) = event { r } else { nil } }
        #expect(problems.count == 1)
        #expect(problems.first?.contains("Zalo") == true)
        #expect(!h.bridge.started)
    }

    @Test func resetKillsHelperAndForgetsQueuedMessages() async throws {
        let h = CallHarness()
        h.announceReady = false      // helper connects but never says native-ready
        h.bridge.sendToNative(json: #"{"n":1}"#, optional: false)
        let native = try #require(h.natives.first)
        #expect(await h.wait("connected") { native.isConnected })
        h.bridge.reset()
        #expect(await h.wait("terminated") { h.processes.first?.terminated == 1 })
        #expect(native.received.isEmpty)   // nothing leaked before ready
        h.bridge.shutdown()
    }

    @Test func socketsAreRemovedOnShutdown() async throws {
        let h = CallHarness()
        h.bridge.sendToNative(json: "{}", optional: false)
        let recv = h.bridge.recvPath
        #expect(FileManager.default.fileExists(atPath: recv))
        let mode = (try FileManager.default.attributesOfItem(atPath: recv)[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o600)
        let directoryMode = (try FileManager.default.attributesOfItem(atPath: (recv as NSString).deletingLastPathComponent)[.posixPermissions] as? NSNumber)?.intValue
        #expect(directoryMode == 0o700)
        h.bridge.shutdown()
        #expect(!FileManager.default.fileExists(atPath: recv))
    }

    @Test func staleDirectoriesOfDeadProcessesAreRemoved() throws {
        let base = URL(fileURLWithPath: "/tmp/szt-stale-\(UInt32.random(in: 0..<1_000_000))", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let dead = base.appendingPathComponent("olaz-call-999999-AbCdEf")
        let mine = base.appendingPathComponent("olaz-call-\(getpid())-AbCdEf")
        let other = base.appendingPathComponent("unrelated")
        for url in [dead, mine, other] { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
        CallBridge.removeStaleDirectories(in: base)
        #expect(!fm.fileExists(atPath: dead.path))
        #expect(fm.fileExists(atPath: mine.path))
        #expect(fm.fileExists(atPath: other.path))
    }
}

// MARK: - Engine state (what the chat header / cards read)

@MainActor
@Suite struct CallEngineState {
    private func conversation(_ id: String, group: Bool = false) -> ZaloEngine.ConversationSummary {
        .init(id: id, isGroup: group, name: "An", avatar: nil, pinned: false, members: 0, unread: 0, preview: nil)
    }

    private func status(_ engine: ZaloEngine, ready: Bool = true, supported: Bool = true, video: Bool = true, busy: Bool = false,
                        conv: (String, Bool)? = ("u1", true), group: [String: Any]? = nil) {
        var call: [String: Any] = ["kind": "status", "ready": ready, "supported": supported, "video": video, "busy": busy]
        if let conv {
            var row: [String: Any] = ["id": conv.0, "can": conv.1]
            if let group { row["group"] = group }
            call["conv"] = row
        }
        engine.handleCall(state: ["page": "main", "call": call])
    }

    @Test func stubsAreReplacedByRealState() {
        let engine = ZaloEngine()
        engine.call.helperInstalled = true
        #expect(!engine.canCall)               // nothing reported yet
        status(engine)
        #expect(engine.canCall)
        engine.call.helperProblem = "x"
        #expect(!engine.canCall)
    }

    @Test func headerAvailabilityFollowsOfficialRules() {
        let engine = ZaloEngine()
        engine.call.helperInstalled = true
        status(engine)
        #expect(engine.callAvailability(for: conversation("u1"), video: false) == .available)
        #expect(engine.callAvailability(for: conversation("u1"), video: true) == .available)
        // Groups without a gate from the renderer are not offered.
        #expect(engine.callAvailability(for: conversation("g1", group: true), video: true) == .hidden)
        // Official header hides calls for non-friends / OA (`canMakeCallAgain` false).
        status(engine, conv: ("u1", false))
        #expect(engine.callAvailability(for: conversation("u1"), video: false) == .hidden)
        // In another call → disabled with a reason.
        status(engine, busy: true)
        if case .disabled = engine.callAvailability(for: conversation("u1"), video: false) {} else { Issue.record("expected disabled") }
        // Video disabled when the account has no video calls.
        status(engine, video: false)
        #expect(engine.callAvailability(for: conversation("u1"), video: false) == .available)
        if case .disabled = engine.callAvailability(for: conversation("u1"), video: true) {} else { Issue.record("expected disabled") }
        // Not supported by the account's server config → disabled (buttons stay visible, with a tooltip).
        status(engine, supported: false, conv: ("u1", false))
        if case .disabled = engine.callAvailability(for: conversation("u1"), video: false) {} else { Issue.record("expected disabled") }
    }

    @Test func missingHelperDisablesWithReason() {
        let engine = ZaloEngine()
        status(engine)
        engine.call.helperInstalled = false
        guard case .disabled(let reason) = engine.callAvailability(for: conversation("u1"), video: false) else {
            Issue.record("expected disabled"); return
        }
        #expect(reason.contains("Zalo"))
    }

    @Test func groupHeaderIsVideoOnlyAndFollowsTheRendererGate() {
        let engine = ZaloEngine()
        engine.call.helperInstalled = true
        let group = conversation("g1", group: true)
        // No gate (member count above the remote threshold, calls hidden, status not here yet): no button at all.
        status(engine, conv: ("g1", false))
        #expect(engine.callAvailability(for: group, video: true) == .hidden)
        status(engine, conv: ("u1", true), group: ["disabled": false, "feature": true])
        #expect(engine.callAvailability(for: group, video: true) == .hidden)          // gate belongs to another conversation
        // Offered: video only (the official header has no group voice button).
        status(engine, conv: ("g1", false), group: ["disabled": false, "feature": true])
        #expect(engine.callAvailability(for: group, video: true) == .available)
        #expect(engine.callAvailability(for: group, video: false) == .hidden)
        // Remote config -2: shown but off. Server flag `enable_group_call_for_user` off: shown, off, with the reason.
        status(engine, conv: ("g1", false), group: ["disabled": true, "feature": true])
        if case .disabled = engine.callAvailability(for: group, video: true) {} else { Issue.record("expected disabled") }
        status(engine, conv: ("g1", false), group: ["disabled": false, "feature": false])
        guard case .disabled(let reason) = engine.callAvailability(for: group, video: true) else { Issue.record("expected disabled"); return }
        #expect(reason.contains("gọi nhóm"))
        // Same device rules as 1-1: busy / no video support.
        status(engine, busy: true, conv: ("g1", false), group: ["disabled": false, "feature": true])
        if case .disabled = engine.callAvailability(for: group, video: true) {} else { Issue.record("expected disabled") }
        status(engine, video: false, conv: ("g1", false), group: ["disabled": false, "feature": true])
        if case .disabled = engine.callAvailability(for: group, video: true) {} else { Issue.record("expected disabled") }
    }

    @Test func startCallNeverTouchesTheRendererWhenUnavailable() {
        let engine = ZaloEngine()          // no host: callChat would be a no-op anyway
        engine.startCall(to: "u1", video: false)
        #expect(engine.call.notice != nil)     // told why, not silently ignored
        engine.call.notice = nil
        engine.call.helperInstalled = true
        status(engine)
        engine.startCall(to: "g123", video: false)   // the official group header has video only
        #expect(engine.call.notice?.title == "Chỉ gọi video cho nhóm")
        engine.call.notice = nil
        engine.startCall(to: "g123", video: true)    // goes to the renderer (no host here), no notice
        #expect(engine.call.notice == nil)
    }

    @Test func incomingGroupCallBannerShowsGroupName() {
        let engine = ZaloEngine()
        engine.call.helperInstalled = true
        engine.handleCall(state: ["call": ["kind": "incoming", "name": "Gia đình", "caller": "Mẹ", "avatar": "", "group": true, "busy": false]])
        #expect(engine.call.incoming?.name == "Gia đình")
        #expect(engine.call.incoming?.caller == "Mẹ")
        #expect(engine.call.incoming?.group == true)
        // Group name unknown: the caller stands in (no separate caller line), else a generic title.
        engine.handleCall(state: ["call": ["kind": "incoming", "name": "", "caller": "Mẹ", "avatar": "", "group": true, "busy": false]])
        #expect(engine.call.incoming?.name == "Mẹ")
        #expect(engine.call.incoming?.caller == nil)
        engine.handleCall(state: ["call": ["kind": "incoming", "name": "", "caller": "", "avatar": "", "group": true, "busy": false]])
        #expect(engine.call.incoming?.name == "Cuộc gọi nhóm")
        // Busy: nothing rings.
        engine.call.incoming = nil
        engine.handleCall(state: ["call": ["kind": "incoming", "name": "Gia đình", "avatar": "", "group": true, "busy": true]])
        #expect(engine.call.incoming == nil)
    }

    @Test func pickerRequestsOpenAndCloseTheSheet() {
        let engine = ZaloEngine()
        let request: [String: Any] = [
            "kind": "picker", "token": "t1", "add": false, "video": true,
            "group": ["id": "g1", "name": "Gia đình", "avatar": ""],
            "max": 4, "existing": [], "note": "",
            "members": [["id": "u2", "name": "Mẹ", "avatar": ""], ["id": "u3", "name": "", "avatar": "https://x.test/a.jpg"], ["id": "", "name": "bỏ"]],
        ]
        engine.handleCall(state: ["call": request])
        let picker = engine.call.picker
        #expect(picker?.id == "t1" && picker?.adding == false && picker?.video == true)
        #expect(picker?.groupName == "Gia đình" && picker?.maxSelectable == 4)
        #expect(picker?.members.map(\.id) == ["u2", "u3"])            // rows without an id are dropped
        #expect(picker?.members[1].name == "Người dùng Zalo")           // never an empty row
        #expect(picker?.members[1].avatar != nil)
        // A malformed request (no token) is ignored; closing another token leaves the open one alone.
        engine.handleCall(state: ["call": ["kind": "picker", "members": []]])
        engine.handleCall(state: ["call": ["kind": "pickerClosed", "token": "other"]])
        #expect(engine.call.picker?.id == "t1")
        engine.handleCall(state: ["call": ["kind": "pickerClosed", "token": "t1"]])    // the call ended / modal closed
        #expect(engine.call.picker == nil)
        // Add-participant: the running call's video state is unknown (null) — no icon is implied.
        engine.handleCall(state: ["call": ["kind": "picker", "token": "t2", "add": true, "video": NSNull(), "group": [:], "max": 4, "members": []]])
        #expect(engine.call.picker?.adding == true && engine.call.picker?.video == nil)
    }

    @Test func pickerSelectionFollowsTheOfficialModal() {
        let members = ["a", "b", "c", "d", "e"].map { GroupCallPicker.Member(id: $0, name: "Bạn \($0)", avatar: nil) }
        let picker = GroupCallPicker(id: "t", adding: true, video: true, groupName: "G", maxSelectable: 2, existing: ["e"], members: members)
        var selection: [String] = []
        selection = picker.toggled("a", in: selection).selection
        selection = picker.toggled("b", in: selection).selection
        #expect(selection == ["a", "b"])
        // Beyond max_mem the item is refused and the toast shows; removing is always possible.
        let over = picker.toggled("c", in: selection)
        #expect(over.selection == ["a", "b"] && over.overLimit)
        #expect(picker.limitMessage == "Bạn chỉ có thể mời 2 người khác")
        selection = picker.toggled("a", in: selection).selection
        #expect(selection == ["b"])
        // Already in the call (ticked, disabled) and unknown ids never change the selection.
        #expect(picker.toggled("e", in: selection).selection == ["b"])
        #expect(picker.toggled("zzz", in: selection).selection == ["b"])
        #expect(picker.title == "Thêm người vào cuộc gọi" && picker.confirmTitle == "Thêm")
    }

    @Test func pickerSearchFoldsVietnamese() {
        let members = [("1", "Nguyễn Đức Anh"), ("2", "Lê Thị Hằng"), ("3", "Trần Văn Bình")]
            .map { GroupCallPicker.Member(id: $0.0, name: $0.1, avatar: nil) }
        let picker = GroupCallPicker(id: "t", adding: false, video: true, groupName: "G", maxSelectable: 4, members: members)
        #expect(picker.members(matching: "duc").map(\.id) == ["1"])
        #expect(picker.members(matching: "  HANG ").map(\.id) == ["2"])
        #expect(picker.members(matching: "").count == 3)
        #expect(picker.members(matching: "xyz").isEmpty)
    }

    @Test func confirmWithoutRendererStillClosesPicker() {
        let engine = ZaloEngine()
        let picker = GroupCallPicker(id: "t", adding: false, video: true, groupName: "G", maxSelectable: 2,
                                     members: [.init(id: "a", name: "A", avatar: nil)])
        engine.call.picker = picker
        engine.confirmGroupPicker(picker, selected: ["a"])
        #expect(engine.call.picker == nil)
        engine.call.picker = picker
        engine.cancelGroupPicker(GroupCallPicker(id: "other", adding: false, video: true, groupName: "G", maxSelectable: 1, members: []))
        #expect(engine.call.picker?.id == "t")             // another token does nothing
        engine.cancelGroupPicker(picker)
        #expect(engine.call.picker == nil)
    }

    @Test func incomingCallBannerAndBusyCall() {
        let engine = ZaloEngine()
        engine.call.helperInstalled = true          // independent of whether this Mac has the Zalo runtime
        engine.handleCall(state: ["call": ["kind": "incoming", "name": "Mẹ", "avatar": "", "group": false, "busy": true]])
        #expect(engine.call.incoming == nil)       // already in a call: the client auto-declines, nothing rings
        engine.handleCall(state: ["call": ["kind": "incoming", "name": "Mẹ", "avatar": "", "group": false, "busy": false]])
        #expect(engine.call.incoming?.name == "Mẹ")
        engine.handleCall(event: .callState("free"))
        #expect(engine.call.incoming == nil)
    }

    @Test func nativePopupSurfacesAsNotice() {
        let engine = ZaloEngine()
        engine.handleCall(event: .popup(header: "Lỗi", content: "Không tìm thấy micro"))
        #expect(engine.call.notice?.message == "Không tìm thấy micro")
        engine.handleCall(event: .helperUnavailable("thiếu"))
        #expect(engine.call.helperProblem == "thiếu")
        engine.handleCall(event: .helperStarted(pid: 77))
        #expect(engine.call.helperProblem == nil && engine.call.nativeRunning && engine.call.nativePID == 77)
    }

    @Test func resultMessages() {
        #expect(ZaloEngine.callFailureMessage("started") == nil)
        #expect(ZaloEngine.callFailureMessage("busy") != nil)
        #expect(ZaloEngine.callFailureMessage("whatever") != nil)
    }
}

// MARK: - Safety: signature, orphans, directories, flow control

@MainActor
@Suite(.serialized) struct CallBridgeSafety {
    @Test func unsignedHelperIsNeverSpawned() {
        let h = CallHarness()
        h.verifyError = CallHelperSignature.Failure(message: "chữ ký sai")
        h.bridge.sendToNative(json: "{}", optional: false)
        #expect(h.processes.isEmpty && !h.bridge.started)
        #expect(h.events.contains(.helperUnavailable("chữ ký sai")))
        // Checked again before every spawn: fixed signature -> starts.
        h.verifyError = nil
        h.bridge.sendToNative(json: "{}", optional: false)
        #expect(h.processes.count == 1)
        h.bridge.shutdown()
    }

    @Test func orphansAreReapedOncePerRun() {
        let h = CallHarness()
        h.bridge.sendToNative(json: "{}", optional: false)
        h.bridge.reset()
        h.bridge.sendToNative(json: "{}", optional: false)
        #expect(h.reaped == 1)
        h.bridge.shutdown()
    }

    @Test func realSignatureCheck() throws {
        // Anything that is not Zalo's helper fails the requirement.
        #expect(throws: (any Error).self) { try CallHelperSignature.verify(executable: URL(fileURLWithPath: "/bin/echo")) }
        // The installed helper (when Zalo.app is present) passes.
        let exe = CallBridge.helperExecutable()
        if CallBridge.isHelperInstalled() { try CallHelperSignature.verify(executable: exe) }
    }

    @Test func orphanMatchingOnlyTouchesOurStaleDirectories() {
        let dead = "/tmp/olaz-call-999999-AbCdEf"
        #expect(CallOrphans.staleOwner(argv: ["ZaloCall", dead + "/recv", dead + "/send"]) == 999999)
        #expect(CallOrphans.staleOwner(argv: ["ZaloCall", "/tmp/szc-999999-Zz9Zz9/recv", "/tmp/szc-999999-Zz9Zz9/send"]) == 999999)
        // Alive owner (this process), the official Zalo's fixed sockets, odd shapes: untouched.
        let mine = "/tmp/olaz-call-\(getpid())-AbCdEf"
        #expect(CallOrphans.staleOwner(argv: ["ZaloCall", mine + "/recv", mine + "/send"]) == nil)
        #expect(CallOrphans.staleOwner(argv: ["ZaloCall", "/tmp/socketzalorecv2021", "/tmp/socketzalosend2021"]) == nil)
        #expect(CallOrphans.staleOwner(argv: ["ZaloCall", dead + "/recv", "/elsewhere/send"]) == nil)
        #expect(CallOrphans.staleOwner(argv: ["ZaloCall"]) == nil)
    }

    @Test func procArgsParsing() {
        var data = Data()
        var argc: Int32 = 3
        withUnsafeBytes(of: &argc) { data.append(contentsOf: $0) }
        data.append(contentsOf: Array("/x/ZaloCall".utf8) + [0, 0, 0])
        for arg in ["ZaloCall", "/a/recv", "/a/send"] { data.append(contentsOf: Array(arg.utf8) + [0]) }
        data.append(contentsOf: Array("ENV=1".utf8) + [0])
        #expect(CallOrphans.parseProcArgs(data) == ["ZaloCall", "/a/recv", "/a/send"])
        #expect(CallOrphans.parseProcArgs(Data([1, 2])) == nil)
        // Our own argv is readable (same user).
        #expect(CallOrphans.arguments(of: getpid())?.isEmpty == false)
    }

    @Test func socketDirectoryIsFreshAndPrivate() throws {
        let h = CallHarness()
        // A hostile pre-existing directory with a predictable name is not reused.
        let predictable = "/tmp/szc-\(getpid())"
        try? FileManager.default.createDirectory(atPath: predictable, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o777])
        defer { try? FileManager.default.removeItem(atPath: predictable) }
        h.bridge.sendToNative(json: "{}", optional: false)
        let directory = (h.bridge.recvPath as NSString).deletingLastPathComponent
        #expect(directory != predictable)
        let attrs = try FileManager.default.attributesOfItem(atPath: directory)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid())
        h.bridge.shutdown()
    }

    @Test func stalledHelperNeverGetsASecondChunkInFlight() async throws {
        let h = CallHarness()
        h.ackEveryChunk = false     // never acknowledges
        h.bridge.sendToNative(json: "{}", optional: false)
        let native = try #require(h.natives.first)
        #expect(await h.wait("ready") { h.events.contains(.ready) })
        let big = #"{"blob":"\#(String(repeating: "a", count: 9000))"}"#
        h.bridge.sendToNative(json: big, optional: false)
        try await Task.sleep(for: .milliseconds(600))
        // Only the first chunk ("{}") is on the wire; without an ack nothing else is written, however long it takes.
        #expect(native.received == ["{}"])
        h.bridge.shutdown()
    }

    @Test func afterConnectMessagesGoImmediately() async throws {
        let h = CallHarness()
        h.announceReady = false     // connected, but never says native-ready
        h.bridge.sendToNative(json: #"{"n":1}"#, optional: false)
        let native = try #require(h.natives.first)
        #expect(await h.wait("connected") { native.isConnected })
        _ = await h.wait("send registered") { h.bridge.nativeReady == false && native.isConnected }
        try await Task.sleep(for: .milliseconds(100))
        h.bridge.sendToNative(json: #"{"n":2}"#, optional: false)
        // Official: once the send socket is connected, messages are written at once (only earlier ones wait).
        #expect(await h.wait("n2") { native.received.contains(#"{"n":2}"#) })
        #expect(!native.received.contains(#"{"n":1}"#))   // queued before the connection: waits for native-ready
        h.bridge.shutdown()
    }

    @Test func resetAllowsAFreshStartRightAway() async throws {
        let h = CallHarness()
        h.bridge.sendToNative(json: "{}", optional: false)
        #expect(await h.wait("ready") { h.events.contains(.ready) })
        h.bridge.reset()
        #expect(!h.bridge.started)
        h.bridge.sendToNative(json: "{}", optional: false)
        #expect(h.processes.count == 2)
        h.bridge.shutdown()
    }
}
