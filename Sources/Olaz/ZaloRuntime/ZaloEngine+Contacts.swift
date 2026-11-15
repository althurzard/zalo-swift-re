import Foundation

// Friends, groups, friend requests, add friend. Bridged to `HostScripts/contacts-adapter.js`
// (`window.__zaloContacts`; posts {page:'main', contacts:{…}} — each key replaces that section).
// Every action runs through the official client's own services (see the adapter header).

struct ContactsState: Equatable {
    struct Friend: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let zaloName: String
        let avatar: URL?
        /// Last activity reported by the official profile, nil when unknown.
        let lastActive: Date?
        let online: Bool
        /// Upper-case Latin initial used for the alphabetical sections ("#" when not a letter).
        let section: String
        /// Diacritic-folded lowercase name for sorting and searching.
        let sortKey: String
    }

    struct Group: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let avatar: URL?
        let members: Int
        let sortKey: String
    }

    struct FriendRequest: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let avatar: URL?
        let message: String
        /// nil when the official client has no timestamp for the request.
        let date: Date?
    }

    struct FoundUser: Equatable, Sendable {
        let id: String
        let name: String
        let zaloName: String
        let avatar: URL?
        let bio: String
        let isFriend: Bool
        let isSelf: Bool
        /// I already sent this person a request.
        var requested: Bool
        /// This person already sent me a request.
        let requesting: Bool
        /// Official default greeting for "find by phone" (editable by the user).
        let defaultMessage: String
        let maxMessage: Int
    }

    struct Search: Equatable, Sendable {
        enum Status: String, Sendable { case idle, searching, found, error }
        var status: Status = .idle
        var error: String?
        var user: FoundUser?
    }

    /// Result of the latest accept / decline / cancel / send action.
    struct Notice: Equatable, Sendable {
        let seq: Int
        let ok: Bool
        let text: String
    }

    var friends: [Friend] = []
    var groups: [Group] = []
    var received: [FriendRequest] = []
    var sent: [FriendRequest] = []
    /// Pending received friend requests (rail badge).
    var pendingRequestCount = 0
    var loadingRequests = false
    var search = Search()
    var notice: Notice?
    /// True once the official friend list has been read at least once.
    var friendsLoaded = false
    var groupsLoaded = false
}

extension ZaloEngine {
    // MARK: Actions

    /// Re-reads friend requests from the server (as opening the official invitation page does).
    func refreshContacts() { callChat("refresh", object: "__zaloContacts") }

    func acceptFriendRequest(_ id: String) { callChat("accept", id, object: "__zaloContacts") }
    func declineFriendRequest(_ id: String) { callChat("decline", id, object: "__zaloContacts") }
    func cancelFriendRequest(_ id: String) { callChat("cancel", id, object: "__zaloContacts") }

    /// Looks a user up by phone number through the official find-user API.
    func findFriend(byPhone phone: String) {
        let trimmed = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        contacts.search = ContactsState.Search(status: .searching)
        callChat("search", trimmed, object: "__zaloContacts")
    }

    func resetFriendSearch() {
        if contacts.search != ContactsState.Search() { contacts.search = ContactsState.Search() }
        callChat("resetSearch", object: "__zaloContacts")
    }

    func sendFriendRequest(to id: String, message: String) {
        callChat("sendRequest", id, message, object: "__zaloContacts")
    }

    /// Opens the 1-1 or group conversation with `id` (the shell observes `navigationRequest`).
    func openContactConversation(_ id: String) { navigationRequest = id }

    // MARK: State

    func handleContacts(state: [String: Any]) {
        guard let json = state["contacts"] as? [String: Any] else { return }
        var next = contacts
        if let rows = json["friends"] as? [[String: Any]] {
            next.friends = rows.compactMap(Self.contactFriend)
            next.friendsLoaded = true
        }
        if let rows = json["groups"] as? [[String: Any]] {
            next.groups = rows.compactMap(Self.contactGroup)
            next.groupsLoaded = true
        }
        if let rows = json["received"] as? [[String: Any]] { next.received = rows.compactMap(Self.contactRequest) }
        if let rows = json["sent"] as? [[String: Any]] { next.sent = rows.compactMap(Self.contactRequest) }
        if let count = (json["pendingRequestCount"] as? NSNumber)?.intValue { next.pendingRequestCount = max(0, count) }
        if let loading = json["loading"] as? [String: Any], let flag = loading["requests"] as? Bool { next.loadingRequests = flag }
        if let search = json["search"] as? [String: Any] { next.search = Self.contactSearch(search) }
        if let notice = json["notice"] as? [String: Any], let seq = (notice["seq"] as? NSNumber)?.intValue {
            next.notice = ContactsState.Notice(seq: seq, ok: notice["ok"] as? Bool ?? false, text: notice["text"] as? String ?? "")
        }
        if next != contacts { contacts = next }
    }

    /// Lower-cased, diacritic-folded text (Vietnamese đ/Đ included) for searching and sorting.
    nonisolated static func contactFold(_ text: String) -> String {
        text.replacingOccurrences(of: "đ", with: "d").replacingOccurrences(of: "Đ", with: "D")
            .folding(options: contactFoldOptions, locale: contactFoldLocale)
            .lowercased()
    }

    /// Built once: thousands of friends are folded per contacts update.
    nonisolated private static let contactFoldLocale = Locale(identifier: "vi")
    nonisolated private static let contactFoldOptions: String.CompareOptions = [.diacriticInsensitive, .caseInsensitive, .widthInsensitive]

    private static func url(_ value: Any?) -> URL? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return URL(string: text)
    }

    private static func contactFriend(_ json: [String: Any]) -> ContactsState.Friend? {
        guard let id = json["id"] as? String, !id.isEmpty else { return nil }
        let name = (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (json["zaloName"] as? String) ?? ""
        let key = contactFold(name).trimmingCharacters(in: .whitespacesAndNewlines)
        let first = key.first.map { String($0).uppercased() } ?? "#"
        let section = first.unicodeScalars.allSatisfy { ("A"..."Z").contains($0) } ? first : "#"
        let last = (json["lastActive"] as? NSNumber)?.doubleValue ?? 0
        return ContactsState.Friend(
            id: id, name: name, zaloName: json["zaloName"] as? String ?? "",
            avatar: url(json["avatar"]),
            lastActive: last > 0 ? Date(timeIntervalSince1970: last / 1000) : nil,
            online: json["online"] as? Bool ?? false,
            section: section, sortKey: key
        )
    }

    private static func contactGroup(_ json: [String: Any]) -> ContactsState.Group? {
        guard let id = json["id"] as? String, !id.isEmpty else { return nil }
        let name = json["name"] as? String ?? ""
        return ContactsState.Group(
            id: id, name: name, avatar: url(json["avatar"]),
            members: (json["members"] as? NSNumber)?.intValue ?? 0,
            sortKey: contactFold(name)
        )
    }

    private static func contactRequest(_ json: [String: Any]) -> ContactsState.FriendRequest? {
        guard let id = json["id"] as? String, !id.isEmpty else { return nil }
        let time = (json["time"] as? NSNumber)?.doubleValue ?? 0
        return ContactsState.FriendRequest(
            id: id, name: json["name"] as? String ?? "", avatar: url(json["avatar"]),
            message: json["message"] as? String ?? "",
            date: time > 0 ? Date(timeIntervalSince1970: time / 1000) : nil
        )
    }

    private static func contactSearch(_ json: [String: Any]) -> ContactsState.Search {
        let status = ContactsState.Search.Status(rawValue: json["status"] as? String ?? "") ?? .idle
        var search = ContactsState.Search(status: status, error: json["error"] as? String, user: nil)
        if let u = json["user"] as? [String: Any], let id = u["id"] as? String, !id.isEmpty {
            search.user = ContactsState.FoundUser(
                id: id, name: u["name"] as? String ?? "", zaloName: u["zaloName"] as? String ?? "",
                avatar: url(u["avatar"]), bio: u["bio"] as? String ?? "",
                isFriend: u["isFriend"] as? Bool ?? false, isSelf: u["isSelf"] as? Bool ?? false,
                requested: u["requested"] as? Bool ?? false, requesting: u["requesting"] as? Bool ?? false,
                defaultMessage: u["defaultMessage"] as? String ?? "",
                maxMessage: (u["maxMessage"] as? NSNumber)?.intValue ?? 150
            )
        }
        return search
    }
}
