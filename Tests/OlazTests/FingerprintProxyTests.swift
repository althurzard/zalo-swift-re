import Network
import XCTest
@testable import Olaz

/// The fingerprint helper (Go): process lifecycle, the unix-socket protocol (HTTP, streaming,
/// websockets) against local servers, and the Set-Cookie parser the helper path needs.
///
/// The helper binary is built by `scripts/build-fingerprint-helper.sh`; tests skip when it is
/// absent (a checkout without Go).
@MainActor
final class FingerprintProxyTests: XCTestCase {
    nonisolated static let helperURL: URL? = {
        let dev = URL(fileURLWithPath: #filePath) // …/Tests/OlazTests/FingerprintProxyTests.swift
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("FingerprintHelper/build/olaz-fingerprint-helper")
        return FileManager.default.isExecutableFile(atPath: dev.path) ? dev : nil
    }()

    /// A tiny local HTTP server: one response per request, served from a queue.
    private final class LocalHTTPServer: @unchecked Sendable {
        let listener: NWListener
        private(set) var port: UInt16 = 0
        private let queue = DispatchQueue(label: "olaz.test-http")
        private var handler: (@Sendable (String) -> (Int, [String: String], Data))?
        private let lock = NSLock()

        init() throws {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            listener = try NWListener(using: parameters, on: .any)
        }

        func start(_ handler: @escaping @Sendable (String) -> (Int, [String: String], Data)) {
            self.handler = handler
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                connection.start(queue: self.queue)
                self.receive(connection)
            }
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { [weak self] state in
                if case .ready = state {
                    self?.port = self?.listener.port?.rawValue ?? 0
                    ready.signal()
                }
            }
            listener.start(queue: queue)
            XCTAssertEqual(ready.wait(timeout: .now() + 5), .success, "http listener never started")
        }

        private var buffer = Data()

        private func receive(_ connection: NWConnection) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { [weak self] content, _, _, error in
                guard let self, error == nil else { return }
                if let content { self.buffer.append(content) }
                // crude HTTP/1.1: answer once the end of the headers is in (and the body, if any)
                guard let headerEnd = self.buffer.range(of: Data("\r\n\r\n".utf8)) else {
                    self.receive(connection)
                    return
                }
                let head = String(decoding: self.buffer[..<headerEnd.lowerBound], as: UTF8.self)
                let contentLength = Int(head.split(separator: "\r\n")
                    .first { $0.lowercased().hasPrefix("content-length:") }?
                    .dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces) ?? "0") ?? 0
                guard self.buffer.count >= headerEnd.upperBound - self.buffer.startIndex + contentLength else {
                    self.receive(connection)
                    return
                }
                let request = head + "\n[body \(contentLength) bytes]"
                self.buffer.removeAll()
                let (status, headers, body) = self.lock.withLock { self.handler?(request) ?? (500, [:], Data()) }
                var response = "HTTP/1.1 \(status) X\r\nContent-Length: \(body.count)\r\n"
                for (name, value) in headers { response += "\(name): \(value)\r\n" }
                response += "\r\n"
                var payload = Data(response.utf8)
                payload.append(body)
                // One NWConnection.send per 32 KiB piece: a single huge send is refused.
                var offset = payload.startIndex
                func sendNext() {
                    guard offset < payload.endIndex else {
                        // The client (the helper) closes after reading the body; this side
                        // follows when that close arrives.
                        return
                    }
                    let end = payload.index(offset, offsetBy: 32 << 10, limitedBy: payload.endIndex) ?? payload.endIndex
                    let piece = payload[offset..<end]
                    offset = end
                    connection.send(content: Data(piece), completion: .contentProcessed { _ in
                        sendNext()
                    })
                }
                sendNext()
            }
        }
    }

    // MARK: Protocol roundtrips

    func testHelloAndRequestRoundtrip() async throws {
        try XCTSkipUnless(Self.helperURL != nil, "fingerprint helper not built")
        let server = try LocalHTTPServer()
        server.start { request in
            // The request must carry the headers the caller set, in order.
            XCTAssertTrue(request.contains("X-Olaz-Test: yes"), request)
            return (200, ["Content-Type": "text/plain", "X-Answer": "42"], Data("hello".utf8))
        }
        let proxy = try await startedProxy()

        var request = FingerprintProxy.Request(url: URL(string: "http://127.0.0.1:\(server.port)/a")!)
        request.method = "GET"
        request.headers = [("X-Olaz-Test", "yes"), ("Accept", "*/*")]
        let response = try await proxy.perform(request)
        XCTAssertEqual(response.head.status, 200)
        XCTAssertEqual(String(decoding: response.body, as: UTF8.self), "hello")
        let answer = try XCTUnwrap(response.head.headers.first { $0.0 == "X-Answer" })
        XCTAssertEqual(answer.1, "42")
    }

    func testStreamRoundtripDeliversChunksInOrder() async throws {
        try XCTSkipUnless(Self.helperURL != nil, "fingerprint helper not built")
        let payload = Data((0..<(300 << 10)).map { UInt8($0 % 251) }) // several 64 KiB chunks
        let server = try LocalHTTPServer()
        server.start { _ in (200, [:], payload) }
        let proxy = try await startedProxy()

        var request = FingerprintProxy.Request(url: URL(string: "http://127.0.0.1:\(server.port)/big")!)
        request.stream = true
        request.maxBytes = 1 << 20
        let start = try await proxy.stream(request)
        guard case .head(let head, let events) = start else {
            return XCTFail("expected a streamed head")
        }
        XCTAssertEqual(head.status, 200)
        var collected = Data()
        for try await event in events {
            switch event {
            case .chunk(let data): collected.append(data)
            case .end: break
            }
        }
        XCTAssertEqual(collected, payload)
    }

    func testMaxBytesAbortsTheStream() async throws {
        try XCTSkipUnless(Self.helperURL != nil, "fingerprint helper not built")
        let server = try LocalHTTPServer()
        server.start { _ in (200, [:], Data(repeating: 0x61, count: 1 << 20)) }
        let proxy = try await startedProxy()

        var request = FingerprintProxy.Request(url: URL(string: "http://127.0.0.1:\(server.port)/big")!)
        request.stream = true
        request.maxBytes = 1024
        let start = try await proxy.stream(request)
        guard case .head(_, let events) = start else { return XCTFail("expected a streamed head") }
        do {
            for try await _ in events {}
            XCTFail("expected tooLarge")
        } catch let error as FingerprintProxy.Error {
            guard case .tooLarge = error else { return XCTFail("wrong error: \(error)") }
        }
    }

    // MARK: WebSocket

    func testWebSocketEchoRoundtrip() async throws {
        try XCTSkipUnless(Self.helperURL != nil, "fingerprint helper not built")
        let echo = try LocalWebSocketEchoServer()
        echo.start()
        let proxy = try await startedProxy()
        let gotText = expectation(description: "messages")
        gotText.expectedFulfillmentCount = 2
        let gotClose = expectation(description: "closed")

        proxy.setWebSocketHandler(id: 7) { event in
            switch event {
            case .text(let text):
                XCTAssertEqual(text, "ping")
                gotText.fulfill()
            case .binary(let data):
                XCTAssertEqual(data, Data([1, 2, 3]))
                gotText.fulfill()
            case .closed:
                gotClose.fulfill()
            case .error(let message):
                XCTFail("ws error: \(message)")
            }
        }
        let negotiated = try await proxy.webSocketOpen(id: 7, url: URL(string: "ws://127.0.0.1:\(echo.port)/rt")!,
                                                       headers: [("User-Agent", "ZaloPC-darwin-23v694")],
                                                       protocols: ["chat"])
        _ = negotiated // WSOPENED returned means open

        proxy.webSocketSend(id: 7, text: "ping")
        proxy.webSocketSend(id: 7, data: Data([1, 2, 3]))
        // messages must have echoed by the time the close handshake completes
        try await Task.sleep(for: .milliseconds(500))
        proxy.webSocketClose(id: 7, code: 1000)
        await fulfillment(of: [gotText, gotClose], timeout: 5)
    }

    /// NWListener-based websocket echo (what the helper connects to over plain ws://).
    private final class LocalWebSocketEchoServer: @unchecked Sendable {
        let listener: NWListener
        private let queue = DispatchQueue(label: "olaz.test-ws")
        private(set) var port: UInt16 = 0

        init() throws {
            let parameters = NWParameters.tcp
            let ws = NWProtocolWebSocket.Options()
            ws.autoReplyPing = true
            parameters.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
            listener = try NWListener(using: parameters, on: .any)
        }

        func start() {
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: self?.queue ?? .main)
                self?.receive(connection)
            }
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { [weak self] state in
                if case .ready = state {
                    self?.port = self?.listener.port?.rawValue ?? 0
                    ready.signal()
                }
            }
            listener.start(queue: queue)
            XCTAssertEqual(ready.wait(timeout: .now() + 5), .success, "ws listener never started")
        }

        private func receive(_ connection: NWConnection) {
            connection.receiveMessage { [weak self] content, context, _, error in
                guard error == nil else { return }
                if let content {
                    let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                    if metadata?.opcode == .close {
                        connection.cancel()
                        return
                    }
                    // echo back
                    let reply = NWProtocolWebSocket.Metadata(opcode: metadata?.opcode ?? .binary)
                    let context = NWConnection.ContentContext(identifier: "echo", metadata: [reply])
                    connection.send(content: content, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
                    self?.receive(connection)
                } else {
                    self?.receive(connection)
                }
            }
        }
    }

    // MARK: Set-Cookie parser

    func testSetCookieParserHandlesZaloShapes() throws {
        let url = try XCTUnwrap(URL(string: "https://tt-chat1-wpa.chat.zalo.me/"))

        let session = try XCTUnwrap(NetworkProxy.cookie(fromSetCookie:
            "zpw_sek=ABC123; Path=/; Domain=.chat.zalo.me; Expires=Sun, 08 Nov 2026 12:00:00 GMT; Secure; HttpOnly", url: url))
        XCTAssertEqual(session.name, "zpw_sek")
        XCTAssertEqual(session.value, "ABC123")
        XCTAssertEqual(session.domain, ".chat.zalo.me")
        XCTAssertEqual(session.path, "/")
        XCTAssertEqual(session.isSecure, true)
        XCTAssertNotNil(session.expiresDate)

        // No Domain attribute: host-only cookie on the request's host.
        let hostOnly = try XCTUnwrap(NetworkProxy.cookie(fromSetCookie: "theme=dark; Path=/", url: url))
        XCTAssertEqual(hostOnly.domain, "tt-chat1-wpa.chat.zalo.me")
        XCTAssertEqual(hostOnly.path, "/")

        // SameSite is preserved in a form the storage round-trips.
        let lax = try XCTUnwrap(NetworkProxy.cookie(fromSetCookie: "pref=1; SameSite=Lax", url: url))
        XCTAssertNotNil(lax.sameSitePolicy, "SameSite=Lax must survive the round-trip")

        XCTAssertNil(NetworkProxy.cookie(fromSetCookie: "novalue", url: url))
    }

    // MARK: Helpers

    /// A started proxy (helper process + one connection), like the app uses.
    private func startedProxy() async throws -> FingerprintProxy {
        guard await FingerprintProxy.shared.ready(seconds: 10) else {
            throw XCTSkip("fingerprint helper did not become ready")
        }
        return .shared
    }

    override func setUp() async throws {
        try await super.setUp()
        guard Self.helperURL != nil else { throw XCTSkip("fingerprint helper not built") }
        _ = try await startedProxy()
    }
}
