import Foundation

/// Append-only diagnostics file: `~/Library/Application Support/Olaz/logs/engine.log`.
///
/// Records *shapes*, never secrets: IPC channel names with argument types,
/// request method/host/path/status (no query strings or bodies), renderer
/// console errors, and trusted-device step outcomes.
@MainActor
final class EngineLog {
    static let shared = EngineLog()

    let url: URL
    private let writer: Writer
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// `swift test` must not rotate the running app's log out from under it.
    private static var isTestProcess: Bool {
        let process = ProcessInfo.processInfo
        return process.environment["XCTestConfigurationFilePath"] != nil
            || ["xctest", "swiftpm-testing-helper"].contains(process.processName)
            || Bundle.main.bundlePath.hasSuffix(".xctest")
            || NSClassFromString("XCTestCase") != nil
    }

    private init() {
        let dir = Self.isTestProcess
            ? FileManager.default.temporaryDirectory.appendingPathComponent("OlazTests-logs", isDirectory: true)
            : ZaloPlatform.defaultUserData.deletingLastPathComponent().appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("engine.log")
        writer = Writer(url: url, previous: dir.appendingPathComponent("engine.previous.log"))
        // Keep the previous run for comparison (nothing else touches the writer yet, so no queue hop).
        writer.rotate(force: false)
    }

    func write(_ line: String) {
        let text = "\(formatter.string(from: .now)) \(line.prefix(1500))\n"
        writer.append(Data(text.utf8))
    }

    /// Argument summary without values: `(string, object{3}, bytes[512])`.
    static func shape(_ args: [Any]) -> String {
        "(" + args.map { arg -> String in
            switch arg {
            case is String: "string"
            case let n as NSNumber: CFGetTypeID(n) == CFBooleanGetTypeID() ? "bool" : "number"
            case let d as Data: "bytes[\(d.count)]"
            case let a as [Any]: "array[\(a.count)]"
            case let o as [String: Any]: "object{\(o.keys.sorted().prefix(6).joined(separator: ","))}"
            case is NSNull: "null"
            default: "\(type(of: arg))"
            }
        }.joined(separator: ", ") + ")"
    }

    /// The file side, confined to `queue`: callers (mostly the main thread) never wait for disk I/O, a full disk only
    /// drops lines (the throwing `write(contentsOf:)`, not the legacy `write(_:)` that raises an ObjC exception), and a
    /// long session cannot grow the file without bound.
    private final class Writer: @unchecked Sendable {
        /// Rotate (to `engine.previous.log`) once the current file passes this size.
        static let maxBytes = 20 << 20

        let queue = DispatchQueue(label: "app.olaz.engine-log", qos: .utility)
        let url: URL
        let previous: URL
        private var handle: FileHandle?
        private var size = 0

        init(url: URL, previous: URL) {
            self.url = url
            self.previous = previous
        }

        func append(_ data: Data) {
            queue.async { [self] in
                if size + data.count > Self.maxBytes { rotate(force: true) }
                guard let handle else { return }
                do {
                    try handle.write(contentsOf: data)
                    size += data.count
                } catch {
                    // Disk full / file gone: drop the line (diagnostics only).
                }
            }
        }

        /// On `queue` (or before first use). Moves a non-empty current file to `previous` (only when over the cap unless at launch, where
        /// `force` is false and any content belongs to the previous run) and opens a fresh one.
        func rotate(force: Bool) {
            let fm = FileManager.default
            try? handle?.close()
            handle = nil
            if let current = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, current > 0 || force {
                try? fm.removeItem(at: previous)
                try? fm.moveItem(at: url, to: previous)
            }
            fm.createFile(atPath: url.path, contents: nil)
            handle = try? FileHandle(forWritingTo: url)
            size = 0
        }
    }
}
