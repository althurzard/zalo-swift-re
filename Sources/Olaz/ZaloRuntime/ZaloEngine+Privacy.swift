import Foundation

// Privacy settings & blocklist (`uWWm.default`, `dSSf.fetchBlockedFriendList`, `UiPd.blockFriend`).
// Bridged to `HostScripts/privacy-adapter.js` (`window.__olazPrivacy`).

enum BirthdayVisibility: Int, CaseIterable, Identifiable, Sendable {
    case hidden = 0
    case fullDate = 1
    case monthAndDayOnly = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .hidden: "Không hiện"
        case .fullDate: "Hiện đầy đủ ngày, tháng, năm"
        case .monthAndDayOnly: "Chỉ hiện ngày, tháng"
        }
    }

    static func parse(_ value: Any?) -> BirthdayVisibility {
        guard let raw = (value as? NSNumber)?.intValue,
              let parsed = BirthdayVisibility(rawValue: raw) else { return .hidden }
        return parsed
    }
}

enum MessageStrangerOption: Int, CaseIterable, Identifiable, Sendable {
    case everyone = 1
    case friendsOnly = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .everyone: "Tất cả mọi người"
        case .friendsOnly: "Bạn bè"
        }
    }

    static func parse(_ value: Any?) -> MessageStrangerOption {
        guard let raw = (value as? NSNumber)?.intValue,
              let parsed = MessageStrangerOption(rawValue: raw) else { return .everyone }
        return parsed
    }
}

enum CallStrangerOption: Int, CaseIterable, Identifiable, Sendable {
    case friendsOnly = 2
    case friendsAndContactedStrangers = 4
    case everyone = 3

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .friendsOnly: "Bạn bè"
        case .friendsAndContactedStrangers: "Bạn bè và người lạ từng liên hệ"
        case .everyone: "Tất cả mọi người"
        }
    }

    static func parse(_ value: Any?) -> CallStrangerOption {
        guard let raw = (value as? NSNumber)?.intValue,
              let parsed = CallStrangerOption(rawValue: raw) else { return .friendsOnly }
        return parsed
    }
}

enum PrivacySettingKey: String, CaseIterable, Sendable {
    case viewBirthday = "view_birthday"
    case showOnlineStatus = "show_online_status"
    case displaySeenStatus = "display_seen_status"
    case receiveMessage = "receive_message"
    case acceptStrangerCall = "accept_stranger_call"
    case addFriendViaPhone = "add_friend_via_phone"
    case addFriendViaQR = "add_friend_via_qr"
    case addFriendViaGroup = "add_friend_via_group"
    case addFriendViaContact = "add_friend_via_contact"
    case displayOnRecommendFriend = "display_on_recommend_friend"
}

struct PrivacySettings: Equatable, Sendable {
    var viewBirthday: BirthdayVisibility = .hidden
    var showOnlineStatus: Bool = true
    var displaySeenStatus: Bool = true
    var receiveMessage: MessageStrangerOption = .everyone
    var acceptStrangerCall: CallStrangerOption = .friendsOnly
    var addFriendViaPhone: Bool = true
    var addFriendViaQR: Bool = true
    var addFriendViaGroup: Bool = true
    var addFriendViaContact: Bool = true
    var displayOnRecommendFriend: Bool = true

    static func parse(_ raw: [String: Any]) -> PrivacySettings {
        func bool(_ key: PrivacySettingKey, defaultValue: Bool) -> Bool {
            guard let v = raw[key.rawValue] else { return defaultValue }
            if let b = v as? Bool { return b }
            if let n = v as? NSNumber { return n.intValue != 0 }
            if let s = v as? String, let i = Int(s) { return i != 0 }
            return defaultValue
        }

        return PrivacySettings(
            viewBirthday: BirthdayVisibility.parse(raw[PrivacySettingKey.viewBirthday.rawValue]),
            showOnlineStatus: bool(.showOnlineStatus, defaultValue: true),
            displaySeenStatus: bool(.displaySeenStatus, defaultValue: true),
            receiveMessage: MessageStrangerOption.parse(raw[PrivacySettingKey.receiveMessage.rawValue]),
            acceptStrangerCall: CallStrangerOption.parse(raw[PrivacySettingKey.acceptStrangerCall.rawValue]),
            addFriendViaPhone: bool(.addFriendViaPhone, defaultValue: true),
            addFriendViaQR: bool(.addFriendViaQR, defaultValue: true),
            addFriendViaGroup: bool(.addFriendViaGroup, defaultValue: true),
            addFriendViaContact: bool(.addFriendViaContact, defaultValue: true),
            displayOnRecommendFriend: bool(.displayOnRecommendFriend, defaultValue: true)
        )
    }

    mutating func apply(key: PrivacySettingKey, wireValue: Int) {
        switch key {
        case .viewBirthday:
            viewBirthday = BirthdayVisibility(rawValue: wireValue) ?? viewBirthday
        case .showOnlineStatus:
            showOnlineStatus = wireValue != 0
        case .displaySeenStatus:
            displaySeenStatus = wireValue != 0
        case .receiveMessage:
            receiveMessage = MessageStrangerOption(rawValue: wireValue) ?? receiveMessage
        case .acceptStrangerCall:
            acceptStrangerCall = CallStrangerOption(rawValue: wireValue) ?? acceptStrangerCall
        case .addFriendViaPhone:
            addFriendViaPhone = wireValue != 0
        case .addFriendViaQR:
            addFriendViaQR = wireValue != 0
        case .addFriendViaGroup:
            addFriendViaGroup = wireValue != 0
        case .addFriendViaContact:
            addFriendViaContact = wireValue != 0
        case .displayOnRecommendFriend:
            displayOnRecommendFriend = wireValue != 0
        }
    }

    func wireValue(for key: PrivacySettingKey) -> Int {
        switch key {
        case .viewBirthday: viewBirthday.rawValue
        case .showOnlineStatus: showOnlineStatus ? 1 : 0
        case .displaySeenStatus: displaySeenStatus ? 1 : 0
        case .receiveMessage: receiveMessage.rawValue
        case .acceptStrangerCall: acceptStrangerCall.rawValue
        case .addFriendViaPhone: addFriendViaPhone ? 1 : 0
        case .addFriendViaQR: addFriendViaQR ? 1 : 0
        case .addFriendViaGroup: addFriendViaGroup ? 1 : 0
        case .addFriendViaContact: addFriendViaContact ? 1 : 0
        case .displayOnRecommendFriend: displayOnRecommendFriend ? 1 : 0
        }
    }
}

struct BlockedUser: Identifiable, Equatable, Sendable {
    let userId: String
    let displayName: String
    let zaloName: String
    let avatar: URL?

    var id: String { userId }

    var resolvedName: String {
        if !displayName.isEmpty { return displayName }
        if !zaloName.isEmpty { return zaloName }
        return "Người dùng Zalo"
    }

    init(userId: String, displayName: String, zaloName: String = "", avatar: URL? = nil) {
        self.userId = userId
        self.displayName = displayName
        self.zaloName = zaloName
        self.avatar = avatar
    }

    init?(json: [String: Any]) {
        let uid = (json["userId"] as? String) ?? (json["id"] as? String) ?? ""
        guard !uid.isEmpty else { return nil }
        let display = (json["displayName"] as? String) ?? (json["dName"] as? String) ?? ""
        let zalo = (json["zaloName"] as? String) ?? (json["zName"] as? String) ?? ""
        let avatarURL = (json["avatar"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
        self.init(userId: uid, displayName: display, zaloName: zalo, avatar: avatarURL)
    }
}

extension ZaloEngine {
    func resetPrivacyState() {
        privacySettings = nil
        privacyLoading = false
        privacyError = nil
        blockedUsers = []
        blockedUsersLoaded = false
    }

    func loadPrivacySettings(force: Bool = false) async {
        privacyLoading = true
        privacyError = nil
        defer { privacyLoading = false }

        guard let dict = await callPrivacy("getSettings", timeout: 12, force) as? [String: Any] else {
            privacyError = "Không tải được thiết lập quyền riêng tư."
            EngineLog.shared.write("privacy load timeout")
            return
        }
        guard (dict["ok"] as? Bool) == true else {
            let code = (dict["errorCode"] as? NSNumber)?.stringValue ?? "none"
            privacyError = dict["error"] as? String ?? "Không tải được thiết lập quyền riêng tư."
            EngineLog.shared.write("privacy load fail code=\(code)")
            return
        }
        let rawSettings = dict["settings"] as? [String: Any] ?? [:]
        privacySettings = PrivacySettings.parse(rawSettings)
        EngineLog.shared.write("privacy load ok")
    }

    @discardableResult
    func updatePrivacySetting(_ key: PrivacySettingKey, value: Int) async -> Bool {
        let previous = privacySettings
        var updated = privacySettings ?? PrivacySettings()
        updated.apply(key: key, wireValue: value)
        privacySettings = updated
        privacyError = nil

        guard let dict = await callPrivacy("updateSetting", timeout: 12, key.rawValue, value) as? [String: Any],
              (dict["ok"] as? Bool) == true else {
            privacySettings = previous
            privacyError = "Không lưu được thay đổi quyền riêng tư."
            EngineLog.shared.write("privacy update fail key=\(key.rawValue)")
            return false
        }
        EngineLog.shared.write("privacy update ok key=\(key.rawValue)")
        return true
    }

    @discardableResult
    func updatePrivacySetting(_ key: PrivacySettingKey, enabled: Bool) async -> Bool {
        await updatePrivacySetting(key, value: enabled ? 1 : 0)
    }

    @discardableResult
    func loadBlockedUsers() async -> [BlockedUser] {
        guard let dict = await callPrivacy("getBlockedUsers", timeout: 15) as? [String: Any],
              (dict["ok"] as? Bool) == true else {
            EngineLog.shared.write("privacy blocked list fail")
            return blockedUsers
        }
        let rows = dict["users"] as? [[String: Any]] ?? []
        let parsed = rows.compactMap(BlockedUser.init(json:))
        blockedUsers = parsed
        blockedUsersLoaded = true
        EngineLog.shared.write("privacy blocked list ok count=\(parsed.count)")
        return parsed
    }

    @discardableResult
    func setBlocked(uid: String, blocked: Bool) async -> ProfileMutationResult {
        let target = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return .failure("Không xác định được người dùng.") }

        guard let dict = await callPrivacy("setBlocked", timeout: 15, target, blocked) as? [String: Any] else {
            EngineLog.shared.write("privacy block timeout")
            return .failure("Không nhận được phản hồi từ Zalo.")
        }
        guard (dict["ok"] as? Bool) == true else {
            let code = (dict["errorCode"] as? NSNumber)?.stringValue ?? "none"
            EngineLog.shared.write("privacy block fail code=\(code)")
            return .failure(dict["error"] as? String ?? (blocked ? "Chặn người dùng thất bại." : "Bỏ chặn thất bại."))
        }

        if blocked {
            await loadBlockedUsers()
        } else {
            blockedUsers.removeAll { $0.userId == target }
        }
        EngineLog.shared.write("privacy block ok blocked=\(blocked)")
        return .success
    }

    func isUserBlocked(_ uid: String) async -> Bool {
        let target = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return false }
        if let result = await callPrivacy("isBlocked", timeout: 5, target) as? Bool, result {
            return true
        }
        return blockedUsers.contains { $0.userId == target }
    }

    private func callPrivacy(_ method: String, timeout: Double, _ args: Any...) async -> Any? {
        guard let host,
              let data = try? JSONSerialization.data(withJSONObject: args, options: [.fragmentsAllowed]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        let script = "const p = window.__olazPrivacy; if (!p || !p.\(method)) return null; return await p.\(method)(...\(json));"
        let boxed = await raceTimeout(timeout) { JSBox(value: await host.evaluate(script)) }
        return boxed?.value
    }
}
