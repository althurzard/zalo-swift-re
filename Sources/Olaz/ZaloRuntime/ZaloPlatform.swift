import Foundation
import os

private let platformLog = Logger(subsystem: "app.olaz", category: "platform")

/// Host-side state the bridge exposes to the renderer: data directories, the
/// device identity (`imei`), electron-store files, client constants.
///
/// Olaz keeps its own data directory — it never touches the official
/// app's `~/Library/Application Support/ZaloData`.
@MainActor
final class ZaloPlatform {
    /// Values the Electron main process passes to renderer pages.
    struct ClientIdentity {
        /// `type` query parameter of the macOS client.
        var clientType = ClientFingerprint.clientType
        var clientVersion = ClientFingerprint.defaultClientVersion
    }

    let appVersion: String
    let identity: ClientIdentity
    let userData: URL
    let fileManager = FileManager.default

    init(appVersion: String,
         clientVersion: String = ClientFingerprint.defaultClientVersion,
         userData: URL = ZaloPlatform.defaultUserData) {
        self.appVersion = appVersion
        self.identity = ClientIdentity(clientType: ClientFingerprint.clientType, clientVersion: clientVersion)
        self.userData = userData
        try? fileManager.createDirectory(at: userData, withIntermediateDirectories: true)
    }

    nonisolated static var defaultUserData: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Olaz/ZaloData", isDirectory: true)
    }

    /// Stable per-install device id (the official client calls it `imei`).
    var imei: String {
        let key = "olaz.imei"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = UUID().uuidString.lowercased()
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }

    /// Electron `app.getPath(name)`.
    func path(_ name: String) -> String {
        let fm = fileManager
        switch name {
        case "userData", "appData":
            return userData.path
        case "temp":
            return fm.temporaryDirectory.appendingPathComponent("Olaz").path
        case "home":
            return fm.homeDirectoryForCurrentUser.path
        case "downloads":
            return fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0].path
        case "documents":
            return fm.urls(for: .documentDirectory, in: .userDomainMask)[0].path
        case "desktop":
            return fm.urls(for: .desktopDirectory, in: .userDomainMask)[0].path
        case "pictures":
            return fm.urls(for: .picturesDirectory, in: .userDomainMask)[0].path
        case "logs":
            return userData.appendingPathComponent("logs").path
        default:
            platformLog.notice("getPath(\(name, privacy: .public)) → userData")
            return userData.path
        }
    }

    // MARK: electron-store files (<userData>/<name>.json)

    func storeURL(_ name: String) -> URL {
        let safe = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "..", with: "_")
        return userData.appendingPathComponent("\(safe).json")
    }

    func readStore(_ name: String) -> [String: Any] {
        guard let data = try? Data(contentsOf: storeURL(name)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    func writeStore(_ name: String, _ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: storeURL(name), options: .atomic)
    }

    /// The renderer may only touch files inside our data/temp directories
    /// (plus reads of files the user explicitly picked, which arrive as absolute paths).
    func isWritable(_ path: String) -> Bool {
        // Symlinks are resolved on both sides first: a link inside an allowed folder must not lead out of it.
        // (The longest existing ancestor is resolved; components that do not exist yet cannot be links.)
        func canonical(_ path: String) -> String {
            var url = URL(fileURLWithPath: path).standardizedFileURL
            var rest: [String] = []
            while url.path != "/", !FileManager.default.fileExists(atPath: url.path) {
                rest.insert(url.lastPathComponent, at: 0)
                url = url.deletingLastPathComponent()
            }
            var resolved = url.resolvingSymlinksInPath()
            for part in rest { resolved.appendPathComponent(part) }
            return resolved.standardizedFileURL.path
        }
        let resolved = canonical(path)
        // Zalo saves received files under the user's Downloads folder by default.
        return [userData.path, self.path("temp"), self.path("downloads")].map(canonical).contains { resolved == $0 || resolved.hasPrefix($0 + "/") }
    }
}
