import XCTest
@testable import Olaz

/// The wire fingerprint the official Zalo PC client presents — captured from the
/// official app (see `reanalysis/wire-fingerprint.md`). Olaz must reproduce these
/// exactly, because Zalo sees them on every request.
final class ClientFingerprintTests: XCTestCase {

    // MARK: User-Agent / versions

    func testUserAgentFollowsRuntimeClientVersion() {
        let saved = ClientFingerprint.clientVersion
        defer { ClientFingerprint.clientVersion = saved }

        ClientFingerprint.clientVersion = "695"
        XCTAssertEqual(PinnedHTTPSClient.userAgent, "ZaloPC-darwin-23v695")
        XCTAssertEqual(ClientFingerprint.userAgent, "ZaloPC-darwin-23v695")

        ClientFingerprint.clientVersion = ClientFingerprint.defaultClientVersion
        XCTAssertEqual(ClientFingerprint.userAgent, "ZaloPC-darwin-23v\(ClientFingerprint.defaultClientVersion)")
    }

    func testClientVersionParsedFromOfficialMainBundle() {
        let main = #"x.getClientVersion:function(){return 694},MAC_CLIENT_TYPE:23,REAL_WIN_CLIENT_TYPE:24"#.data(using: .utf8)!
        XCTAssertEqual(OfficialZaloInstall.clientVersion(fromMainJS: main), "694")

        // A different runtime must report its own number, not ours.
        let newer = "…getClientVersion:function(){return 701},getComputerName…".data(using: .utf8)!
        XCTAssertEqual(OfficialZaloInstall.clientVersion(fromMainJS: newer), "701")

        // Nothing recognizable: the caller falls back to the pinned default.
        XCTAssertNil(OfficialZaloInstall.clientVersion(fromMainJS: Data("getClientVersion".utf8)))
        XCTAssertNil(OfficialZaloInstall.clientVersion(fromMainJS: Data()))
    }

    // MARK: Accept-Language

    func testAcceptLanguageSingleEntryHasNoQValues() {
        // Ground truth from the official app on a single-language system.
        XCTAssertEqual(ClientFingerprint.acceptLanguage(preferred: ["en-US"]), "en-US")
        XCTAssertEqual(ClientFingerprint.acceptLanguage(preferred: ["vi-VN"]), "vi-VN")
    }

    func testAcceptLanguageMultipleEntriesDescendByTenth() {
        XCTAssertEqual(ClientFingerprint.acceptLanguage(preferred: ["vi-VN", "en-US"]),
                       "vi-VN,en-US;q=0.9")
        XCTAssertEqual(ClientFingerprint.acceptLanguage(preferred: ["vi-VN", "vi", "en-US"]),
                       "vi-VN,vi;q=0.9,en-US;q=0.8")
        XCTAssertFalse(ClientFingerprint.acceptLanguage(preferred: []).isEmpty)
    }

    // MARK: Multipart boundary

    func testFormBoundaryMatchesChromiumFormat() {
        for _ in 0..<5 {
            let boundary = NetworkProxy.chromiumFormBoundary()
            XCTAssertNotNil(boundary.range(of: #"^----WebKitFormBoundary[0-9A-Za-z]{16}$"#, options: .regularExpression),
                            "boundary not in Chromium's format: \(boundary)")
        }
        // 16 chars of a 62-char alphabet: collisions in a handful of draws are ~impossible.
        XCTAssertNotEqual(NetworkProxy.chromiumFormBoundary(), NetworkProxy.chromiumFormBoundary())
    }

    // MARK: Proxied request headers

    func testProxiedRequestsGetTheOfficialHeaderSet() throws {
        var request = URLRequest(url: URL(string: "https://wpa.zaloapp.com/api/login/getServerInfo")!)
        // The page (axios) sets these two; the rest must come from the fingerprint.
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        NetworkProxy.applyClientHeaders(to: &request)

        // `value(forHTTPHeaderField:)` is case-insensitive; URLRequest canonicalizes the case
        // of well-known names in `allHTTPHeaderFields`, which says nothing about the wire
        // (HTTP/2 lowercases everything anyway).
        func header(_ name: String) -> String? { request.value(forHTTPHeaderField: name) }
        XCTAssertEqual(header("sec-ch-ua"), ClientFingerprint.secCHUA)
        XCTAssertEqual(header("sec-ch-ua"), #""Not?A_Brand";v="8", "Chromium";v="108""#)
        XCTAssertEqual(header("sec-ch-ua-mobile"), "?0")
        XCTAssertEqual(header("sec-ch-ua-platform"), #""macOS""#)
        XCTAssertEqual(header("sec-fetch-dest"), "empty")
        XCTAssertEqual(header("sec-fetch-mode"), "cors")
        XCTAssertEqual(header("sec-fetch-site"), "cross-site")
        XCTAssertEqual(header("accept-encoding"), "gzip, deflate, br")
        XCTAssertEqual(header("accept-language"), ClientFingerprint.acceptLanguage())
        // Page-set headers survive untouched.
        XCTAssertEqual(header("Accept"), "application/json, text/plain, */*")
        // The official client sends neither on the wire.
        XCTAssertNil(header("Origin"))
        XCTAssertNil(header("Referer"))
    }

    // MARK: Node os.* parity

    func testHostnameIsGetHostnameNotProcessInfo() {
        // gethostname() returns the casing macOS reports (e.g. "Quans-MacBook-Pro.local");
        // ProcessInfo.hostName lower-cases it on this machine and would disagree with
        // Node's os.hostname(), which is what the official client sends as computer_name.
        let hostname = BridgeImplementation.hostname()
        XCTAssertFalse(hostname.isEmpty)
        var expected = [CChar](repeating: 0, count: 256)
        gethostname(&expected, 256)
        let node = String(cString: expected)
        if !node.isEmpty { XCTAssertEqual(hostname, node) }
    }

    func testNetworkInterfacesMatchNodeShape() throws {
        let json = BridgeImplementation.networkInterfacesJSON()
        let data = try XCTUnwrap(json.data(using: .utf8))
        let pairs = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[Any]])
        XCTAssertFalse(pairs.isEmpty, "getifaddrs always reports at least lo0")

        var sawLoopback = false, sawIPv4 = false
        for pair in pairs {
            let name = try XCTUnwrap(pair.first as? String)
            let addresses = try XCTUnwrap(pair.last as? [[String: Any]])
            XCTAssertFalse(name.isEmpty)
            for entry in addresses {
                XCTAssertEqual(entry["mac"] is String, true)
                let family = try XCTUnwrap(entry["family"] as? String)
                XCTAssertTrue(family == "IPv4" || family == "IPv6")
                XCTAssertFalse((entry["address"] as? String ?? "").isEmpty)
                let internalAddress = try XCTUnwrap(entry["internal"] as? Bool)
                if name == "lo0" && internalAddress { sawLoopback = true }
                if family == "IPv4" { sawIPv4 = true }
            }
        }
        XCTAssertTrue(sawLoopback, "lo0 must be present and internal")
        XCTAssertTrue(sawIPv4, "at least one IPv4 address (QoS local IP depends on it)")
    }

    func testNetworkInterfacesOrderSurvivesTheJSONRoundTrip() throws {
        // The official QoS code takes the FIRST non-internal IPv4 as the local IP,
        // so the order getifaddrs reported must survive serialization.
        let json = BridgeImplementation.networkInterfacesJSON()
        let pairs = try XCTUnwrap(JSONSerialization.jsonObject(with: json.data(using: .utf8)!) as? [[Any]])
        let names = pairs.compactMap { $0.first as? String }
        XCTAssertEqual(names, names)
        XCTAssertTrue(names.contains("lo0"), "lo0 is always the first interface macOS reports")
        if names.count > 1 { XCTAssertEqual(names.first, "lo0") }
    }

    // MARK: Media request flavours

    func testImageRequestCarriesImageFlavour() throws {
        var request = URLRequest(url: URL(string: "https://res-zalo.zadn.vn/upload/media/a.png")!)
        MediaLoader.applyClientHeaders(to: &request, flavour: .image)
        let headers = request.allHTTPHeaderFields ?? [:]
        XCTAssertEqual(headers["Accept"], ClientFingerprint.imageAccept)
        XCTAssertEqual(headers["sec-fetch-dest"], "image")
        XCTAssertEqual(headers["sec-fetch-mode"], "no-cors")
        XCTAssertEqual(headers["sec-fetch-site"], "cross-site")
        XCTAssertEqual(headers["User-Agent"], ClientFingerprint.userAgent)
    }

    func testCorsRequestCarriesFetchFlavour() throws {
        var request = URLRequest(url: URL(string: "https://zt-launcher.zadn.vn/file")!)
        request.setValue("cloud-viewer-key: x", forHTTPHeaderField: "X-Ignore")   // caller headers first
        MediaLoader.applyClientHeaders(to: &request, flavour: .cors)
        let headers = request.allHTTPHeaderFields ?? [:]
        XCTAssertEqual(headers["Accept"], "*/*")
        XCTAssertEqual(headers["sec-fetch-dest"], "empty")
        XCTAssertEqual(headers["sec-fetch-mode"], "cors")
        XCTAssertEqual(headers["X-Ignore"], "cloud-viewer-key: x")
    }

    func testPinnedClientHeaderDictOmitsAcceptEncoding() {
        // PinnedHTTPSClient speaks HTTP/1.1 and parses the framing itself: it must
        // never ask for a compressed body.
        let headers = MediaLoader.clientHeaders(.image)
        XCTAssertNil(headers["accept-encoding"])
        XCTAssertEqual(headers["sec-ch-ua"], ClientFingerprint.secCHUA)
    }
}
