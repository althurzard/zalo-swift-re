import Foundation
import os

extension FingerprintProxy {
    enum StreamEvent: Sendable {
        case chunk(Data)
        case end
    }

    /// What `stream` returns: the response head and the body stream, or a complete response
    /// when the helper did not stream (its no-redirect answer to a 3xx).
    enum StreamStart {
        case head(ResponseHead, AsyncThrowingStream<StreamEvent, Swift.Error>)
        case complete(Response)
    }

    /// One Olaz↔helper connection: a unix socket with a blocking reader thread. Request and
    /// stream answers are matched to their callers by id; websocket events are forwarded to
    /// the proxy on the main queue (FIFO from this one thread).
    final class Connection: @unchecked Sendable {
        enum Frame {
            case closed
            case wsEvent(session: String, event: WSEvent)
        }

        private let fd: Int32
        private let writeLock = NSLock()
        private let stateLock = NSLock()
        private var closed = false

        /// Bytes read but not yet parsed.
        private var buffer = Data()
        /// A binary payload in progress: its owning frame id and remaining byte count.
        private var expectedBinary: (id: String, remaining: Int)?
        private var wsMessageKind: [String: String] = [:]
        private var wsPartial: [String: Data] = [:]

        private var pendingResponses: [String: CheckedContinuation<Response, Swift.Error>] = [:]
        private var pendingOpens: [String: CheckedContinuation<String, Swift.Error>] = [:]
        private var pendingStreamHeads: [String: CheckedContinuation<StreamStart, Swift.Error>] = [:]
        private var activeStreams: [String: AsyncThrowingStream<StreamEvent, Swift.Error>.Continuation] = [:]
        private var helloContinuation: CheckedContinuation<String, Swift.Error>?
        let helloReceived = OSAllocatedUnfairLock(initialState: false)

        /// Called on the main queue with websocket events and socket closure.
        var onFrame: ((Frame) -> Void)?

        init?(path: String) {
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            var noSigPipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            guard path.utf8.count < MemoryLayout<sockaddr_un>.size - 1,
                  path.withCString({ cstring -> Bool in
                      withUnsafeMutableBytes(of: &address.sun_path) { destination in
                          destination.copyBytes(from: UnsafeRawBufferPointer(start: cstring, count: strlen(cstring) + 1))
                      }
                      return true
                  }),
                  withUnsafePointer(to: &address, { pointer in
                      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddr in
                          connect(fd, sockaddr, socklen_t(MemoryLayout<sockaddr_un>.size))
                      }
                  }) == 0 else {
                Darwin.close(fd)
                return nil
            }
        }

        // MARK: Reading

        func startReading() {
            let thread = Thread { [weak self] in
                guard let self else { return }
                var chunk = [UInt8](repeating: 0, count: 64 << 10)
                while true {
                    let received = read(self.fd, &chunk, chunk.count)
                    if received <= 0 {
                        self.shutdownFromReader()
                        return
                    }
                    self.feed(Data(chunk[0..<received]))
                    if self.isClosed { return }
                }
            }
            thread.name = "olaz.fp-reader"
            thread.start()
        }

        private func shutdownFromReader() {
            deliver(.closed)
            failAllPending(FingerprintProxy.Error.connectionLost("socket closed"))
        }

        private func feed(_ data: Data) {
            buffer.append(data)
            while true {
                if var expected = expectedBinary {
                    guard !buffer.isEmpty else { return }
                    let take = min(expected.remaining, buffer.count)
                    let piece = buffer.prefix(take)
                    buffer.removeFirst(take)
                    expected.remaining -= take
                    let complete = expected.remaining == 0
                    expectedBinary = complete ? nil : expected
                    deliverBinary(expected.id, piece, complete: complete)
                    continue
                }
                guard let newline = buffer.firstIndex(of: 0x0A) else { return }
                let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...newline)
                guard handleLine(line) else {
                    close()
                    shutdownFromReader()
                    return
                }
            }
        }

        /// One parsed line; returns false when the connection is done (BYE). Only the first two
        /// fields split on spaces — JSON payloads may contain spaces themselves.
        private func handleLine(_ line: String) -> Bool {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            let command = parts[0]
            let id = parts.count > 1 ? parts[1] : ""
            let rest = parts.count > 2 ? parts[2] : ""
            switch command {
            case "OK":
                resumeHello(rest)
            case "BYE":
                return false
            case "RES":
                if let wire = Self.decode(WireResponse.self, rest) {
                    resumeResponse(id, Self.makeResponse(wire))
                } else {
                    resumeResponse(id, brokenFrame("RES"))
                }
            case "RESHEAD":
                if let head = Self.decode(WireResponse.self, rest).map(Self.makeHead) {
                    startStreamBody(id, head)
                } else {
                    resumeResponse(id, brokenFrame("RESHEAD"))
                }
            case "CHUNK":
                if let length = Int(rest) {
                    if length > 0 {
                        expectedBinary = (id, length)
                    } else {
                        deliverBinary(id, Data(), complete: true)
                    }
                }
            case "END":
                finishStream(id, nil)
            case "ERR":
                if let wire = Self.decode(WireResponse.self, rest) {
                    resumeError(id, wire.error ?? "unknown error", status: wire.status)
                } else {
                    resumeError(id, "undecodable ERR frame", status: 0)
                }
            case "WSOPENED":
                if let wire = Self.decode(WireEvent.self, rest) {
                    resumeOpen(id, wire.protocolName ?? "")
                } else {
                    resumeOpenError(id, "undecodable WSOPENED frame")
                }
            case "WSERR":
                if let wire = Self.decode(WireEvent.self, rest) {
                    resumeOpenError(id, wire.error ?? "websocket open failed")
                } else {
                    resumeOpenError(id, "undecodable WSERR frame")
                }
            case "WSMSG":
                // rest = "text|binary <len>"
                let messageParts = rest.split(separator: " ", maxSplits: 1).map(String.init)
                guard messageParts.count == 2, let length = Int(messageParts[1]) else { return true }
                wsMessageKind[id] = messageParts[0]
                if length > 0 {
                    expectedBinary = (id, length)
                } else {
                    deliverWsMessage(id, Data())
                }
            case "WSCLOSED":
                // rest = "<code> {json}"
                let closeParts = rest.split(separator: " ", maxSplits: 1).map(String.init)
                guard closeParts.count == 2 else { return true }
                let reason = Self.decode(WireEvent.self, closeParts[1])?.reason ?? ""
                deliver(.wsEvent(session: id, event: .closed(code: Int(closeParts[0]) ?? 1006, reason: reason)))
            default:
                break
            }
            return true
        }

        private func brokenFrame(_ kind: String) -> Response {
            Response(head: ResponseHead(status: 0, statusText: "", headers: [], url: ""),
                     body: Data())
            // The status 0 + empty body marks an undecodable frame; the caller's caller
            // treats status 0 as a failure. (resumeResponse has no error variant, so this
            // is only reachable when the helper sent garbage.)
        }

        // MARK: Frame delivery

        private func deliver(_ frame: Frame) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.onFrame?(frame)
                }
            }
        }

        /// Binary payloads of CHUNK frames stream through piece by piece (the END line, not
        /// the frame end, finishes a stream); websocket messages are reassembled and delivered
        /// whole.
        private func deliverBinary(_ id: String, _ piece: Data, complete: Bool) {
            if activeStreams[id] != nil {
                activeStreams[id]?.yield(.chunk(piece))
            } else if wsMessageKind[id] != nil {
                var message = wsPartial[id] ?? Data()
                message.append(piece)
                if complete {
                    wsPartial[id] = nil
                    deliverWsMessage(id, message)
                } else {
                    wsPartial[id] = message
                }
            }
        }

        private func deliverWsMessage(_ session: String, _ payload: Data) {
            let kind = wsMessageKind.removeValue(forKey: session) ?? "binary"
            if kind == "text" {
                deliver(.wsEvent(session: session, event: .text(String(decoding: payload, as: UTF8.self))))
            } else {
                deliver(.wsEvent(session: session, event: .binary(payload)))
            }
        }

        // MARK: Hello

        func expectHello() async throws -> String {
            try await withCheckedThrowingContinuation { continuation in
                stateLock.lock()
                helloContinuation = continuation
                stateLock.unlock()
                do {
                    try send("HELLO\n")
                } catch {
                    resumeHello(with: error)
                }
            }
        }

        private func resumeHello(_ profile: String) {
            helloReceived.withLock { $0 = true }
            stateLock.lock()
            let continuation = helloContinuation
            helloContinuation = nil
            stateLock.unlock()
            continuation?.resume(returning: profile)
        }

        private func resumeHello(with error: Swift.Error) {
            stateLock.lock()
            let continuation = helloContinuation
            helloContinuation = nil
            stateLock.unlock()
            continuation?.resume(throwing: error)
        }

        // MARK: Requests

        func perform(_ request: Request, id: String) async throws -> Response {
            let encoded = Self.encode(Self.wire(request))
            return try await withCheckedThrowingContinuation { continuation in
                stateLock.lock()
                pendingResponses[id] = continuation
                stateLock.unlock()
                do {
                    try send("REQ \(id) \(encoded)\n")
                } catch {
                    takePending(&pendingResponses, id: id)?.resume(throwing: error)
                }
            }
        }

        private func resumeResponse(_ id: String, _ response: Response) {
            if let continuation = takePending(&pendingResponses, id: id) {
                continuation.resume(returning: response)
            } else if let continuation = takePending(&pendingStreamHeads, id: id) {
                continuation.resume(returning: .complete(response))
            }
        }

        private func resumeError(_ id: String, _ message: String, status: Int) {
            let error: Error = message.contains("body too large")
                ? .tooLarge
                : .requestFailed(message, status: status)
            if let continuation = takePending(&pendingResponses, id: id) {
                continuation.resume(throwing: error)
            } else if let continuation = takePending(&pendingStreamHeads, id: id) {
                continuation.resume(throwing: error)
            } else {
                finishStream(id, error)
            }
        }

        // MARK: Streams

        func stream(_ request: Request, id: String) async throws -> StreamStart {
            let encoded = Self.encode(Self.wire(request))
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    stateLock.lock()
                    pendingStreamHeads[id] = continuation
                    stateLock.unlock()
                    do {
                        try send("REQ \(id) \(encoded)\n")
                    } catch {
                        takePending(&pendingStreamHeads, id: id)?.resume(throwing: error)
                    }
                }
            } onCancel: {
                self.cancel(id)
            }
        }

        private func startStreamBody(_ id: String, _ head: ResponseHead) {
            guard let pendingHead = takePending(&pendingStreamHeads, id: id) else { return }
            let (stream, bodyContinuation) = AsyncThrowingStream<StreamEvent, Swift.Error>.makeStream()
            stateLock.lock()
            activeStreams[id] = bodyContinuation
            stateLock.unlock()
            pendingHead.resume(returning: .head(head, stream))
        }

        private func finishStream(_ id: String, _ error: Swift.Error?) {
            stateLock.lock()
            let entry = activeStreams.removeValue(forKey: id)
            stateLock.unlock()
            guard let entry else { return }
            if let error {
                entry.finish(throwing: error)
            } else {
                entry.yield(.end)
                entry.finish()
            }
        }

        // MARK: WebSockets

        func webSocketOpen(session: String, url: URL, headers: [(String, String)], protocols: [String]) async throws -> String {
            let wire = (try? JSONSerialization.data(withJSONObject: [
                "url": url.absoluteString,
                "headers": headers.map { [$0.0, $0.1] },
                "protocols": protocols,
            ])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    stateLock.lock()
                    pendingOpens[session] = continuation
                    stateLock.unlock()
                    do {
                        try send("WSOPEN \(session) \(wire)\n")
                    } catch {
                        takePending(&pendingOpens, id: session)?.resume(throwing: error)
                    }
                }
            } onCancel: {
                self.cancel(session)
            }
        }

        private func resumeOpen(_ session: String, _ negotiated: String) {
            takePending(&pendingOpens, id: session)?.resume(returning: negotiated)
        }

        private func resumeOpenError(_ session: String, _ message: String) {
            takePending(&pendingOpens, id: session)?.resume(throwing: FingerprintProxy.Error.requestFailed(message, status: 0))
        }

        func webSocketSend(session: String, kind: String, payload: Data) {
            _ = try? send("WSSEND \(session) \(kind) \(payload.count)\n", payload)
        }

        func webSocketClose(session: String, code: Int) {
            _ = try? send("WSCLOSE \(session) \(code)\n")
        }

        // MARK: Control

        func cancel(_ id: String) {
            stateLock.lock()
            let pendingResponse = pendingResponses.removeValue(forKey: id)
            let pendingHead = pendingStreamHeads.removeValue(forKey: id)
            let pendingOpen = pendingOpens.removeValue(forKey: id)
            let stream = activeStreams.removeValue(forKey: id)
            stateLock.unlock()
            pendingResponse?.resume(throwing: CancellationError())
            pendingHead?.resume(throwing: CancellationError())
            pendingOpen?.resume(throwing: CancellationError())
            stream?.finish(throwing: CancellationError())
            _ = try? send("CANCEL \(id)\n")
        }

        func shutdown() {
            _ = try? send("SHUTDOWN\n")
            close()
        }

        var isClosed: Bool {
            stateLock.lock(); defer { stateLock.unlock() }
            return closed
        }

        func close() {
            stateLock.lock()
            let alreadyClosed = closed
            closed = true
            stateLock.unlock()
            if !alreadyClosed { Darwin.close(fd) }
        }

        func failAllPending(_ error: Error) {
            stateLock.lock()
            let responses = pendingResponses
            let heads = pendingStreamHeads
            let opens = pendingOpens
            let streams = activeStreams
            pendingResponses.removeAll()
            pendingStreamHeads.removeAll()
            pendingOpens.removeAll()
            activeStreams.removeAll()
            let hello = helloContinuation
            helloContinuation = nil
            stateLock.unlock()
            for (_, continuation) in responses { continuation.resume(throwing: error) }
            for (_, continuation) in heads { continuation.resume(throwing: error) }
            for (_, continuation) in opens { continuation.resume(throwing: error) }
            for (_, stream) in streams { stream.finish(throwing: error) }
            hello?.resume(throwing: error)
        }

        // MARK: Writing

        private func send(_ line: String) throws {
            try send(line, Data())
        }

        private func send(_ line: String, _ payload: Data) throws {
            writeLock.lock()
            defer { writeLock.unlock() }
            var data = Data(line.utf8)
            data.append(payload)
            try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                var sent = 0
                while sent < raw.count {
                    let written = write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                    if written <= 0 { throw FingerprintProxy.Error.connectionLost("write failed") }
                    sent += written
                }
            }
        }

        // MARK: Wire structs

        private struct WireRequest: Codable {
            var method: String
            var url: String
            var headers: [[String]]
            var bodyB64: String?
            var timeoutMs: Int
            var stream: Bool
            var follow: Bool
            var maxBytes: Int64
            var idleMs: Int
            var firstByteMs: Int
        }

        private struct WireResponse: Codable {
            var status: Int = 0
            var statusText: String?
            var headers: [[String]]?
            var url: String?
            var bodyB64: String?
            var error: String?
        }

        private struct WireEvent: Codable {
            var protocolName: String?
            var error: String?
            var reason: String?
            var status: Int?

            enum CodingKeys: String, CodingKey {
                case protocolName = "protocol"
                case error, reason, status
            }
        }

        private static func wire(_ request: Request) -> WireRequest {
            WireRequest(
                method: request.method,
                url: request.url.absoluteString,
                headers: request.headers.map { [$0.0, $0.1] },
                bodyB64: request.body.map { $0.base64EncodedString() },
                timeoutMs: request.timeoutMs,
                stream: request.stream,
                follow: request.follow,
                maxBytes: request.maxBytes,
                idleMs: request.idleMs,
                firstByteMs: request.firstByteMs
            )
        }

        private static func encode(_ value: some Encodable) -> String {
            guard let data = try? JSONEncoder().encode(value) else { return "{}" }
            return String(decoding: data, as: UTF8.self)
        }

        private static func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T? {
            try? JSONDecoder().decode(type, from: Data(json.utf8))
        }

        private static func makeHead(_ wire: WireResponse) -> ResponseHead {
            ResponseHead(
                status: wire.status,
                statusText: wire.statusText ?? "",
                headers: (wire.headers ?? []).compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil },
                url: wire.url ?? ""
            )
        }

        private static func makeResponse(_ wire: WireResponse) -> Response {
            Response(
                head: makeHead(wire),
                body: wire.bodyB64.flatMap { Data(base64Encoded: $0) } ?? Data()
            )
        }

        private func takePending<T>(_ dictionary: inout [String: CheckedContinuation<T, Swift.Error>], id: String) -> CheckedContinuation<T, Swift.Error>? {
            stateLock.lock()
            defer { stateLock.unlock() }
            return dictionary.removeValue(forKey: id)
        }
    }
}
