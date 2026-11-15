import Foundation

// zCloud ("Zalo Cloud" sidebar tab of the official client): storage quota & usage, plan, browsing the media /
// files stored in the cloud, download, delete, auto-free-up setting. Bridged to `HostScripts/zcloud-adapter.js`
// (`window.__zaloCloud`; posts {page:'main', zcloud:{…}} — each key replaces that section). Every call runs through
// the official client's own cloud services (see the adapter header).

enum CloudItemKind: String, Sendable, CaseIterable {
    case photo, video, file, voice, other

    var title: String {
        switch self {
        case .photo: "Ảnh"
        case .video: "Video"
        case .file: "File"
        case .voice: "Tin nhắn thoại"
        case .other: "Khác"
        }
    }

    var symbol: String {
        switch self {
        case .photo: "photo.fill"
        case .video: "play.rectangle.fill"
        case .file: "doc.fill"
        case .voice: "waveform"
        case .other: "questionmark.square.fill"
        }
    }
}

/// One media / file item stored in zCloud, as the official ZCloud table describes it.
struct CloudItem: Identifiable, Hashable, Sendable {
    /// Official `zKey`; the adapter resolves items by it.
    let id: String
    let kind: CloudItemKind
    let conversationId: String
    let conversationName: String
    let size: Int64
    let date: Date?
    /// File name as sent (empty for photos / videos / voice messages).
    let title: String
    let ext: String
    let duration: TimeInterval
    let width: Int
    let height: Int
}

struct CloudPage: Sendable {
    var items: [CloudItem] = []
    var hasMore = false
    var error: String?
}

/// Bytes per category (official usage legend: Ảnh / Video / File / Tin nhắn thoại).
struct CloudBreakdown: Equatable, Sendable {
    var photo: Int64 = 0
    var video: Int64 = 0
    var file: Int64 = 0
    var voice: Int64 = 0
    var total: Int64 { photo + video + file + voice }

    func bytes(_ kind: CloudItemKind) -> Int64 {
        switch kind {
        case .photo: photo
        case .video: video
        case .file: file
        case .voice: voice
        case .other: 0
        }
    }
}

struct CloudState: Equatable {
    enum PlanKind: String, Sendable {
        /// Paid zCloud subscription.
        case paid
        /// Free "Cloud của tôi" only.
        case free
        /// Subscription lapsed, data still downloadable for a while.
        case grace
        /// Free again after the grace period.
        case afterGrace
    }

    struct Plan: Equatable, Sendable {
        var kind: PlanKind
        var name: String
        var quota: Int64
        var usage: Int64
        /// Other family members' usage.
        var family: Int64
        var cloudMedia: Int64
        var messageBackup: Int64
        var myCloud: Int64
        var expireAt: Date?
        /// nil when the server does not say.
        var autoRenew: Bool?
        var months: Int
        /// The personal cloud key (from the phone) is available, so contents can be decrypted.
        var hasKey: Bool
        /// What the phone's storage settings back up automatically (cloud-settings `opt_in`).
        var backupMedia: Bool
        var backupMyCloud: Bool
        var backupMessages: Bool
        var fileLimit: Int64

        var remaining: Int64 { max(0, quota - usage - family) }
        var isPaid: Bool { kind == .paid || kind == .grace }
    }

    struct Conversation: Identifiable, Hashable, Sendable {
        let id: String
        let name: String
        let avatar: URL?
        let isGroup: Bool
        let total: Int64
        let lastActivity: Date?
    }

    struct Settings: Equatable, Sendable {
        var offloadEnabled = false
        /// Plan, cloud key and server flag all allow the feature.
        var offloadAvailable = false
        var lastOffloadAt: Date?
        var lastOffloadSize: Int64 = 0
        var ttlDays = 0
    }

    var plan: Plan?
    var media = CloudBreakdown()
    var myCloudTypes = CloudBreakdown()
    var conversations: [Conversation] = []
    var settings = Settings()
    /// Bumped by the adapter whenever cloud items were added / removed.
    var changed = 0
    var loaded = false
    /// False when the official hidden-chat lookup was not found: conversation-grouped data is withheld (fail closed).
    var hiddenLookup = true
    /// Official My Cloud (send-to-me) conversation id.
    var selfId: String?
}

enum CloudFetch: Sendable {
    case ready(CloudFile)
    case expired
    case failed(String)
}

/// A cloud item downloaded (through the official path) to the official zCloud cache.
struct CloudFile: Sendable {
    let url: URL
    let kind: CloudItemKind
    let title: String
    let ext: String
    let size: Int64
    let date: Date?
}

struct CloudActionResult: Sendable {
    var ok: Bool
    /// Keys actually deleted / not deleted (delete only).
    var deleted: [String] = []
    var failed: [String] = []
    var error: String?
    /// No answer (timeout / page reload): the write may still have happened — check again, don't retry blindly.
    var pending = false
}

extension ZaloEngine {
    // MARK: Actions

    /// Re-reads plan / usage / conversations from the official services.
    func refreshCloud() { callChat("refresh", object: "__zaloCloud") }

    /// One page of items (official `filterAndSort`, 60 per page by default).
    func cloudList(conversationId: String?, kind: CloudItemKind?, sortBySize: Bool, ascending: Bool, offset: Int, limit: Int = 60) async -> CloudPage {
        let options: [String: Any] = [
            "convId": conversationId ?? "", "kind": kind?.rawValue ?? "", "sort": sortBySize ? "size" : "date",
            "dir": ascending ? "asc" : "desc", "offset": offset, "limit": limit,
        ]
        guard let json = await callCloud("list", options) as? [String: Any] else {
            return CloudPage(items: [], hasMore: false, error: "Chưa kết nối được tới zCloud.")
        }
        let rows = (json["items"] as? [[String: Any]] ?? []).compactMap(Self.cloudItem)
        return CloudPage(items: rows, hasMore: json["hasMore"] as? Bool ?? false, error: json["error"] as? String)
    }

    /// A local file to draw the item's thumbnail from (photo: the image itself; video: the video).
    func cloudThumbnail(for key: String) async -> MediaResolution {
        guard let json = await callCloud("thumb", key) as? [String: Any] else { return .unavailable }
        return MediaResolution(json: json)
    }

    /// Downloads the whole item through the official downloader (cached in the official zCloud folder).
    func cloudFetch(_ key: String) async -> CloudFetch {
        guard let json = await callCloud("fetch", key) as? [String: Any] else { return .failed("Chưa kết nối được tới zCloud.") }
        switch json["state"] as? String {
        case "ok":
            guard let path = json["path"] as? String, path.hasPrefix("/") else { return .failed("Không tìm thấy tệp đã tải.") }
            let ms = (json["date"] as? NSNumber)?.doubleValue ?? 0
            return .ready(CloudFile(
                url: URL(fileURLWithPath: path), kind: CloudItemKind(rawValue: json["kind"] as? String ?? "") ?? .other,
                title: json["title"] as? String ?? "", ext: json["ext"] as? String ?? "",
                size: (json["size"] as? NSNumber)?.int64Value ?? 0, date: ms > 0 ? Date(timeIntervalSince1970: ms / 1000) : nil))
        case "expired": return .expired
        default: return .failed("Không tải được nội dung này lúc này. Vui lòng thử lại sau.")
        }
    }

    /// WRITE: removes the items the way the official "Xoá dữ liệu" confirmation does (sync-delete of the messages).
    func cloudDelete(_ keys: [String]) async -> CloudActionResult {
        switch await cloudWrite("deleteItems", keys) {
        case .notConnected:
            return CloudActionResult(ok: false, failed: keys, error: Self.cloudNotConnectedText)
        case .unknown:
            // Nothing is known as failed: the caller reloads the list (the truth) instead of offering a retry.
            return CloudActionResult(ok: false, error: CardActionOutcome.noAnswerText, pending: true)
        case .answer(let json):
            return CloudActionResult(ok: json["ok"] as? Bool ?? false, deleted: json["deleted"] as? [String] ?? [],
                                     failed: json["failed"] as? [String] ?? [],
                                     error: (json["error"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    /// WRITE: Settings ▸ "Tự động giải phóng dung lượng" (official `changeEnableOffload`).
    func cloudSetOffload(_ enabled: Bool) async -> CloudActionResult {
        switch await cloudWrite("setOffload", enabled) {
        case .notConnected: return CloudActionResult(ok: false, error: Self.cloudNotConnectedText)
        case .unknown: return CloudActionResult(ok: false, error: CardActionOutcome.noAnswerText, pending: true)
        case .answer(let json): return CloudActionResult(ok: json["ok"] as? Bool ?? false, error: json["error"] as? String)
        }
    }

    private static let cloudNotConnectedText = "Chưa kết nối được tới zCloud."
    /// Swift-side cap on one zCloud write.
    private static let cloudWriteTimeout: Double = 90

    private enum CloudWriteAnswer {
        case answer([String: Any])
        /// Nothing was started (no page / adapter not installed).
        case notConnected
        /// No answer in time, or the call threw (page reloaded): the write may still have happened.
        case unknown
    }

    /// A zCloud WRITE with a bounded wait that tells "never started" from "started, outcome unknown".
    private func cloudWrite(_ method: String, _ args: Any) async -> CloudWriteAnswer {
        guard let host, let data = try? JSONSerialization.data(withJSONObject: [args], options: [.fragmentsAllowed]),
              let json = String(data: data, encoding: .utf8) else { return .notConnected }
        let script = "const c = window.__zaloCloud; if (!c || !c.\(method)) return 'missing'; return await c.\(method)(...\(json));"
        let answer = await raceTimeout(Self.cloudWriteTimeout) { JSBox(value: await host.evaluate(script)) }
        guard let value = answer?.value else {
            EngineLog.shared.write("cloud \(method) → no answer (pending)")
            return .unknown
        }
        guard let dict = value as? [String: Any] else { return .notConnected }   // 'missing' or an unexpected shape
        return .answer(dict)
    }

    /// `await window.__zaloCloud[method](...args)`; arguments are JSON-encoded.
    private func callCloud(_ method: String, _ args: Any...) async -> Any? {
        guard let host, let data = try? JSONSerialization.data(withJSONObject: args, options: [.fragmentsAllowed]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        let script = "const c = window.__zaloCloud; if (!c || !c.\(method)) return null; return await c.\(method)(...\(json));"
        return await host.evaluate(script)
    }

    /// Sign-out: drop everything zCloud kept (state, thumbnails, staged previews of the previous account).
    func resetCloud() {
        cloud = CloudState()
        CloudThumbnails.shared.reset()
        CloudFiles.purgeAll()
    }

    // MARK: State

    func handleCloud(state: [String: Any]) {
        guard let json = state["zcloud"] as? [String: Any] else { return }
        var next = cloud
        func int(_ value: Any?) -> Int64 { (value as? NSNumber)?.int64Value ?? 0 }
        func date(_ value: Any?) -> Date? {
            let ms = (value as? NSNumber)?.doubleValue ?? 0
            return ms > 0 ? Date(timeIntervalSince1970: ms / 1000) : nil
        }
        func breakdown(_ value: Any?) -> CloudBreakdown {
            let d = value as? [String: Any] ?? [:]
            return CloudBreakdown(photo: int(d["photo"]), video: int(d["video"]), file: int(d["file"]), voice: int(d["voice"]))
        }
        if let id = json["selfId"] as? String, !id.isEmpty { next.selfId = id }
        if let p = json["plan"] as? [String: Any] {
            let optIn = p["optIn"] as? [String: Any] ?? [:]
            next.plan = CloudState.Plan(
                kind: CloudState.PlanKind(rawValue: p["kind"] as? String ?? "") ?? .free,
                name: p["name"] as? String ?? "zCloud",
                quota: int(p["quota"]), usage: int(p["usage"]), family: int(p["family"]),
                cloudMedia: int(p["cloudMedia"]), messageBackup: int(p["messageBackup"]), myCloud: int(p["myCloud"]),
                expireAt: date(p["expireAt"]), autoRenew: p["autoRenew"] as? Bool, months: Int(int(p["months"])),
                hasKey: p["hasKey"] as? Bool ?? false,
                backupMedia: optIn["media"] as? Bool ?? false, backupMyCloud: optIn["myCloud"] as? Bool ?? false,
                backupMessages: optIn["backup"] as? Bool ?? false, fileLimit: int(p["fileLimit"]))
        }
        if let t = json["types"] as? [String: Any] {
            next.media = breakdown(t["media"])
            next.myCloudTypes = breakdown(t["myCloud"])
        }
        if let rows = json["conversations"] as? [[String: Any]] {
            next.conversations = rows.compactMap { row in
                guard let id = row["id"] as? String, !id.isEmpty else { return nil }
                let avatar = (row["avatar"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
                return CloudState.Conversation(id: id, name: row["name"] as? String ?? "", avatar: avatar,
                                               isGroup: row["isGroup"] as? Bool ?? false, total: int(row["total"]),
                                               lastActivity: date(row["lastTs"]))
            }
        }
        if let s = json["settings"] as? [String: Any] {
            next.settings = CloudState.Settings(
                offloadEnabled: s["offloadEnabled"] as? Bool ?? false, offloadAvailable: s["offloadAvailable"] as? Bool ?? false,
                lastOffloadAt: date(s["lastOffloadAt"]), lastOffloadSize: int(s["lastOffloadSize"]),
                ttlDays: Int(int(s["ttlDays"])))
        }
        if let changed = (json["changed"] as? NSNumber)?.intValue { next.changed = changed }
        if json["loaded"] as? Bool == true { next.loaded = true }
        if let lookup = json["hiddenLookup"] as? Bool { next.hiddenLookup = lookup }
        if next != cloud { cloud = next }
    }

    private static func cloudItem(_ json: [String: Any]) -> CloudItem? {
        guard let key = json["key"] as? String, !key.isEmpty else { return nil }
        let ms = (json["date"] as? NSNumber)?.doubleValue ?? 0
        return CloudItem(
            id: key, kind: CloudItemKind(rawValue: json["kind"] as? String ?? "") ?? .other,
            conversationId: json["conv"] as? String ?? "", conversationName: json["convName"] as? String ?? "",
            size: (json["size"] as? NSNumber)?.int64Value ?? 0, date: ms > 0 ? Date(timeIntervalSince1970: ms / 1000) : nil,
            title: json["title"] as? String ?? "", ext: json["ext"] as? String ?? "",
            duration: ((json["duration"] as? NSNumber)?.doubleValue ?? 0) / 1000,
            width: (json["width"] as? NSNumber)?.intValue ?? 0, height: (json["height"] as? NSNumber)?.intValue ?? 0)
    }
}
