import CryptoKit
import Foundation
import os

private let asarLog = Logger(subsystem: "app.olaz", category: "asar")

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
        /// Electron's per-file `integrity.hash` (SHA-256 hex of the whole file), when the header carries one.
        let sha256: String?
    }

    enum AsarError: LocalizedError {
        case unreadable(URL)
        case badHeader
        case integrity(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let url): "Không đọc được \(url.path)"
            case .badHeader: "app.asar không hợp lệ"
            case .integrity(let why): "app.asar không khớp mã kiểm tra (\(why))"
            }
        }
    }

    let url: URL
    private let data: Data
    private let base: Int
    private var entries: [String: Entry] = [:]
    /// SHA-256 (hex) of the header JSON: what Electron's `ElectronAsarIntegrity` (Info.plist, signed by VNG) pins.
    let headerSHA256: String

    init(url: URL) throws {
        self.url = url
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else {
            throw AsarError.unreadable(url)
        }
        self.data = data
        guard data.count > 16 else { throw AsarError.badHeader }
        let headerPickleSize = Int(data.u32(at: 4))
        let jsonLength = Int(data.u32(at: 12))
        guard 16 + jsonLength <= data.count else { throw AsarError.badHeader }
        let header = data.subdata(in: 16..<(16 + jsonLength))
        guard let json = try? JSONSerialization.jsonObject(with: header) as? [String: Any] else { throw AsarError.badHeader }
        headerSHA256 = Self.hex(SHA256.hash(data: header))
        base = 8 + headerPickleSize
        index(json, prefix: "")
    }

    static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }

    /// SHA-256 (hex) of the whole archive file.
    func fileSHA256() -> String { Self.hex(SHA256.hash(data: data)) }

    private func index(_ node: [String: Any], prefix: String) {
        guard let files = node["files"] as? [String: Any] else { return }
        for (name, value) in files {
            guard let child = value as? [String: Any] else { continue }
            let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
            if child["files"] != nil {
                index(child, prefix: path)
            } else if let size = (child["size"] as? NSNumber)?.intValue {
                let offset = Int((child["offset"] as? String) ?? "0") ?? 0
                let integrity = child["integrity"] as? [String: Any]
                let sha = (integrity?["algorithm"] as? String)?.uppercased() == "SHA256" ? (integrity?["hash"] as? String)?.lowercased() : nil
                entries[path] = Entry(offset: offset, size: size, unpacked: child["unpacked"] as? Bool ?? false, sha256: sha)
            }
        }
    }

    func contains(_ path: String) -> Bool { entries[normalize(path)] != nil }

    /// Bytes of a file inside the archive, e.g. `pc-dist/login.html`. Checked against the header's per-file
    /// integrity hash (the header itself is pinned by `OfficialZaloInstall.verifyIntegrity`): a file whose bytes
    /// changed after install is not served (nil → 404).
    func read(_ path: String) -> Data? {
        let key = normalize(path)
        guard let entry = entries[key] else { return nil }
        let bytes: Data?
        if entry.unpacked {
            let unpackedURL = url.deletingLastPathComponent()
                .appendingPathComponent("app.asar.unpacked")
                .appendingPathComponent(key)
            bytes = try? Data(contentsOf: unpackedURL)
        } else {
            let start = base + entry.offset
            guard start + entry.size <= data.count else { return nil }
            bytes = data.subdata(in: start..<(start + entry.size))
        }
        guard let bytes else { return nil }
        if let expected = entry.sha256, Self.hex(SHA256.hash(data: bytes)) != expected {
            asarLog.fault("integrity mismatch, not served: \(key, privacy: .public)")
            return nil
        }
        return bytes
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
        try verifyIntegrity(of: asar, plist: plist)
        let clientVersion = asar.read("main-dist/main.js").flatMap(Self.clientVersion(fromMainJS:))
            ?? ClientFingerprint.defaultClientVersion
        return Info(appURL: appURL, version: version, clientVersion: clientVersion, asar: asar)
    }

    /// Sidecar holding the archive's SHA-256, written by the first verified load of a freshly installed runtime.
    /// It lives inside the runtime folder on purpose: every install / upgrade replaces that folder wholesale
    /// (`ZaloRuntimeInstaller.stage`, `prepareForLaunch`), so a new runtime starts without one.
    static func hashRecordURL(for asar: URL) -> URL {
        asar.deletingLastPathComponent().appendingPathComponent("app.asar.olaz-sha256")
    }

    /// Load-time check of `app.asar` (issue #1.4: it was only verified at install, through VNG's code signature):
    /// 1. the header hash must equal `ElectronAsarIntegrity` from the runtime's Info.plist (VNG-signed data, checked
    ///    at install); per-file hashes in that header are then checked on every `read`;
    /// 2. the whole file must equal the SHA-256 recorded at the first verified load (recorded now when absent).
    /// Throws on mismatch: the host is not created and `ZaloEngine.start` falls back to reinstalling the runtime.
    static func verifyIntegrity(of asar: AsarArchive, plist: NSDictionary?) throws {
        func refuse(_ why: String) -> AsarArchive.AsarError {
            asarLog.fault("app.asar refused: \(why, privacy: .public)")
            Task { @MainActor in EngineLog.shared.write("runtime: app.asar refused (\(why))") }
            return .integrity(why)
        }
        let pinned = (plist?["ElectronAsarIntegrity"] as? [String: Any])?["Resources/app.asar"] as? [String: Any]
        if let expected = (pinned?["hash"] as? String)?.lowercased(),
           ((pinned?["algorithm"] as? String)?.uppercased() ?? "SHA256") == "SHA256",
           asar.headerSHA256 != expected {
            throw refuse("header hash ≠ ElectronAsarIntegrity")
        }
        let record = hashRecordURL(for: asar.url)
        let actual = asar.fileSHA256()
        if let stored = (try? String(contentsOf: record, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines),
           !stored.isEmpty {
            guard stored.lowercased() == actual else { throw refuse("file hash ≠ recorded \(record.lastPathComponent)") }
        } else {
            do {
                try Data((actual + "\n").utf8).write(to: record, options: .atomic)
                asarLog.info("app.asar hash recorded")
            } catch {
                asarLog.error("app.asar hash not recorded: \(error.localizedDescription, privacy: .public)")
            }
        }
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
