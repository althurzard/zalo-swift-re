import Foundation
import os

/// Identity and header constants of the official Zalo PC build Olaz pins.
///
/// Every value here was captured passively from the official client 26.10.20
/// (Electron 22.3.9 / Chromium 108.0.5359.215) — see `reanalysis/wire-fingerprint.md`.
/// Zalo sees these on the wire, so they must match the official client exactly.
/// When the pinned Zalo release (`ZaloRuntime.pinned`) is bumped, re-capture and
/// update this together with the pin.
enum ClientFingerprint {
    /// `getClientVersion()` of the official main process, and the `?client_version=` the page
    /// query carries. Overridden at boot with the value found in the installed runtime.
    static let defaultClientVersion = "694"
    /// `type=` of the macOS client.
    static let clientType = "23"

    /// The client-hints brand list of Chromium 108 as Electron builds it (no "Google Chrome" brand).
    static let secCHUA = #""Not?A_Brand";v="8", "Chromium";v="108""#
    static let secCHUAMobile = "?0"
    static let secCHUAPlatform = #""macOS""#

    /// Chromium's Accept-Encoding; URLSession's own default omits `br`.
    static let acceptEncoding = "gzip, deflate, br"
    /// Chromium's Accept for `<img>` loads.
    static let imageAccept = "image/webp,image/apng,image/*,*/*;q=0.8"

    /// Chromium's Accept-Language built from the system's preferred languages. The official client
    /// on a single-language system sends exactly that language (e.g. `en-US`, no q-values, no
    /// base-language expansion); further entries get descending q-values.
    static func acceptLanguage(preferred: [String] = Locale.preferredLanguages) -> String {
        let languages = preferred.map { $0.replacingOccurrences(of: "_", with: "-") }
        guard !languages.isEmpty else { return "en-US" }
        return languages.enumerated().map { index, language in
            index == 0 ? language : "\(language);q=\(String(format: "%.1f", 1.0 - 0.1 * Double(index)))"
        }.joined(separator: ",")
    }

    /// The client version of the runtime in use. Set by `ZaloEngine.boot` from the installed
    /// `app.asar` (`main-dist/main.js`), so a newer installed runtime keeps reporting its own
    /// number rather than the pinned build's.
    private static let versionLock = OSAllocatedUnfairLock(initialState: defaultClientVersion)
    static var clientVersion: String {
        get { versionLock.withLock { $0 } }
        set { versionLock.withLock { $0 = newValue } }
    }

    /// The whole User-Agent official main sets: `ZaloPC-<platform>-<type>v<clientVersion>`.
    static var userAgent: String { "ZaloPC-darwin-\(clientType)v\(clientVersion)" }
}
