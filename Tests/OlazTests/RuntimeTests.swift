import Testing
import Foundation
import AppKit
@testable import Olaz

/// The bridge must reproduce Node's crypto byte-for-byte: the official renderer
/// encrypts `zcid` and request params through `$znode.crypto`. Expected values
/// were produced by Node 26 (`crypto.createCipheriv` & co.).
@MainActor
@Suite struct CryptoBridgeParity {
    private func call(_ bridge: ZaloBridge, _ path: String, _ args: [Any]) throws -> Any? {
        let body = try JSONSerialization.data(withJSONObject: ["path": path, "args": args.map { ZaloBridge.toJS($0) }])
        let response = try JSONSerialization.jsonObject(with: bridge.handleSyncRequest(body)) as! [String: Any]
        if let error = response["error"] as? String { throw ZaloBridge.BridgeError(message: error) }
        return response["value"].map(ZaloBridge.fromJS)
    }

    private func makeBridge() -> ZaloBridge {
        let bridge = ZaloBridge()
        CryptoBridge.install(on: bridge)
        return bridge
    }

    @Test func zcidEncryptMatchesNode() throws {
        let out = try call(makeBridge(), "$znode.crypto.encrypt", [
            "23,abc-imei,1792963077777", "aes-256-cbc", "3FC4F0D2AB50057BCE0D90D9187A22B1", NSNull(),
            ["key": "utf-8", "input": "utf-8", "output": "hex"],
        ])
        #expect(out as? String == "a1a69db6a344da4d883865c637f979495dd86112a4534347b462259bfdeb641b")
    }

    @Test func paramsRoundTripBase64() throws {
        let bridge = makeBridge()
        let key = "DE71B7D4C57C0749158CB90D5E431AE3"
        let encrypted = try call(bridge, "$znode.crypto.encrypt", [
            "{\"language\":\"vi\"}", "aes-256-cbc", key, NSNull(), ["key": "utf-8", "input": "utf-8", "output": "base64"],
        ])
        #expect(encrypted as? String == "V5p1S6tTwaE91W8UDCagn9vVP9wUQ3QzA04wG7xh+5E=")
        let decrypted = try call(bridge, "$znode.crypto.decrypt", [
            encrypted!, "aes-256-cbc", key, NSNull(), ["key": "utf-8", "input": "base64", "output": "utf-8"],
        ])
        #expect(decrypted as? String == "{\"language\":\"vi\"}")
    }

    @Test func streamingCTRAndGCM() throws {
        let bridge = makeBridge()
        let ctr = try call(bridge, "$znode.crypto.__cipherCreate", ["cipher", "aes-128-ctr", Data(repeating: 7, count: 16), Data(repeating: 1, count: 16)]) as! Int
        let ctrOut = try call(bridge, "$znode.crypto.__cipherUpdate", [ctr, "hello zalo ctr mode!", "utf8", "hex"]) as? String
        #expect(ctrOut == "324a84ef5fc3a21b11456b948b319aab1c6e924d")

        let gcm = try call(bridge, "$znode.crypto.__cipherCreate", ["cipher", "aes-256-gcm", Data(repeating: 3, count: 32), Data(repeating: 9, count: 12)]) as! Int
        _ = try call(bridge, "$znode.crypto.__cipherUpdate", [gcm, "gcm payload", "utf8", NSNull()])
        let sealed = try call(bridge, "$znode.crypto.__cipherFinal", [gcm, "hex"]) as? String
        #expect(sealed == "636b00fbfe1c3505e56f0c")
        let tag = try call(bridge, "$znode.crypto.__cipherOption", [gcm, "getAuthTag"]) as? Data
        #expect(tag?.map { String(format: "%02x", $0) }.joined() == "377ee9d6cfa423566629c0cfbb8eb885")
    }

    @Test func hashes() throws {
        let bridge = makeBridge()
        let h = try call(bridge, "$znode.crypto.__hashCreate", ["md5"]) as! Int
        _ = try call(bridge, "$znode.crypto.__hashUpdate", [h, "841630ae41f", NSNull()])
        #expect(try call(bridge, "$znode.crypto.__hashDigest", [h, "hex"]) as? String == "d9e97c18b27cd54e969268d9b39e8680")
        #expect(try call(bridge, "$znode.crypto.hash", ["zalo", "sha256", NSNull(), "base64"]) as? String
                == "PpYUHCFwTpavYlfqQcD8aQzgUEyFKdxCTciyRbY0PA8=")
    }

    @Test func badDecryptThrows() {
        #expect(throws: (any Error).self) {
            try call(makeBridge(), "$znode.crypto.decrypt", [
                "AAAAAAAAAAAAAAAAAAAAAA==", "aes-256-cbc", "DE71B7D4C57C0749158CB90D5E431AE3", NSNull(),
                ["key": "utf-8", "input": "base64", "output": "utf-8"],
            ])
        }
    }
}

@Suite struct AsarReading {
    /// Builds a minimal asar: header pickle + two files.
    private func makeArchive() throws -> URL {
        let files: [(String, Data)] = [("pc-dist/login.html", Data("<html>hi</html>".utf8)), ("pc-dist/lazy/a.js", Data("1+1".utf8))]
        var offset = 0
        var tree: [String: Any] = [:]
        var payload = Data()
        for (path, data) in files {
            let parts = path.split(separator: "/").map(String.init)
            func insert(_ node: inout [String: Any], _ rest: ArraySlice<String>) {
                var files = node["files"] as? [String: Any] ?? [:]
                if rest.count == 1 {
                    files[rest.first!] = ["size": data.count, "offset": String(offset)]
                } else {
                    var child = files[rest.first!] as? [String: Any] ?? [:]
                    insert(&child, rest.dropFirst())
                    files[rest.first!] = child
                }
                node["files"] = files
            }
            insert(&tree, parts[...])
            payload.append(data)
            offset += data.count
        }
        let json = try JSONSerialization.data(withJSONObject: tree)
        func u32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
        let padded = (json.count + 3) & ~3
        let headerPickle = u32(padded + 4) + u32(json.count) + json + Data(count: padded - json.count)
        let archive = u32(4) + u32(headerPickle.count) + headerPickle + payload
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-test-\(UUID()).asar")
        try archive.write(to: url)
        return url
    }

    @Test func readsFilesFromArchive() throws {
        let asar = try AsarArchive(url: try makeArchive())
        #expect(asar.read("pc-dist/login.html").map { String(decoding: $0, as: UTF8.self) } == "<html>hi</html>")
        #expect(asar.read("/pc-dist/lazy/a.js").map { String(decoding: $0, as: UTF8.self) } == "1+1")
        #expect(asar.read("pc-dist/missing.js") == nil)
        #expect(asar.paths(withPrefix: "pc-dist/lazy").count == 1)
    }

    @Test func installedZaloIsReadableWhenPresent() throws {
        guard FileManager.default.fileExists(atPath: OfficialZaloInstall.defaultAppURL.path) else { return }
        let info = try OfficialZaloInstall.locate()
        #expect(info.asar.contains("pc-dist/login.html"))
        #expect(info.asar.contains("pc-dist/index.html"))
    }
}

@MainActor
@Suite struct SessionCookies {
    /// The realtime socket (`wss://wsN-msg.chat.zalo.me`) must receive `zpw_sek`,
    /// as Electron's domain cookies did; a host-only cookie silently breaks it.
    @Test func appCookieReachesRealtimeAndAPIHosts() {
        let storage = HTTPCookieStorage.sharedCookieStorage(forGroupContainerIdentifier: "olaz.tests.\(UUID())")
        for domain in ZaloMainProcess.sessionCookieDomains {
            ZaloMainProcess.setCookie(name: "zpw_sek", value: "test", domain: domain, days: 1, httpOnly: true, storage: storage)
        }
        for host in ["https://ws5-msg.chat.zalo.me/", "https://chat.zalo.me/", "https://wpa.zaloapp.com/", "https://tt-profile-wpa.zaloapp.com/"] {
            let names = storage.cookies(for: URL(string: host)!)?.map(\.name) ?? []
            #expect(names.contains("zpw_sek"), "missing zpw_sek for \(host)")
        }
    }
}

/// The login QR reaches Swift as the official `<img>` source: a base64 PNG from the server, or (trusted-device /
/// multi-layer QR) an SVG the renderer drew itself. Before SVG decoding, QR2 was dropped and the retired QR1 stayed
/// on screen, so the phone answered "Mã QR không hợp lệ". Based on PR #3 by oolong20k.
@MainActor
@Suite struct QRDataURLDecoding {
    @Test func decodesBase64PNG() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        #expect(ZaloEngine.decodeDataURL("data:image/png;base64," + png.base64EncodedString()) == png)
    }

    @Test func decodesPercentEncodedSVGAndItRenders() throws {
        let svg = #"<svg xmlns="http://www.w3.org/2000/svg" version="1.1" width="40" height="40" viewBox="0 0 40 40"><rect width="100%" height="100%" fill="white"/><rect x="10" y="10" width="20" height="20" fill="black"/></svg>"#
        // Same encoding as the official `T()`: `data:image/svg+xml;utf8,${encodeURIComponent(svg)}`.
        let encoded = try #require(svg.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        let data = try #require(ZaloEngine.decodeDataURL("data:image/svg+xml;utf8," + encoded))
        #expect(String(decoding: data, as: UTF8.self) == svg)
        #expect(NSImage(data: data) != nil)
    }

    @Test func rejectsNonDataURLs() {
        #expect(ZaloEngine.decodeDataURL("https://example.com/qr.png") == nil)
    }
}
