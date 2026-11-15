import Darwin
import Dispatch
import Foundation

/// Minimal `net.createServer().listen(path)` for a UNIX-domain stream socket.
///
/// All socket work happens on a private serial queue; callbacks are delivered on the main queue, in order.
/// Writes are queued behind each other and never block the caller.
final class UnixSocketServer: @unchecked Sendable {
    struct SocketError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// `sockaddr_un.sun_path` holds 104 bytes on macOS, including the terminator.
    static let maxPathLength = 103

    let path: String
    private let queue: DispatchQueue
    /// Marks `queue`, so `stop()` can tell it already runs there (see `stop`).
    private let queueKey = DispatchSpecificKey<Bool>()
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [Int: (fd: Int32, source: DispatchSourceRead)] = [:]
    private var nextID = 1

    // Set before `start()`; invoked on the main queue.
    var onConnect: (@MainActor @Sendable (Int) -> Void)?
    var onData: (@MainActor @Sendable (Int, Data) -> Void)?
    var onEnd: (@MainActor @Sendable (Int) -> Void)?

    init(path: String) {
        self.path = path
        queue = DispatchQueue(label: "app.olaz.unix-socket." + (path as NSString).lastPathComponent)
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit { stop() }

    func start() throws {
        try queue.sync {
            guard listenFD < 0 else { return }
            guard path.utf8.count <= Self.maxPathLength else { throw SocketError(message: "socket path too long") }
            unlink(path)
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw SocketError(message: "socket(): errno \(errno)") }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { raw in
                for (i, byte) in path.utf8.enumerated() { raw[i] = byte }
            }
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0 else {
                let code = errno
                close(fd)
                throw SocketError(message: "bind(): errno \(code)")
            }
            chmod(path, 0o600)
            guard listen(fd, 4) == 0 else {
                let code = errno
                close(fd)
                unlink(path)
                throw SocketError(message: "listen(): errno \(code)")
            }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            listenFD = fd
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptPending() }
            source.setCancelHandler { close(fd) }
            source.resume()
            acceptSource = source
        }
    }

    /// Sends `data` to connection `id` (dropped when it is gone).
    func write(_ data: Data, to id: Int) {
        queue.async { [weak self] in
            guard let self, let fd = self.connections[id]?.fd else { return }
            if !Self.writeAll(fd, data) { self.closeConnection(id, notify: true) }
        }
    }

    func disconnectAll() {
        queue.async { [weak self] in
            guard let self else { return }
            for id in Array(self.connections.keys) { self.closeConnection(id, notify: false) }
        }
    }

    func stop() {
        // The last reference can drop inside one of our own queue blocks (`[weak self]` upgraded there), running
        // `deinit` → `stop()` on `queue`: a `queue.sync` from there traps (deadlock), so clean up in place.
        if DispatchQueue.getSpecific(key: queueKey) == true {
            stopOnQueue()
        } else {
            queue.sync { stopOnQueue() }
        }
    }

    private func stopOnQueue() {
        for id in Array(connections.keys) { closeConnection(id, notify: false) }
        acceptSource?.cancel()
        acceptSource = nil
        if listenFD >= 0 {
            listenFD = -1
            unlink(path)
        }
    }

    // MARK: Queue-confined

    private func acceptPending() {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { return }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let id = nextID
            nextID += 1
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.readable(id) }
            source.setCancelHandler { close(fd) }
            connections[id] = (fd, source)
            source.resume()
            DispatchQueue.main.async { [weak self] in
                guard let callback = self?.onConnect else { return }
                MainActor.assumeIsolated { callback(id) }
            }
        }
    }

    private func readable(_ id: Int) {
        guard let fd = connections[id]?.fd else { return }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                let data = Data(buffer[0..<count])
                DispatchQueue.main.async { [weak self] in
                    guard let callback = self?.onData else { return }
                    MainActor.assumeIsolated { callback(id, data) }
                }
                if count < buffer.count { return }
            } else if count == 0 {
                closeConnection(id, notify: true)
                return
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else if errno == EINTR {
                continue
            } else {
                closeConnection(id, notify: true)
                return
            }
        }
    }

    private func closeConnection(_ id: Int, notify: Bool) {
        guard let entry = connections.removeValue(forKey: id) else { return }
        entry.source.cancel()   // the cancel handler closes the descriptor
        guard notify else { return }
        DispatchQueue.main.async { [weak self] in
            guard let callback = self?.onEnd else { return }
            MainActor.assumeIsolated { callback(id) }
        }
    }

    /// Writes everything, waiting (up to ~3 s without progress) when the peer's buffer is full.
    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var offset = 0
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            while offset < raw.count {
                let written = Darwin.write(fd, base + offset, raw.count - offset)
                if written > 0 { offset += written; continue }
                if written < 0, errno == EINTR { continue }
                if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    if poll(&descriptor, 1, 3000) > 0 { continue }
                }
                return false
            }
            return true
        }
    }
}
