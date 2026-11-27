import Foundation
import AppKit

// MARK: - Chat contract
//
// Shared between the engine (data from the official client, see
// `HostScripts/chat-adapter.js`) and the SwiftUI chat views. Values are produced
// by the official renderer's own services; nothing here is synthesized.
//
// JS → Swift (`zstate` message handler):
//   {page:'main', chat:{convId, messages:[ChatMessageJSON], removed:[id], hasMore:Bool, reset:Bool}}
//     grew=true: older raw messages arrived that are all hidden cards (nothing else changed) → `ZaloEngine.historyTicks`.
//     reset=true: `messages` is the full list; otherwise only added/changed messages (merge by id) + `removed` ids.
//     Own messages are keyed by `cliMsgId` (stable pending → sent); others by server `msgId`.
//   {page:'main', typing:{convId, name}}
//   {page:'main', transfer:TransferJSON|null}   // phone → PC message sync (transfer-adapter.js)
// Swift → JS (`window.__zaloChat`):
//   open(convId) · close(convId) · loadMore(convId) · sendText(convId, text, quoteMsgId?, mentions?) → Promise<'sent'|'not-open'|'not-ready'|'error'>
//   mentionCandidates(convId, query, mentionedUids) → Promise<[{id, name, avatar, isAll}]>
//   reactors(convId, msgId) → Promise<{tabs:[{type, key, emoji, image, total}],
//                                      users:[{uid, name, avatar, isMe, total, icons:[{type, key, emoji, image, count}]}]} | null>
//     (who reacted — the official "Biểu cảm" popup, parsed by `ReactionDetail`; null = unknown → failure state)
//   Message `kind` JSON → `ChatMessage.Kind` (parsed by `Kind(json:)`): text · photo · sticker · gif · video · voice · file ·
//     link{title,url,thumbnail,description,source} · contactCard{name,uid,avatar,phone,qr,oaLink,isOA} ·
//     location{title,address,hasCoordinates,latitude,longitude,thumbnail} · call{video,missed,duration,title,detail} ·
//     ecard{style,image,thumb,title,description,actions,avatars,reminder*} · oaMessage{parts} · poll{question,header,anonymous,pollId,conversationId} ·
//     stickerSet{title,thumb} · zinstant{title,text,thumb} · notice{symbol,text} · placeholder{symbol,text} · system · recalled ·
//     unsupported{rawType}. Unknown `type`s and missing / mistyped fields degrade to `.unsupported` / empty values, never a crash.
//     The full field list with the official bundle offsets is the contract comment in `chat-adapter.js`.
//   Message `buttons` JSON (card-actions-adapter.js, merged into the message object): [{ref, label, enabled, help}] — the buttons of an
//     e-card / info message / call log; `stickers`: Bool — the card offers its suggested stickers.
//   Message `menu` JSON (message-actions-adapter.js `describe`): {forward: 'ok'|'blocked'|'', recall, delete: 'forMe'|'plain'|'', pin,
//     star: 'star'|'unstar'|'blocked'|'', starred, protected, pinned} → `MessageMenu`.
// Swift → JS (`window.__zaloMsgActions`, message-actions-adapter.js; `ZaloEngine+MessageActions.swift`):
//   forward(convId, msgId, targets) · recall(convId, msgId) · deleteForMe(convId, msgId, confirmed) · undoDelete(id) · commitDelete(id) ·
//   dropDelete(id) · star(convId, msgId, on) · watchPins(convId|null) · pin(convId, msgId, confirmRef?) · unpin(convId, ref)
//     → {status, text?, …} (parsed by `MessageActionOutcome`)
//   JS → Swift: {page:'main', pins:{convId, ready, canPin, items:[{ref, kind, title, sender, thumb, msgId, cliMsgId}]}} → `PinnedList`
// Swift → JS (`window.__zaloChat`, card-actions-adapter.js):
//   performAction(convId, msgId, ref) → Promise<{status, effect?, text?}>     (parsed by `CardActionOutcome`)
//   cardStickers(convId, msgId) → [{ref, url}] · contactState(uid) → {isSelf, isFriend} · contactProfile(uid) → {uid, name, zaloName, avatar, bio, isSelf, isFriend}
//   prepareFriendRequest(uid, convId) → {state, defaultMessage, maxMessage}                          (parsed by `FriendRequestPrep`)
//   Message `reactions` JSON: [{type, key, emoji, image, count, includesMe, names (≤3), people}]; `image` is a
//     `pc-dist` path of the official icon PNG (parsed by `ReactionIcon`; names feed the chip tooltip)
//   markRead(convId) · react(convId, msgId, emoji)
// Swift → JS (`window.__zaloTransfer`, HostScripts/transfer-adapter.js):
//   respond(accept: Bool) · dismiss()
// Swift → JS (`window.__zaloMediaStore`, HostScripts/media-store-adapter.js; `ZaloEngine+SharedMedia.swift`):
//   page(convId, kind: 'images'|'files'|'links', cursor, limit) → Promise<{items:[ChatMessageJSON], cursor, more} | null>
//     (every photo / video, file or link ever shared in the conversation, newest first; parsed by `SharedMediaPage`; null = unavailable)

/// An @mention inside a text: `pos`/`len` are UTF-16 offsets into the message text covering
/// "@Name" (the official `mentions` field: {uid, pos, len, type}; type 1 / uid "-1" = everyone).
struct Mention: Equatable, Hashable, Sendable {
    var uid: String
    var pos: Int
    var len: Int
    var isAll: Bool = false
}

/// What the composer holds: text with its mentions (UTF-16 offsets into `text`) and the message being replied to.
struct ComposerDraft: Equatable {
    var text: String
    var mentions: [Mention] = []
    var replyTo: ChatMessage?

    /// `other` after `self`, one line below when both have text; its mention offsets move with it.
    /// The reply target stays `self`'s unless it has none.
    func appending(_ other: ComposerDraft) -> ComposerDraft {
        guard !text.isEmpty else { return ComposerDraft(text: other.text, mentions: other.mentions, replyTo: replyTo ?? other.replyTo) }
        guard !other.text.isEmpty else { return self }
        let shift = (text as NSString).length + 1
        var merged = mentions
        merged += other.mentions.map { Mention(uid: $0.uid, pos: $0.pos + shift, len: $0.len, isAll: $0.isAll) }
        return ComposerDraft(text: text + "\n" + other.text, mentions: merged, replyTo: replyTo ?? other.replyTo)
    }
}

/// Drafts the official client did not take, per conversation. Owned by the engine (above `ChatView`, which is
/// rebuilt per conversation) so a failure that arrives after switching away is not lost; the next composer shown
/// for that conversation takes it back. Several failures merge in order.
struct FailedDraftStore: Equatable {
    private var drafts: [String: ComposerDraft] = [:]
    /// Conversations whose held draft was stashed `silent` (the caller already told the user why): giving it back shows no notice of its own.
    private var silent: Set<String> = []
    /// Bumps on every stash so views can react.
    private(set) var revision = 0

    func has(_ id: String) -> Bool { drafts[id] != nil }

    /// `silent`: the failure is reported elsewhere (a specific toast), so putting the text back needs no "not sent" notice. A silent stash
    /// merged with a normal one stays normal.
    mutating func stash(_ draft: ComposerDraft, for id: String, silent isSilent: Bool = false) {
        guard !draft.text.isEmpty else { return }
        if drafts[id] == nil { if isSilent { silent.insert(id) } } else if !isSilent { silent.remove(id) }
        drafts[id] = drafts[id].map { $0.appending(draft) } ?? draft
        revision += 1
    }

    mutating func take(for id: String) -> ComposerDraft? { takeWithNotice(for: id)?.draft }

    /// The held draft and whether giving it back deserves the "not sent" notice.
    mutating func takeWithNotice(for id: String) -> (draft: ComposerDraft, notice: Bool)? {
        let wasSilent = silent.remove(id) != nil
        return drafts.removeValue(forKey: id).map { ($0, !wasSilent) }
    }

    /// Everything held, leaving the store empty.
    mutating func drain() -> [(String, ComposerDraft)] {
        defer { drafts = [:]; silent = [] }
        return drafts.map { ($0.key, $0.value) }
    }
}

/// A group member offered by the composer's @-popover (official suggestion engine).
struct MentionCandidate: Identifiable, Equatable, Sendable {
    var id: String
    /// Display name without the "@" (the official client inserts "@All" for everyone).
    var name: String
    var avatar: URL?
    var isAll: Bool
}

/// A reaction icon of the official client (`reactCache.getIconMap()`): an image from `pc-dist`
/// (`emoji/emoji-32/row-R-column-C.png`, looked up through the official `emojiRC` table) with the icon text as fallback.
struct ReactionIcon: Equatable, Hashable, Sendable, Identifiable {
    /// Official reaction type (`rType`); chips, tabs and rows are grouped by it.
    var type: String
    /// Official icon text (e.g. "/-heart").
    var key: String
    /// Unicode emoji for the six known reactions, otherwise the icon text.
    var emoji: String
    /// `pc-dist` relative path of the icon PNG; empty when the official table has none.
    var image: String = ""
    var id: String { type }

    init(type: String, key: String = "", emoji: String, image: String = "") {
        self.type = type; self.key = key; self.emoji = emoji; self.image = image
    }

    init?(json: [String: Any]) {
        let emoji = json["emoji"] as? String ?? ""
        let key = json["key"] as? String ?? ""
        guard !(emoji.isEmpty && key.isEmpty) else { return nil }
        let type = (json["type"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (key.isEmpty ? emoji : key)
        self.init(type: type, key: key, emoji: emoji.isEmpty ? key : emoji, image: json["image"] as? String ?? "")
    }
}

struct ChatMessage: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case text
        case photo(url: URL?, width: Int, height: Int)
        case sticker(url: URL?)
        case gif(url: URL?)
        case video(thumbnail: URL?, duration: Int, url: URL? = nil)
        case voice(url: URL?, duration: Int)
        case file(name: String, size: Int64, url: URL?)
        /// Link preview card (official `recommened.link`): `title` is the page title (or the URL), `source` the site.
        case link(title: String, url: URL?, thumbnail: URL?, description: String = "", source: String = "")
        case contactCard(ContactCard)
        case location(LocationInfo)
        /// `title` / `detail` are the official call strings ("Bạn bị nhỡ", "2 phút 5 giây"); empty = derive from the flags.
        case call(video: Bool, missed: Bool, duration: Int, title: String = "", detail: String = "")
        case ecard(ECard)
        case oaMessage([OAPart])
        case poll(PollInfo)
        case stickerSet(title: String, thumbnail: URL?)
        case zinstant(title: String, text: String, thumbnail: URL?)
        /// Centered notice with an SF Symbol (info message, to-do, vanish, syncing).
        case notice(symbol: String, text: String)
        /// A bubble standing in for a message that cannot be shown yet (end-to-end encryption pending / failed).
        case placeholder(symbol: String, text: String)
        case system
        case recalled
        case unsupported(type: String)

        /// Kinds the official client lays out centered, outside the message bubbles.
        var isStandalone: Bool {
            switch self {
            case .system, .notice, .ecard: true
            default: false
            }
        }
    }

    /// Business card (official `recommened.user` / `recommened.vip`): the contact's id, name, avatar and extras.
    struct ContactCard: Equatable, Sendable {
        var name: String
        var uid: String = ""
        var avatar: URL?
        var phone: String = ""
        var qr: URL?
        var oaLink: String = ""
        var isOfficialAccount: Bool = false
    }

    /// Shared location: the official card shows title, address and a map of the coordinates.
    struct LocationInfo: Equatable, Sendable {
        var title: String = ""
        var address: String = ""
        var coordinate: Coordinate?
        var thumbnail: URL?

        struct Coordinate: Equatable, Sendable { var latitude: Double; var longitude: Double }

        /// The link the official card opens (`maps.google.com/maps?q=lat,lo&z=14`).
        var mapURL: URL? {
            guard let coordinate else { return nil }
            return URL(string: "https://maps.google.com/maps?q=\(coordinate.latitude),\(coordinate.longitude)&z=14&t=m")
        }
    }

    /// E-card (official `chat.ecard`): a banner, new-friend / birthday card, or a reminder.
    struct ECard: Equatable, Sendable {
        enum Style: String, Sendable { case banner, friend, birthday, reminder }
        var style: Style = .banner
        var image: URL?
        var thumb: URL?
        var title: String = ""
        var description: String = ""
        /// Legacy label-only list; the live buttons are `ChatMessage.cardButtons`.
        var actions: [String] = []
        var avatars: [URL] = []
        var reminderTitle: String = ""
        var reminderStart: Date?
        var reminderRepeat: String = ""
    }

    /// One part of an OA list message / article (`l.a.header.*` = lead card, `l.a.child.full` = row).
    struct OAPart: Equatable, Sendable {
        var isHeader: Bool
        var title: String
        var description: String = ""
        var thumb: URL?
        var url: URL?
        /// Why the row cannot be opened here (its official action needs UI this app does not have); empty = nothing to say.
        var help: String = ""
    }

    /// Group poll event message: question, the info line ("Lan đã bình chọn") and the ids the poll service is read by
    /// (options / votes / actions: `ZaloEngine+Poll.swift`, `PollViews.swift`).
    struct PollInfo: Equatable, Sendable {
        var question: String
        var header: String = ""
        var anonymous: Bool = false
        var pollId: String = ""
        var conversationId: String = ""
    }

    enum Status: String, Equatable, Sendable {
        case sending, sent, delivered, seen, failed
    }

    struct Quote: Equatable, Sendable {
        var senderName: String
        var text: String
        /// Ids the quoted message may be keyed by in the list (server id, client id): a tap on the quote jumps to it.
        var messageIds: [String] = []
    }

    struct Reaction: Equatable, Sendable, Identifiable {
        var icon: ReactionIcon
        var count: Int
        var includesMe: Bool
        /// Up to 3 reactor names known from cached profiles (me first, as "Bạn"); may be fewer than `people`.
        var names: [String] = []
        /// Distinct people who used this reaction.
        var people: Int = 0

        var id: String { icon.id }
        var emoji: String { icon.emoji }

        /// Chip tooltip: "A", "A và B", "A, B và C", "A, B, C và 2 người khác"; nil when nobody is known.
        var tooltip: String? {
            let others = max(0, people - names.count)
            switch (names.count, others) {
            case (0, 0): return nil
            case (0, _): return "\(others) người"
            case (1, 0): return names[0]
            case (_, 0): return names.dropLast().joined(separator: ", ") + " và " + names[names.count - 1]
            default: return names.joined(separator: ", ") + " và \(others) người khác"
            }
        }
    }

    /// Server `msgId` when known, else the client id (`cliMsgId`) of a pending message.
    var id: String
    var conversationId: String
    var senderId: String
    var senderName: String
    var senderAvatar: URL?
    var isMine: Bool
    var kind: Kind
    /// Text body, caption, or a readable fallback for non-text kinds.
    var text: String
    var date: Date
    var status: Status
    var quote: Quote?
    var reactions: [Reaction]
    var isE2EE: Bool
    /// Official `message.mentions` (empty for messages without @mentions).
    var mentions: [Mention] = []
    /// Buttons the official card draws for this message (e-card actions, info-message links, call back).
    var cardButtons: [CardButton] = []
    /// The card offers its suggested stickers (new-friend / birthday / sticker e-cards).
    var suggestsStickers: Bool = false
    /// What the official right-click menu offers for this message (forward, recall, delete, pin, star).
    var menu = MessageMenu()
}

/// The items of the official message context menu (message-actions-adapter.js `describe`, the builder's own conditions) with the
/// message's starred / pinned state. An album photo has its own menu: the official album view opens the menu of the photo clicked.
struct MessageMenu: Equatable, Sendable {
    enum Availability: String, Sendable { case hidden, available, blocked }
    enum Delete: String, Sendable {
        /// "Xóa" — a message that failed to send, or anything in My Cloud.
        case plain
        /// "Xóa chỉ ở phía tôi".
        case forMe
    }
    enum Star: String, Sendable { case star, unstar, blocked }

    var forward: Availability = .hidden
    var recall = false
    var delete: Delete?
    var pin = false
    var star: Star?
    var starred = false
    var pinned = false
    /// "Chặn chia sẻ" is on in this conversation: nothing may be forwarded, copied or saved.
    var isProtected = false

    init() {}

    init(json: Any?) {
        guard let row = json as? [String: Any] else { return }
        switch row["forward"] as? String {
        case "ok": forward = .available
        case "blocked": forward = .blocked
        default: forward = .hidden
        }
        recall = row["recall"] as? Bool ?? false
        delete = (row["delete"] as? String).flatMap(Delete.init(rawValue:))
        pin = row["pin"] as? Bool ?? false
        star = (row["star"] as? String).flatMap(Star.init(rawValue:))
        starred = row["starred"] as? Bool ?? false
        pinned = row["pinned"] as? Bool ?? false
        isProtected = row["protected"] as? Bool ?? false
    }
}

extension ChatMessage {
    /// Parses one `ChatMessageJSON` (the `messages` of the chat state, the `items` of a shared-media page). nil without an id.
    init?(json: [String: Any], fallbackConversation: String) {
        guard let id = json["id"] as? String, !id.isEmpty else { return nil }
        func url(_ value: Any?) -> URL? {
            guard let text = value as? String, !text.isEmpty else { return nil }
            return URL(string: text)
        }
        func number(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }
        var quote: Quote?
        if let q = json["quote"] as? [String: Any] {
            quote = Quote(senderName: q["senderName"] as? String ?? "", text: q["text"] as? String ?? "",
                          messageIds: q["ids"] as? [String] ?? [])
        }
        let reactions = (json["reactions"] as? [[String: Any]] ?? []).compactMap { r -> Reaction? in
            guard let icon = ReactionIcon(json: r) else { return nil }
            return Reaction(icon: icon, count: clampedInt(number(r["count"])), includesMe: r["includesMe"] as? Bool ?? false,
                            names: r["names"] as? [String] ?? [], people: clampedInt(number(r["people"])))
        }
        let mentions = (json["mentions"] as? [[String: Any]] ?? []).compactMap { m -> Mention? in
            guard let uid = m["uid"] as? String, !uid.isEmpty else { return nil }
            return Mention(uid: uid, pos: clampedInt(number(m["pos"])), len: clampedInt(number(m["len"])), isAll: m["isAll"] as? Bool ?? false)
        }
        self.init(
            id: id,
            conversationId: json["conversationId"] as? String ?? fallbackConversation,
            senderId: json["senderId"] as? String ?? "",
            senderName: json["senderName"] as? String ?? "",
            senderAvatar: url(json["senderAvatar"]),
            isMine: json["isMine"] as? Bool ?? false,
            kind: Kind(json: json["kind"] as? [String: Any] ?? [:]),
            text: json["text"] as? String ?? "",
            date: Date(timeIntervalSince1970: number(json["date"]) / 1000),
            status: Status(rawValue: json["status"] as? String ?? "") ?? .sent,
            quote: quote,
            reactions: reactions,
            isE2EE: json["isE2EE"] as? Bool ?? false,
            mentions: mentions,
            cardButtons: CardButton.list(json: json["buttons"]),
            suggestsStickers: json["stickers"] as? Bool ?? false,
            menu: MessageMenu(json: json["menu"])
        )
    }
}

/// A button on a message card. `ref` names it for `window.__zaloChat.performAction` (card-actions-adapter.js);
/// `enabled` false = the official action needs UI this app does not have (`help` says so).
struct CardButton: Equatable, Hashable, Identifiable, Sendable {
    var ref: String
    var label: String
    var enabled: Bool = true
    var help: String = ""
    var id: String { ref }

    /// Parses the message-level `buttons` array; entries without a ref or label are dropped.
    static func list(json: Any?) -> [CardButton] {
        (json as? [[String: Any]] ?? []).compactMap { row in
            let ref = row["ref"] as? String ?? ""
            let label = (row["label"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !ref.isEmpty, !label.isEmpty else { return nil }
            return CardButton(ref: ref, label: label, enabled: (row["enabled"] as? NSNumber)?.boolValue ?? false, help: row["help"] as? String ?? "")
        }
    }
}

/// What `performAction` made of a click. Effects that need app UI (opening a conversation, a profile, a link) are applied by Swift.
enum CardActionOutcome: Equatable, Sendable {
    case done
    case openChat(String)
    case openProfile(String)
    case openURL(URL)
    /// Put this text on the pasteboard (zinstant clipboard actions).
    case copy(String)
    /// Open a native sheet / screen (alias dialog, group invite, sticker category, poll, side-bar tab).
    case present(CardSheet)
    /// The official action needs UI this app does not have.
    case unsupported(String)
    /// Sending is locked in this conversation (only admins may post).
    case locked(String)
    case failed(String)
    /// The official action was started but has not answered (yet): it may still happen, so nothing is retried and no text is given back.
    case pending(String)

    static let defaultUnsupported = "Chưa hỗ trợ trên ứng dụng này"
    /// The page did not answer within the Swift-side cap: the action may still happen, so the wording never invites a retry.
    static let noAnswerText = "Thao tác vẫn đang được xử lý. Hãy kiểm tra lại cuộc trò chuyện trước khi thử lại."
    static let defaultPending = "Thao tác đang được xử lý, chưa nhận được phản hồi. Hãy kiểm tra lại cuộc trò chuyện trước khi thử lại."

    init(json: Any?) {
        guard let root = json as? [String: Any], let status = root["status"] as? String else {
            self = .failed("Không thực hiện được thao tác.")
            return
        }
        let text = (root["text"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        switch status {
        case "done": self = .done
        case "effect":
            let effect = root["effect"] as? [String: Any] ?? [:]
            let id = effect["id"] as? String ?? effect["uid"] as? String ?? ""
            switch effect["type"] as? String {
            case "openChat" where !id.isEmpty: self = .openChat(id)
            case "openProfile" where !id.isEmpty: self = .openProfile(id)
            case "copy" where !(effect["text"] as? String ?? "").isEmpty: self = .copy(effect["text"] as? String ?? "")
            case "openURL":
                if let url = WebLink.sanitized((effect["url"] as? String).flatMap { URL(string: $0) }) { self = .openURL(url) }
                else { self = .unsupported(Self.defaultUnsupported) }
            default:
                if let sheet = CardSheet(effect: effect) { self = .present(sheet) } else { self = .unsupported(Self.defaultUnsupported) }
            }
        case "unsupported": self = .unsupported(text ?? Self.defaultUnsupported)
        case "locked": self = .locked(text ?? "Bạn không thể gửi tin nhắn vào cuộc trò chuyện này.")
        case "not-open": self = .failed("Cuộc trò chuyện chưa sẵn sàng, hãy thử lại sau giây lát.")
        // busy: an earlier run of this button has not settled, nothing new was started. pending: this run has not answered in time but may still
        // happen (a send may be on its way): the caller must not invite a retry or give typed text back.
        case "busy": self = .failed(text ?? "Thao tác đang được xử lý, hãy chờ giây lát.")
        case "pending": self = .pending(text ?? Self.defaultPending)
        default: self = .failed(text ?? "Không thực hiện được thao tác.")
        }
    }
}

/// A sticker the official e-card suggests (`cardStickers`): `ref` goes back to `performAction`.
struct SuggestedSticker: Equatable, Identifiable, Sendable {
    var ref: String
    var url: URL
    var id: String { ref }

    static func list(json: Any?) -> [SuggestedSticker] {
        (json as? [[String: Any]] ?? []).compactMap { row in
            guard let ref = row["ref"] as? String, !ref.isEmpty,
                  let text = row["url"] as? String, let url = WebLink.sanitized(URL(string: text)) else { return nil }
            return SuggestedSticker(ref: ref, url: url)
        }
    }
}

/// Profile summary of a contact (official profile popup, reduced to what the client holds locally).
struct ContactProfile: Equatable, Sendable {
    var uid: String
    var name: String
    var zaloName: String = ""
    var avatar: URL?
    var bio: String = ""
    var isSelf: Bool = false
    var isFriend: Bool = false
    /// Official `isOAType(profile)`: an Official Account (no add-friend button).
    var isOfficialAccount: Bool = false

    init(uid: String, name: String, zaloName: String = "", avatar: URL? = nil, bio: String = "", isSelf: Bool = false, isFriend: Bool = false, isOfficialAccount: Bool = false) {
        self.uid = uid; self.name = name; self.zaloName = zaloName; self.avatar = avatar
        self.bio = bio; self.isSelf = isSelf; self.isFriend = isFriend; self.isOfficialAccount = isOfficialAccount
    }

    init?(json: Any?) {
        guard let root = json as? [String: Any], let uid = root["uid"] as? String, !uid.isEmpty else { return nil }
        self.init(uid: uid, name: root["name"] as? String ?? "", zaloName: root["zaloName"] as? String ?? "",
                  avatar: (root["avatar"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }, bio: root["bio"] as? String ?? "",
                  isSelf: (root["isSelf"] as? NSNumber)?.boolValue ?? false, isFriend: (root["isFriend"] as? NSNumber)?.boolValue ?? false,
                  isOfficialAccount: (root["isOA"] as? NSNumber)?.boolValue ?? false)
    }
}

/// State of a reminder e-card as the official reminder controller derives it (card-actions-adapter.js `reminderSnapshot`).
struct ReminderSnapshot: Equatable, Sendable {
    /// Official card variants. `hidden` / `pending` are drawn as nothing by the official client (the static card is kept here).
    enum Variant: String, Sendable { case hidden, pending, invite, alert, demotedCreate, demotedAlert }
    enum Answer: String, Sendable { case accept, reject }

    var variant: Variant = .hidden
    /// Reminder id (not the message id): the key RSVP busy / pending state is shared under by every card of the reminder.
    var id = ""
    var title = ""
    var start: Date?
    var repeatLabel = ""
    var creatorName = ""
    var onlyMe = false
    var isGroup = false
    var mine: Answer?
    /// An answer is being sent (this card's controller, or another card of the same reminder): the answer buttons stay disabled.
    var pending: Answer?
    /// Counts of the official `rsvp` (people who accepted / declined).
    var acceptedCount = 0
    var rejectedCount = 0
    var canRsvp = false
    var canView = false
    var deleted = false
    var sig = ""

    /// The official card draws something (not hidden / pending).
    var isDrawn: Bool { variant != .hidden && variant != .pending }
    /// Official: `Ae && canRsvp && !deleted` and no answer yet → "Tham gia" / "Từ chối".
    var showsRsvpButtons: Bool { isGroup && !onlyMe && canRsvp && !deleted && mine == nil }
    var showsRsvpStatus: Bool { isGroup && !onlyMe && mine != nil }
    /// Official `STR_RMD_RSVP_RESPONDERS_LINK` row: group reminders that are not "only me".
    var hasResponders: Bool { isGroup && !onlyMe }
    /// Official `Xc.d(rsvp)`: "N người tham gia, M người từ chối" (nil while nobody answered).
    var responderSummary: String? {
        var parts: [String] = []
        if acceptedCount > 0 { parts.append("\(acceptedCount) người tham gia") }
        if rejectedCount > 0 { parts.append("\(rejectedCount) người từ chối") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    init() {}

    init?(json: Any?) {
        guard let root = json as? [String: Any] else { return nil }
        func flag(_ key: String) -> Bool { (root[key] as? NSNumber)?.boolValue ?? false }
        variant = Variant(rawValue: root["variant"] as? String ?? "") ?? .hidden
        id = root["rid"] as? String ?? ""
        title = root["title"] as? String ?? ""
        let ms = (root["start"] as? NSNumber)?.doubleValue ?? 0
        // Plausible timestamps only (1970 … 2100).
        start = ms > 0 && ms < 4_102_444_800_000 ? Date(timeIntervalSince1970: ms / 1000) : nil
        repeatLabel = root["repeat"] as? String ?? ""
        creatorName = root["creatorName"] as? String ?? ""
        onlyMe = flag("onlyMe"); isGroup = flag("isGroup"); canRsvp = flag("canRsvp"); canView = flag("canView"); deleted = flag("deleted")
        mine = Answer(rawValue: root["mine"] as? String ?? "")
        pending = Answer(rawValue: root["pending"] as? String ?? "")
        acceptedCount = max(0, clampedInt((root["accepted"] as? NSNumber)?.doubleValue ?? 0))
        rejectedCount = max(0, clampedInt((root["rejected"] as? NSNumber)?.doubleValue ?? 0))
        sig = root["sig"] as? String ?? ""
    }
}

/// Who accepted / declined a group reminder (card-actions-adapter.js `reminderResponders`; official responders page of the reminder detail).
struct ReminderResponders: Equatable, Sendable {
    struct Person: Identifiable, Equatable, Sendable {
        var id: String { uid }
        var uid: String
        var name: String
        var avatar: URL?
        var isMe: Bool
    }

    var accept: [Person] = []
    var reject: [Person] = []
    /// Full counts (the tab counts; like the official page they include people without a profile, who are not listed).
    var acceptTotal = 0
    var rejectTotal = 0
    /// People left out only because the list is capped.
    var acceptMore = 0
    var rejectMore = 0

    /// nil = could not be read (the page shows the official generic error).
    init?(json: Any?) {
        guard let root = json as? [String: Any], (root["ok"] as? NSNumber)?.boolValue == true else { return nil }
        func people(_ key: String) -> [Person] {
            var seen = Set<String>()
            return (root[key] as? [[String: Any]] ?? []).compactMap { row in
                guard let uid = row["uid"] as? String, !uid.isEmpty, seen.insert(uid).inserted else { return nil }
                return Person(uid: uid, name: row["name"] as? String ?? "", avatar: (row["avatar"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) },
                              isMe: (row["isMe"] as? NSNumber)?.boolValue ?? false)
            }
        }
        accept = people("accept")
        reject = people("reject")
        acceptTotal = max(accept.count, clampedInt((root["acceptTotal"] as? NSNumber)?.doubleValue ?? 0))
        rejectTotal = max(reject.count, clampedInt((root["rejectTotal"] as? NSNumber)?.doubleValue ?? 0))
        acceptMore = max(0, clampedInt((root["acceptMore"] as? NSNumber)?.doubleValue ?? 0))
        rejectMore = max(0, clampedInt((root["rejectMore"] as? NSNumber)?.doubleValue ?? 0))
    }
}

/// Result of the official "KẾT BẠN" pre-checks (`_onAddFriend`): whether the add-friend form may be shown, with its default message.
struct FriendRequestPrep: Equatable, Sendable {
    enum State: String, Sendable { case ready, requested, requesting, friend, me = "self", error }
    var state: State = .error
    var defaultMessage: String = ""
    var maxMessage: Int = 150

    init(state: State = .error, defaultMessage: String = "", maxMessage: Int = 150) {
        self.state = state; self.defaultMessage = defaultMessage; self.maxMessage = maxMessage
    }

    init(json: Any?) {
        let root = json as? [String: Any] ?? [:]
        let limit = clampedInt((root["maxMessage"] as? NSNumber)?.doubleValue ?? 150)
        self.init(state: State(rawValue: root["state"] as? String ?? "") ?? .error,
                  defaultMessage: root["defaultMessage"] as? String ?? "", maxMessage: limit > 0 ? min(limit, 500) : 150)
    }
}

/// Sender-supplied numbers can be NaN or astronomically large; `Int(_:)` traps on those.
func clampedInt(_ value: Double) -> Int {
    guard value.isFinite else { return 0 }
    return Int(max(-9e15, min(9e15, value)))
}

func clampedInt64(_ value: Double) -> Int64 { Int64(clampedInt(value)) }

/// The only links a message card may open: plain web pages. Mirrors the official `validOpenUrl` / `removeMaliciousScheme`
/// guard but stricter (allow-list), because `file:`, `smb:`, `ssh:` or app schemes would launch or mount things.
enum WebLink {
    static func sanitized(_ url: URL?) -> URL? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    @MainActor static func open(_ url: URL?) {
        if let safe = sanitized(url) { NSWorkspace.shared.open(safe) }
    }
}

extension ChatMessage.Kind {
    /// Parses the `kind` object of a `ChatMessageJSON` (see chat-adapter.js). Never fails: anything unrecognised
    /// becomes `.unsupported`, missing fields become empty values.
    init(json: [String: Any]) {
        func url(_ value: Any?) -> URL? {
            guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return URL(string: text)
        }
        func text(_ key: String) -> String { json[key] as? String ?? "" }
        func number(_ key: String) -> Double { (json[key] as? NSNumber)?.doubleValue ?? 0 }
        func flag(_ key: String) -> Bool { (json[key] as? NSNumber)?.boolValue ?? false }
        switch json["type"] as? String ?? "text" {
        case "text": self = .text
        case "photo": self = .photo(url: url(json["url"]), width: clampedInt(number("width")), height: clampedInt(number("height")))
        case "sticker": self = .sticker(url: url(json["url"]))
        case "gif": self = .gif(url: url(json["url"]))
        case "video": self = .video(thumbnail: url(json["thumbnail"]), duration: clampedInt(number("duration")), url: url(json["url"]))
        case "voice": self = .voice(url: url(json["url"]), duration: clampedInt(number("duration")))
        case "file": self = .file(name: text("name"), size: clampedInt64(number("size")), url: url(json["url"]))
        case "link":
            self = .link(title: text("title"), url: WebLink.sanitized(url(json["url"])), thumbnail: url(json["thumbnail"]),
                         description: text("description"), source: text("source"))
        case "contactCard":
            self = .contactCard(ChatMessage.ContactCard(
                name: text("name"), uid: text("uid"), avatar: url(json["avatar"]), phone: text("phone"),
                qr: url(json["qr"]), oaLink: text("oaLink"), isOfficialAccount: flag("isOA")))
        case "location":
            var info = ChatMessage.LocationInfo(title: text("title"), address: text("address"), thumbnail: url(json["thumbnail"]))
            if flag("hasCoordinates") {
                let lat = number("latitude"), lon = number("longitude")
                if abs(lat) <= 90, abs(lon) <= 180 { info.coordinate = .init(latitude: lat, longitude: lon) }
            }
            self = .location(info)
        case "call":
            self = .call(video: flag("video"), missed: flag("missed"), duration: clampedInt(number("duration")),
                         title: text("title"), detail: text("detail"))
        case "ecard":
            var card = ChatMessage.ECard()
            card.style = ChatMessage.ECard.Style(rawValue: text("style")) ?? .banner
            card.image = url(json["image"])
            card.thumb = url(json["thumb"])
            card.title = text("title")
            card.description = text("description")
            card.actions = (json["actions"] as? [Any] ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }
            card.avatars = (json["avatars"] as? [Any] ?? []).compactMap { url($0) }
            card.reminderTitle = text("reminderTitle")
            let start = number("reminderStart")
            // Plausible timestamps only (1970 … 2100); anything else is sender noise.
            card.reminderStart = start > 0 && start < 4_102_444_800_000 ? Date(timeIntervalSince1970: start / 1000) : nil
            card.reminderRepeat = text("reminderRepeat")
            self = .ecard(card)
        case "oaMessage":
            let parts = (json["parts"] as? [[String: Any]] ?? []).compactMap { row -> ChatMessage.OAPart? in
                let title = row["title"] as? String ?? ""
                let thumb = url(row["thumb"])
                guard !title.isEmpty || thumb != nil else { return nil }
                return ChatMessage.OAPart(isHeader: (row["header"] as? NSNumber)?.boolValue ?? false, title: title,
                                          description: row["description"] as? String ?? "", thumb: thumb, url: WebLink.sanitized(url(row["url"])),
                                          help: row["help"] as? String ?? "")
            }
            self = .oaMessage(parts)
        case "poll":
            self = .poll(ChatMessage.PollInfo(question: text("question"), header: text("header"), anonymous: flag("anonymous"),
                                              pollId: text("pollId"), conversationId: text("conversationId")))
        case "stickerSet": self = .stickerSet(title: text("title"), thumbnail: url(json["thumb"]))
        case "zinstant": self = .zinstant(title: text("title"), text: text("text"), thumbnail: url(json["thumb"]))
        case "notice": self = .notice(symbol: text("symbol").isEmpty ? "info.circle" : text("symbol"), text: text("text"))
        case "placeholder": self = .placeholder(symbol: text("symbol").isEmpty ? "lock" : text("symbol"), text: text("text"))
        case "system": self = .system
        case "recalled": self = .recalled
        default: self = .unsupported(type: text("rawType"))
        }
    }
}

/// Who reacted to a message (the official "Biểu cảm" popup, `reactors` in chat-adapter.js).
struct ReactionDetail: Equatable, Sendable {
    struct Tab: Identifiable, Equatable, Sendable {
        var icon: ReactionIcon
        var total: Int
        var id: String { icon.id }
    }

    struct Icon: Equatable, Sendable {
        var icon: ReactionIcon
        var count: Int
    }

    struct User: Identifiable, Equatable, Sendable {
        var uid: String
        var name: String
        var avatar: URL?
        var isMe: Bool
        /// Everything this person reacted with, including types that have no icon.
        var total: Int
        /// Icons this person used, most-used first.
        var icons: [Icon]
        var id: String { uid }
    }

    /// One tab per icon, by total descending ("Tất cả" is implicit).
    var tabs: [Tab]
    /// Everyone who reacted, in the official "Tất cả" order (total desc, me first, then first reaction type).
    var users: [User]

    var isEmpty: Bool { users.isEmpty }
    /// "Tất cả" total (counts types without an icon too).
    var total: Int { users.reduce(0) { $0 + $1.total } }

    /// Fallback shown when the official client has no profile for a reactor.
    static let unknownName = "Người dùng Zalo"

    /// Rows for a tab: `nil` = "Tất cả" (up to 6 icons each); a reaction type = people who used it, with their count of it.
    func rows(for type: String?) -> [User] {
        guard let type else {
            return users.map { user in
                var user = user
                user.icons = Array(user.icons.prefix(6))
                return user
            }
        }
        return users.enumerated().compactMap { index, user -> (Int, User)? in
            guard let used = user.icons.first(where: { $0.icon.type == type }) else { return nil }
            var user = user
            user.icons = [used]
            user.total = used.count
            return (index, user)
        }
        // Same ordering rule as "Tất cả": count desc, me first, otherwise the overall order.
        .sorted { a, b in
            if a.1.total != b.1.total { return a.1.total > b.1.total }
            if a.1.isMe != b.1.isMe { return a.1.isMe }
            return a.0 < b.0
        }
        .map(\.1)
    }

    /// The official count label (dG4g.c): up to 999 as is, then "1k" … "9k"; "k+" when there is a remainder or the value is over 9999.
    static func shortCount(_ n: Int) -> String {
        if n <= 0 { return "0" }
        if n <= 999 { return String(n) }
        let thousands = n / 1000
        let k = min(thousands, 9)
        return n % 1000 > 0 || thousands > 9 ? "\(k)k+" : "\(k)k"
    }

    /// Parses the `reactors` JS result; nil when it is not the expected object (JS `null` = unknown).
    init?(json: Any?) {
        guard let root = json as? [String: Any] else { return nil }
        func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
        tabs = (root["tabs"] as? [[String: Any]] ?? []).compactMap { row in
            ReactionIcon(json: row).map { Tab(icon: $0, total: int(row["total"])) }
        }
        users = (root["users"] as? [[String: Any]] ?? []).compactMap { row in
            guard let uid = row["uid"] as? String, !uid.isEmpty else { return nil }
            let name = (row["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let icons = (row["icons"] as? [[String: Any]] ?? []).compactMap { entry in
                ReactionIcon(json: entry).map { Icon(icon: $0, count: int(entry["count"])) }
            }
            return User(uid: uid, name: name.isEmpty ? Self.unknownName : name,
                        avatar: (row["avatar"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) },
                        isMe: row["isMe"] as? Bool ?? false, total: int(row["total"]), icons: icons)
        }
    }
}

/// Phone → PC message transfer ("Đồng bộ tin nhắn"), driven by the official client.
struct MessageTransferState: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        /// Official client asks whether to sync history from the phone.
        case offer
        /// Waiting for the user to confirm on the phone.
        case waitingForPhone
        case transferring
        case finished
        case failed(String)
    }
    var phase: Phase
    /// 0…1 when known.
    var progress: Double?
    var syncedConversations: Int
    var totalConversations: Int?
    var message: String?
    // Optional detail from the official client (transfer-adapter.js `TransferJSON`).
    /// Official stage: modal / suggestion / openMobile / confirmMobile / waitForBackup /
    /// conversationList / messages / otherMessages / downloading / decrypting / restoring.
    var stage: String? = nil
    var stageIndex: Int? = nil
    var stageCount: Int? = nil
    /// 0…1 progress of the current stage, nil = indeterminate.
    var stageProgress: Double? = nil
    /// Messages stored so far in the long "other messages" stage (its official progress only counts finished conversations).
    var receivedMessages: Int? = nil
    var errorCode: Int? = nil
    var errorName: String? = nil
    /// Failed phase: `respondToTransfer(accept: true)` retries.
    var canRetry: Bool = false
    /// Server-driven texts of the official first-login modal.
    var officialTitle: String? = nil
    var officialDescription: String? = nil
    var officialSuggestion: String? = nil
}
