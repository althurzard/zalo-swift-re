import Foundation

/// Read-only access to an Electron `app.asar` archive.
///
/// Olaz does not ship VNG's client code. It reads the official renderer
/// (`pc-dist/…`) directly out of the official Zalo PC's `app.asar`, which
/// `ZaloRuntimeInstaller` fetches from VNG into Olaz's own folder (`ZaloRuntime`),
/// so the protocol, crypto and sync logic are Zalo's own.
///
/// Format: `[u32 4][u32 headerPickleSize]` then a pickle `[u32 payload][u32 jsonLen][json]`;
/// file offsets in the JSON header are relative to `8 + headerPickleSize`.
/// Entries flagged `unpacked` live beside the archive in `app.asar.unpacked/`.
final class AsarArchive: @unchecked Sendable {
    struct Entry {
        let offset: Int
        let size: Int
        let unpacked: Bool
    }

    enum AsarError: LocalizedError {
        case unreadable(URL)
        case badHeader

        var errorDescription: String? {
            switch self {
            case .unreadable(let url): "Không đọc được \(url.path)"
            case .badHeader: "app.asar không hợp lệ"
            }
        }
    }

    let url: URL
    private let data: Data
    private let base: Int
    private var entries: [String: Entry] = [:]

    init(url: URL) throws {
        self.url = url
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else {
            throw AsarError.unreadable(url)
        }
        self.data = data
        guard data.count > 16 else { throw AsarError.badHeader }
        let headerPickleSize = Int(data.u32(at: 4))
        let jsonLength = Int(data.u32(at: 12))
        guard 16 + jsonLength <= data.count,
              let json = try? JSONSerialization.jsonObject(with: data.subdata(in: 16..<(16 + jsonLength))) as? [String: Any]
        else { throw AsarError.badHeader }
        base = 8 + headerPickleSize
        index(json, prefix: "")
    }

    private func index(_ node: [String: Any], prefix: String) {
        guard let files = node["files"] as? [String: Any] else { return }
        for (name, value) in files {
            guard let child = value as? [String: Any] else { continue }
            let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
            if child["files"] != nil {
                index(child, prefix: path)
            } else if let size = (child["size"] as? NSNumber)?.intValue {
                let offset = Int((child["offset"] as? String) ?? "0") ?? 0
                entries[path] = Entry(offset: offset, size: size, unpacked: child["unpacked"] as? Bool ?? false)
            }
        }
    }

    func contains(_ path: String) -> Bool { entries[normalize(path)] != nil }

    /// Bytes of a file inside the archive, e.g. `pc-dist/login.html`.
    func read(_ path: String) -> Data? {
        let key = normalize(path)
        guard let entry = entries[key] else { return nil }
        if entry.unpacked {
            let unpackedURL = url.deletingLastPathComponent()
                .appendingPathComponent("app.asar.unpacked")
                .appendingPathComponent(key)
            return try? Data(contentsOf: unpackedURL)
        }
        let start = base + entry.offset
        guard start + entry.size <= data.count else { return nil }
        return data.subdata(in: start..<(start + entry.size))
    }

    func paths(withPrefix prefix: String) -> [String] {
        entries.keys.filter { $0.hasPrefix(prefix) }.sorted()
    }

    private func normalize(_ path: String) -> String {
        var p = path.removingPercentEncoding ?? path
        while p.hasPrefix("/") { p.removeFirst() }
        return p
    }
}

private extension Data {
    func u32(at offset: Int) -> UInt32 {
        withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }.littleEndian
    }
}

/// Locates the official client the runtime loads code from.
enum OfficialZaloInstall {
    /// The runtime Olaz installed (`ZaloRuntime.current`), laid out like Zalo.app's `Contents/`.
    static var defaultAppURL: URL { ZaloRuntime.current }

    struct Info {
        let appURL: URL
        let version: String
        /// The API client version this runtime's official main reports (User-Agent, `?client_version=`).
        let clientVersion: String
        let asar: AsarArchive
    }

    static func locate(appURL: URL = defaultAppURL) throws -> Info {
        let asarURL = appURL.appendingPathComponent("Contents/Resources/app.asar")
        let plist = NSDictionary(contentsOf: appURL.appendingPathComponent("Contents/Info.plist"))
        let version = plist?["CFBundleShortVersionString"] as? String ?? "?"
        let asar = try AsarArchive(url: asarURL)
        let clientVersion = asar.read("main-dist/main.js").flatMap(Self.clientVersion(fromMainJS:))
            ?? ClientFingerprint.defaultClientVersion
        return Info(appURL: appURL, version: version, clientVersion: clientVersion, asar: asar)
    }

    /// `getClientVersion:function(){return 694}` in the main bundle — the number official main
    /// puts in the User-Agent and the page query. Read from the runtime so a newer installed
    /// runtime keeps reporting its own number instead of the pinned build's.
    static func clientVersion(fromMainJS data: Data) -> String? {
        guard let source = String(data: data, encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: #"getClientVersion:function\(\)\{return (\d+)\}"#),
              let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              let range = Range(match.range(at: 1), in: source) else { return nil }
        return String(source[range])
    }
}
