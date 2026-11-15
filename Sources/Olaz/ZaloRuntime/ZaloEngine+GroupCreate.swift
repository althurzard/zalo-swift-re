import AppKit
import ImageIO
import UniformTypeIdentifiers

// "Tạo nhóm": the official group compose (modal CREATE_GROUP_COMPOSE) as a native sheet, `Views/CreateGroupSheet.swift`. The picker
// list, the selection rules and the group photo are built here from what the engine already has, the way the official picker builds
// them; creating goes through `HostScripts/group-create-adapter.js` (`window.__zaloGroupCreate`), which runs the official quota check,
// `createGroupV2`, the open of the new conversation, its summary messages and the avatar upload (see the adapter header).

/// Asks the shell to show the compose sheet, with the people already picked (the 1:1 inspector's "Tạo nhóm" starts with that friend).
struct GroupComposeRequest: Identifiable, Equatable {
    let id = UUID()
    var members: [String] = []
}

/// Limits of the official compose (`info()`): `settings.group.max_member`, `group_config`, and the blocked friends.
struct GroupCreateLimits: Equatable, Sendable {
    var maxMembers = 100
    var maxNameLength = 50
    /// `group_config.group_name_regex` (JavaScript source): a name it matches is refused (STR_GROUP_NAME_INVALID).
    var namePattern = "`|~|!|@|#|%|\\*|\\^|\\$"
    var blocked: Set<String> = []
    /// Friends that are official accounts (`isOAType`): never among the recent chats.
    var officialAccounts: Set<String> = []

    init() {}

    init?(json: Any?) {
        guard let root = json as? [String: Any], root["status"] as? String == "ok" else { return nil }
        if let max = (root["maxMembers"] as? NSNumber)?.intValue, max > 0 { maxMembers = max }
        if let length = (root["maxNameLength"] as? NSNumber)?.intValue, length > 0 { maxNameLength = length }
        if let pattern = root["nameRegex"] as? String, !pattern.isEmpty { namePattern = pattern }
        blocked = Set((root["blocked"] as? [Any] ?? []).compactMap { $0 as? String })
        officialAccounts = Set((root["officialAccounts"] as? [Any] ?? []).compactMap { $0 as? String })
    }

    /// The compose's `onChangeGroupName` check. A pattern NSRegularExpression cannot read lets the name through: the renderer checks again.
    func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, let regex = try? NSRegularExpression(pattern: namePattern) else { return true }
        return regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) == nil
    }

    /// The name field's `maxLength` (UTF-16 units, like the HTML input).
    func clampedName(_ name: String) -> String {
        guard name.utf16.count > maxNameLength else { return name }
        var result = ""
        for character in name {
            if result.utf16.count + String(character).utf16.count > maxNameLength { break }
            result.append(character)
        }
        return result
    }

    /// STR_MAX_MEM_TOAST.
    var overLimitText: String { "Bạn chỉ có thể tạo nhóm với \(maxMembers) người khác" }
    static let blockedText = "Bỏ chặn để thêm người này"            // STR_UNBLOCK_TO_ADD_TO_GROUP
    static let invalidNameText = "Tên nhóm chứa ký tự không hợp lệ. Vui lòng thử lại."   // STR_GROUP_NAME_INVALID
}

/// The people the compose lists (official member picker `W`): "Trò chuyện gần đây" = the 5 latest 1:1 conversations with friends that
/// are not official accounts, then every friend by name. Hidden chats and My Cloud never show up.
struct GroupComposeRoster: Equatable {
    struct Person: Identifiable, Equatable {
        let id: String
        let name: String
        let avatar: URL?
        let section: String
        let sortKey: String
        /// Folded Zalo name (search matches it too, like the friends list).
        let zaloKey: String
    }

    static let recentLimit = 5
    var recent: [Person] = []
    var friends: [Person] = []

    init(friends source: [ContactsState.Friend], conversations: [ZaloEngine.ConversationSummary], selfId: String?,
         officialAccounts: Set<String> = []) {
        let people = source.map(Self.person(_:))
        let byId = Dictionary(people.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Same order as the friends list: letters A–Z, "#" last, names in a section by their folded form.
        friends = people.sorted { lhs, rhs in
            if lhs.section != rhs.section {
                if lhs.section == "#" { return false }
                if rhs.section == "#" { return true }
                return lhs.section < rhs.section
            }
            return lhs.sortKey.localizedStandardCompare(rhs.sortKey) == .orderedAscending
        }
        let latest = conversations.filter { !$0.isGroup && $0.id != selfId && byId[$0.id] != nil && !officialAccounts.contains($0.id) }
            .sorted { ($0.preview?.date ?? .distantPast) > ($1.preview?.date ?? .distantPast) }
        recent = latest.prefix(Self.recentLimit).compactMap { byId[$0.id] }
    }

    func person(_ id: String) -> Person? { friends.first { $0.id == id } }

    /// A friend the list leaves out (hidden chat), for the chip of a pick handed in by the caller.
    static func person(_ id: String, in friends: [ContactsState.Friend]) -> Person? {
        friends.first { $0.id == id }.map(person(_:))
    }

    private static func person(_ friend: ContactsState.Friend) -> Person {
        Person(id: friend.id, name: friend.name.isEmpty ? "Người dùng Zalo" : friend.name, avatar: friend.avatar, section: friend.section,
               sortKey: friend.sortKey, zaloKey: ZaloEngine.contactFold(friend.zaloName))
    }

    /// Friends whose name contains `query` (case, diacritics and đ folded).
    func matching(_ query: String) -> [Person] {
        let needle = ZaloEngine.contactFold(query).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return friends }
        return friends.filter { $0.sortKey.contains(needle) || $0.zaloKey.contains(needle) }
    }

    /// Alphabetical sections of `friends` (the picker's letter titles).
    var sections: [(title: String, people: [Person])] {
        var result: [(title: String, people: [Person])] = []
        for person in friends {
            if result.last?.title == person.section { result[result.count - 1].people.append(person) } else { result.append((person.section, [person])) }
        }
        return result
    }
}

/// The picks of the compose (`onItemClick`): blocked friends and picks beyond the limit are refused; 2 picks enable "Tạo nhóm".
struct GroupComposeSelection: Equatable {
    enum Change: Equatable { case added, removed, overLimit, blocked }
    private(set) var ids: [String] = []

    init(_ ids: [String] = []) { self.ids = ids }

    var canConfirm: Bool { ids.count > 1 }
    func contains(_ id: String) -> Bool { ids.contains(id) }

    @discardableResult
    mutating func toggle(_ id: String, limits: GroupCreateLimits) -> Change {
        if let index = ids.firstIndex(of: id) {
            ids.remove(at: index)
            return .removed
        }
        if limits.blocked.contains(id) { return .blocked }
        if ids.count >= limits.maxMembers { return .overLimit }
        ids.append(id)
        return .added
    }

    /// Drops picks that are no longer allowed (blocked meanwhile, unfriended, hidden).
    mutating func keep(where allowed: (String) -> Bool) { ids.removeAll { !allowed($0) } }
}

/// The group photo: centre square of the picked image, JPEG. Like the official avatar picker, the picked FILE must be 7 KB – 30 MB
/// (`update_avatar.min_size_kb` / `max_local_size`) and the image at least 240×240 (`min_width/min_height`); the upload takes up to
/// 1 MB for a group (`limit_size_group`).
struct GroupAvatarImage: Equatable {
    let jpeg: Data
    let side: Int

    static let minSide = 240
    static let maxSide = 1024
    /// Picked file size bounds (official `min_size_kb` × 1024, `max_local_size` × 10⁶).
    static let minFileBytes = 7 * 1024
    static let maxFileBytes = 30_000_000
    /// Upload size limit of a group avatar.
    static let maxBytes = 1024 * 1024
    static let tooSmallText = "Ảnh đại diện quá nhỏ. Kích thước tối thiểu là 240 x 240."      // update_avatar.min_dimension_error
    static let tooLightText = "Ảnh đại diện quá nhỏ. Dung lượng tối thiểu là 7 KB."           // update_avatar.min_size_error
    static let tooHeavyText = "Đã có lỗi xảy ra. Vui lòng sử dụng ảnh khác hoặc thử lại sau"  // STR_TOAST_UPLOAD_FAILED
    static let unreadableText = "Không đọc được ảnh này. Hãy chọn một ảnh khác."

    var image: NSImage? { NSImage(data: jpeg) }
    var base64: String { jpeg.base64EncodedString() }

    /// Reads `url` (EXIF orientation applied), crops the centre square and encodes it, or says why it cannot be used.
    static func make(from url: URL) -> Result<GroupAvatarImage, AvatarError> {
        guard let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return .failure(.unreadable) }
        if bytes < minFileBytes { return .failure(.tooLight) }
        if bytes >= maxFileBytes { return .failure(.tooHeavy) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, width > 0, height > 0
        else { return .failure(.unreadable) }
        let short = min(width, height), long = max(width, height)
        guard short >= minSide else { return .failure(.tooSmall) }
        // Decode no larger than needed for a `maxSide` square (the thumbnail API also applies the EXIF orientation).
        let scale = min(1, Double(maxSide) / Double(short))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(minSide, Int((Double(long) * scale).rounded(.up))),
        ]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return .failure(.unreadable) }
        return make(from: decoded)
    }

    static func make(from image: CGImage) -> Result<GroupAvatarImage, AvatarError> {
        let short = min(image.width, image.height)
        guard short >= minSide else { return .failure(.tooSmall) }
        let crop = CGRect(x: (image.width - short) / 2, y: (image.height - short) / 2, width: short, height: short)
        guard let square = image.cropping(to: crop) else { return .failure(.unreadable) }
        let side = min(short, maxSide)
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return .failure(.unreadable) }
        // JPEG has no alpha: transparent parts become white, as on a light avatar background.
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.interpolationQuality = .high
        context.draw(square, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let scaled = context.makeImage() else { return .failure(.unreadable) }
        var quality = 0.9
        var data = jpeg(scaled, quality: quality)
        while let bytes = data, bytes.count > maxBytes, quality > 0.45 {
            quality -= 0.15
            data = jpeg(scaled, quality: quality)
        }
        guard let result = data, result.count <= maxBytes else { return .failure(.unreadable) }
        return .success(GroupAvatarImage(jpeg: result, side: side))
    }

    private static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    enum AvatarError: Error, Equatable {
        case unreadable, tooSmall, tooLight, tooHeavy

        var text: String {
            switch self {
            case .unreadable: GroupAvatarImage.unreadableText
            case .tooSmall: GroupAvatarImage.tooSmallText
            case .tooLight: GroupAvatarImage.tooLightText
            case .tooHeavy: GroupAvatarImage.tooHeavyText
            }
        }
    }
}

/// Answer of group-create-adapter.js `create()`.
enum GroupCreateOutcome: Equatable {
    /// `failed`: picked members the server did not add (its `errorInfo`).
    case created(id: String, failed: [String])
    /// The same group already existed (STR_GROUP_EXISTS); it is opened.
    case exists(id: String, text: String)
    /// Refused before anything was sent (too few members, invalid name…): the sheet stays to fix it. `dropped`: picks that can no
    /// longer be added (blocked, not a friend any more), to be unpicked.
    case invalid(String, dropped: [String] = [])
    /// Refused by the quota check or the server. `title` set: shown as a confirm instead of a note. `closes`: the official compose
    /// closes after it (quota check failures).
    case failed(title: String?, message: String, closes: Bool = false)
    /// No answer in time: the group may still be created, so nothing invites a retry.
    case pending(String)

    static let defaultFailure = "Tạo nhóm không thành công."              // STR_CREATE_GROUP_FAIL
    static let notReadyText = "Ứng dụng chưa sẵn sàng, hãy thử lại sau giây lát."
    static let noAnswerText = "Chưa nhận được phản hồi. Hãy kiểm tra danh sách hội thoại trước khi thử lại."

    init(json: Any?) {
        guard let root = json as? [String: Any], let status = root["status"] as? String else {
            self = .failed(title: nil, message: Self.defaultFailure)
            return
        }
        let text = (root["text"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let id = root["convId"] as? String ?? ""
        switch status {
        case "created" where !id.isEmpty:
            self = .created(id: id, failed: (root["failed"] as? [Any] ?? []).compactMap { $0 as? String })
        case "exists" where !id.isEmpty:
            self = .exists(id: id, text: text ?? "Nhóm bạn vừa tạo đã tồn tại")
        case "invalid": self = .invalid(text ?? Self.defaultFailure, dropped: (root["dropped"] as? [Any] ?? []).compactMap { $0 as? String })
        case "pending": self = .pending(text ?? Self.noAnswerText)
        case "not-ready": self = .failed(title: nil, message: text ?? Self.notReadyText)
        case "busy": self = .failed(title: nil, message: text ?? Self.defaultFailure)
        default:
            self = .failed(title: (root["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }, message: text ?? Self.defaultFailure,
                           closes: root["close"] as? Bool ?? false)
        }
    }

    var logName: String {
        switch self {
        case .created: "created"
        case .exists: "exists"
        case .invalid: "invalid"
        case .failed: "failed"
        case .pending: "pending"
        }
    }
}

extension ZaloEngine {
    /// The compose's limits, nil while the official services are not ready.
    func groupCreateLimits() async -> GroupCreateLimits? {
        GroupCreateLimits(json: await evaluateGroupCreate("info", []))
    }

    /// `groupCreateLimits()`, asked again until the official services answer (the blocked list must not stay unknown).
    func groupCreateLimitsWhenReady(attempts: Int = 20) async -> GroupCreateLimits? {
        for attempt in 0..<attempts {
            if let limits = await groupCreateLimits() { return limits }
            if attempt + 1 < attempts { try? await Task.sleep(for: .seconds(1)) }
            if Task.isCancelled { return nil }
        }
        return nil
    }

    /// Creates the group in the official client. On success the new (or existing) group is opened in the shell once the conversation
    /// list knows it; members the server did not add are named in a toast (the official summary message in the chat has the detail).
    func createGroup(name: String, members: [String], avatar: GroupAvatarImage?) async -> GroupCreateOutcome {
        var input: [String: Any] = ["name": name, "members": members]
        if let avatar { input["avatar"] = ["data": avatar.base64, "width": avatar.side, "height": avatar.side] }
        guard host != nil else { return .failed(title: nil, message: GroupCreateOutcome.notReadyText) }   // nothing was started
        let answer = await raceTimeout(45) { [self] in JSBox(value: await evaluateGroupCreate("create", [input])) }
        // No answer in time, or none at all (the call threw: page reloaded mid-create) → the group may exist: pending, never a
        // failure that invites a retry into a duplicate group.
        let outcome = answer?.value.map { GroupCreateOutcome(json: $0) } ?? .pending(GroupCreateOutcome.noAnswerText)
        EngineLog.shared.write("group create → \(outcome.logName)")
        switch outcome {
        case .created(let id, let failed):
            await openCreatedGroup(id)
            if !failed.isEmpty { conversationUI.show(.neutral, Self.notAddedText(failed.map(contactName(_:)))) }
        case .exists(let id, let text):
            await openCreatedGroup(id)
            conversationUI.show(.neutral, text)
        case .pending(let text):
            conversationUI.show(.neutral, text)
        case .invalid, .failed:
            break
        }
        return outcome
    }

    /// "Chưa thêm được A, B và 3 người khác vào nhóm."
    nonisolated static func notAddedText(_ names: [String]) -> String {
        let shown = names.prefix(3).joined(separator: ", ")
        let rest = names.count - min(names.count, 3)
        return "Chưa thêm được " + (rest > 0 ? "\(shown) và \(rest) người khác" : shown) + " vào nhóm."
    }

    private func contactName(_ id: String) -> String {
        contacts.friends.first { $0.id == id }?.name ?? "Người dùng Zalo"
    }

    /// Waits (briefly) for the new conversation to reach the list, then shows it.
    private func openCreatedGroup(_ id: String) async {
        for _ in 0..<50 where !conversations.contains(where: { $0.id == id }) && !contacts.groups.contains(where: { $0.id == id }) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        navigationRequest = id
    }

    private func evaluateGroupCreate(_ method: String, _ args: [Any]) async -> Any? {
        guard let data = try? JSONSerialization.data(withJSONObject: args, options: [.fragmentsAllowed]),
              let json = String(data: data, encoding: .utf8), let host else { return nil }
        return await host.evaluate("const c = window.__zaloGroupCreate; if (!c || !c.\(method)) return {status: 'not-ready'}; return await c.\(method)(...\(json));")
    }
}
