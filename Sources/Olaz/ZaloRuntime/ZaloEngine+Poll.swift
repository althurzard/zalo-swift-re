import Foundation

// Group polls (MSG_POLL 26), bridged to `HostScripts/poll-adapter.js` (`window.__zaloPoll`; posts
// {page:'main', poll:{id, detail}} / {page:'main', poll:{id, error}}). Everything runs through the official
// GroupPollManager (see the adapter header). Writes (vote / lock / share / create) are only called from explicit
// button presses in `PollViews.swift`.

// MARK: - Poll model

struct PollDetail: Equatable, Sendable, Identifiable {
    struct Option: Equatable, Sendable, Identifiable {
        var id: String
        var content: String
        var votes: Int
        var voted: Bool
    }

    var id: String
    /// Conversation id ("g…") the poll lives in.
    var groupId: String
    var question: String
    var creator: String
    var creatorName: String
    var created: Date?
    var expires: Date?
    var closed: Bool
    /// I have voted (official `joined`).
    var joined: Bool
    var multi: Bool
    var allowAdd: Bool
    var anonymous: Bool
    var hidePreview: Bool
    /// Distinct people who voted.
    var voterCount: Int
    /// Owner / deputy / creator (official `isEnableClose`).
    var canClose: Bool
    var options: [Option]

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String, !id.isEmpty else { return nil }
        func text(_ key: String) -> String { json[key] as? String ?? "" }
        func flag(_ key: String) -> Bool { (json[key] as? NSNumber)?.boolValue ?? false }
        func date(_ key: String) -> Date? {
            let ms = (json[key] as? NSNumber)?.doubleValue ?? 0
            return ms > 0 && ms < 4_102_444_800_000 ? Date(timeIntervalSince1970: ms / 1000) : nil
        }
        self.id = id
        groupId = text("groupId")
        question = text("question")
        creator = text("creator")
        creatorName = text("creatorName")
        created = date("created")
        expires = date("expired")
        closed = flag("closed")
        joined = flag("joined")
        multi = flag("multi")
        allowAdd = flag("allowAdd")
        anonymous = flag("anonymous")
        hidePreview = flag("hidePreview")
        voterCount = clampedInt((json["voters"] as? NSNumber)?.doubleValue ?? 0)
        canClose = flag("canClose")
        options = (json["options"] as? [[String: Any]] ?? []).compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            return Option(id: id, content: row["content"] as? String ?? "",
                          votes: max(0, clampedInt((row["votes"] as? NSNumber)?.doubleValue ?? 0)),
                          voted: (row["voted"] as? NSNumber)?.boolValue ?? false)
        }
    }

    var totalVotes: Int { options.reduce(0) { $0 + $1.votes } }

    func isExpired(at now: Date = .now) -> Bool { expires.map { $0 < now } ?? false }

    /// Votes cannot change any more: closed, expired, or (results hidden until voting) already voted.
    func isVotingLocked(at now: Date = .now) -> Bool { closed || isExpired(at: now) || (hidePreview && joined) }

    /// "Ẩn kết quả khi chưa bình chọn": the numbers are only meaningful after I voted.
    var resultsHidden: Bool { hidePreview && !joined }

    /// Official `isEnableViewDetail`: voter list is offered when the poll is not anonymous and results are visible.
    var votersVisible: Bool { !anonymous && !resultsHidden && totalVotes > 0 }

    func weight(of option: Option) -> Double { totalVotes > 0 ? Double(option.votes) / Double(totalVotes) : 0 }
}

/// What the vote popup edits: which existing options are ticked and the options being added. Mirrors the
/// official reducer (single choice: ticking one unticks the others, added options included).
struct PollVoteDraft: Equatable {
    struct Added: Identifiable, Equatable {
        var id = UUID()
        var text = ""
        var voted = false
    }

    private(set) var selected: Set<String>
    private let original: Set<String>
    private let multi: Bool
    var added: [Added] = []

    init(_ detail: PollDetail) {
        let voted = Set(detail.options.filter(\.voted).map(\.id))
        selected = voted
        original = voted
        multi = detail.multi
    }

    mutating func toggle(_ optionId: String) {
        if selected.contains(optionId) { selected.remove(optionId); return }
        if !multi { selected = []; for i in added.indices { added[i].voted = false } }
        selected.insert(optionId)
    }

    mutating func setAddedVoted(_ id: UUID, _ voted: Bool) {
        guard let at = added.firstIndex(where: { $0.id == id }) else { return }
        if voted && !multi { selected = []; for i in added.indices { added[i].voted = false } }
        added[at].voted = voted
    }

    mutating func addRow() { added.append(Added()) }
    mutating func removeAdded(_ id: UUID) { added.removeAll { $0.id == id } }

    private var filled: [Added] {
        added.map { Added(id: $0.id, text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines), voted: $0.voted) }.filter { !$0.text.isEmpty }
    }

    /// Anything to send: a changed tick or a new option (official confirm button state).
    var hasChanges: Bool { selected != original || !filled.isEmpty }

    /// Nothing is ticked (existing or added): the official "hide results" confirmation is skipped for this.
    var votesNothing: Bool { selected.isEmpty && !filled.contains(where: \.voted) }

    /// Same trimmed text used twice among the existing and the added options.
    func hasDuplicates(in detail: PollDetail) -> Bool {
        let all = detail.options.map { $0.content.trimmingCharacters(in: .whitespacesAndNewlines) } + filled.map(\.text)
        return Set(all).count != all.count
    }

    func isDuplicate(_ id: UUID, in detail: PollDetail) -> Bool {
        guard let row = filled.first(where: { $0.id == id }) else { return false }
        let others = detail.options.map { $0.content.trimmingCharacters(in: .whitespacesAndNewlines) } + filled.filter { $0.id != id }.map(\.text)
        return others.contains(row.text)
    }

    /// Arguments of `window.__zaloPoll.vote` (option ids in the poll's own order).
    func request(for detail: PollDetail) -> (newOptions: [[String: Any]], votedIds: [String]) {
        (filled.map { ["voted": $0.voted, "content": $0.text] }, detail.options.map(\.id).filter(selected.contains))
    }

    /// The poll as it would look after this vote (live preview of the bars, like the official popup).
    func applied(to detail: PollDetail) -> PollDetail {
        var next = detail
        for i in next.options.indices {
            let was = detail.options[i].voted, now = selected.contains(detail.options[i].id)
            next.options[i].voted = now
            if was != now { next.options[i].votes = max(0, next.options[i].votes + (now ? 1 : -1)) }
        }
        return next
    }

    var canSubmit: Bool { hasChanges }
}

struct PollVoters: Equatable, Sendable {
    struct User: Identifiable, Equatable, Sendable {
        var id: String { uid }
        var uid: String
        var name: String
        var avatar: URL?
        var isMe: Bool
    }
    struct Group: Identifiable, Equatable, Sendable {
        var id: String
        var content: String
        var votes: Int
        var users: [User]
    }

    /// Anonymous poll / results hidden until I vote: the official client shows no voter list.
    var restricted: Bool
    var groups: [Group]

    init?(json: Any?) {
        guard let object = json as? [String: Any] else { return nil }
        restricted = (object["restricted"] as? NSNumber)?.boolValue ?? false
        groups = (object["groups"] as? [[String: Any]] ?? []).compactMap { row in
            guard let id = row["optionId"] as? String else { return nil }
            let users = (row["users"] as? [[String: Any]] ?? []).compactMap { u -> User? in
                guard let uid = u["uid"] as? String, !uid.isEmpty else { return nil }
                return User(uid: uid, name: u["name"] as? String ?? "", avatar: (u["avatar"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) },
                            isMe: (u["isMe"] as? NSNumber)?.boolValue ?? false)
            }
            return Group(id: id, content: row["content"] as? String ?? "", votes: clampedInt((row["votes"] as? NSNumber)?.doubleValue ?? 0), users: users)
        }
    }
}

/// Official `groupPoll` limits (config) used by the create popup.
struct PollConfig: Equatable, Sendable {
    var minOptions = 2
    var maxOptions = 30
    var maxQuestion = 200
    var maxOption = 120
    var enableAnonymous = true
    var enableHidePreview = true
    /// Options shown on the chat card before "* Còn N lựa chọn khác".
    var displayOptions = 3

    init() {}

    init(json: [String: Any]?) {
        guard let json else { return }
        func count(_ key: String, _ fallback: Int) -> Int {
            let value = clampedInt((json[key] as? NSNumber)?.doubleValue ?? 0)
            return value > 0 ? value : fallback
        }
        minOptions = count("minOptions", minOptions)
        maxOptions = max(minOptions, count("maxOptions", maxOptions))
        maxQuestion = count("maxQuestion", maxQuestion)
        maxOption = count("maxOption", maxOption)
        displayOptions = count("displayOptions", displayOptions)
        enableAnonymous = (json["enableAnonymous"] as? NSNumber)?.boolValue ?? true
        enableHidePreview = (json["enableHidePreview"] as? NSNumber)?.boolValue ?? true
    }
}

struct PollCapabilities: Equatable, Sendable {
    var ready = false
    var canCreate = false
    var canPin = false
    var config = PollConfig()

    init() {}

    init(json: Any?) {
        guard let o = json as? [String: Any] else { return }
        ready = (o["ready"] as? NSNumber)?.boolValue ?? false
        canCreate = (o["canCreate"] as? NSNumber)?.boolValue ?? false
        canPin = (o["canPin"] as? NSNumber)?.boolValue ?? false
        config = PollConfig(json: o["config"] as? [String: Any])
    }
}

/// The "Tạo bình chọn" form (official create popup defaults: multiple choice and "add option" on).
struct PollCreateDraft: Equatable {
    enum Issue: Equatable {
        case emptyQuestion, tooFewOptions(Int), duplicate, pastDeadline
    }

    var question = ""
    var options: [String]
    var hasDeadline = false
    var deadline = Date.now.addingTimeInterval(86_400)
    var pin = false
    var multi = true
    var allowAdd = true
    var hidePreview = false
    var anonymous = false

    init(config: PollConfig = PollConfig()) { options = Array(repeating: "", count: config.minOptions) }

    var trimmedQuestion: String { question.trimmingCharacters(in: .whitespacesAndNewlines) }
    var filledOptions: [String] { options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }

    func isDuplicate(at index: Int) -> Bool {
        guard options.indices.contains(index) else { return false }
        let text = options[index].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        return options.enumerated().contains { $0.offset != index && $0.element.trimmingCharacters(in: .whitespacesAndNewlines) == text }
    }

    /// First reason the poll cannot be created yet; nil = ready.
    func issue(config: PollConfig, now: Date = .now) -> Issue? {
        if trimmedQuestion.isEmpty { return .emptyQuestion }
        let filled = filledOptions
        if Set(filled).count != filled.count { return .duplicate }
        if filled.count < config.minOptions { return .tooFewOptions(config.minOptions) }
        if hasDeadline && deadline.timeIntervalSince(now) <= 0 { return .pastDeadline }
        return nil
    }

    /// "Add option" is meaningless while results are hidden (official create popup disables and sends false).
    var effectiveAllowAdd: Bool { allowAdd && !hidePreview }

    /// Argument of `window.__zaloPoll.create`.
    func spec(config: PollConfig, canPin: Bool) -> [String: Any] {
        [
            "question": String(trimmedQuestion.prefix(config.maxQuestion)),
            "options": filledOptions.map { String($0.prefix(config.maxOption)) },
            "expired": hasDeadline ? Int(deadline.timeIntervalSince1970 * 1000) : 0,
            "pin": pin && canPin, "multi": multi, "allowAdd": effectiveAllowAdd,
            "hidePreview": hidePreview && config.enableHidePreview, "anonymous": anonymous && config.enableAnonymous,
        ]
    }
}

enum PollAction { case vote, lock, share, create, pin, unpin }

struct PollActionResult: Equatable, Sendable {
    var ok: Bool
    var error: String?
    /// The poll was created, but "ghim" was left out (the board is full or could not be checked): pin it from its menu.
    var pinSkipped = false

    /// Official toast / modal texts (lang_vi.json).
    func message(for action: PollAction) -> String {
        switch error {
        case "closed": "Có lỗi xảy ra do bình chọn đã bị khoá"
        case "expired": "Bình chọn đã hết hạn"
        case "network": "Không có mạng, vui lòng kiểm tra lại kết nối và thử lại"
        case "duplicate": "Phương án được thêm đã tồn tại"
        case "forbidden":
            switch action {
            case .create: "Bạn không đủ quyền tạo bình chọn"
            case .pin, .unpin: "Bạn không có quyền thực hiện thao tác này."   // STR_ONLY_ADMIN_INTERACT_PIN_BOARD
            default: "Bạn không có quyền khóa bình chọn này"
            }
        case "limit": "Bảng ghim đã đầy. Hãy bỏ bớt ghim trong Zalo rồi thử lại."
        case "partial": "Đã bỏ ghim cũ nhưng chưa ghim được bình chọn. Vui lòng thử ghim lại."
        case "unknown": "Chưa xác nhận được kết quả. Vui lòng kiểm tra lại bình chọn sau."
        default:
            switch action {
            case .vote: "Có lỗi xảy ra trong quá trình bình chọn."
            case .lock: "Có lỗi xảy ra trong quá trình khóa bình chọn. Vui lòng thử lại."
            case .share: "Có lỗi xảy ra trong quá trình chia sẻ bình chọn. Vui lòng thử lại."
            case .create: "Có lỗi xảy ra trong quá trình tạo bình chọn. Vui lòng kiểm tra lại."
            case .pin: "Ghim bình chọn không thành công. Vui lòng thử lại."
            case .unpin: "Bỏ ghim không thành công. Vui lòng thử lại."
            }
        }
    }
}

/// Whether the group's board lets me pin, and whether this poll is pinned (poll-adapter.js `pinState`; official board topics).
/// Not `ready` = unknown / not offered (not a group, topic board unavailable): the pin item is hidden and nothing is guessed.
struct PollPinState: Equatable, Sendable {
    var ready = false
    /// Official `isEnablePin`: owner / deputy, or members when the group allows setting topics.
    var canPin = false
    var pinned = false
    /// Pinned topics the board holds at most (`pinLimit`).
    var limit = 0

    init() {}

    init(json: Any?) {
        guard let o = json as? [String: Any] else { return }
        ready = (o["ready"] as? NSNumber)?.boolValue ?? false
        canPin = (o["canPin"] as? NSNumber)?.boolValue ?? false
        pinned = (o["pinned"] as? NSNumber)?.boolValue ?? false
        limit = max(0, clampedInt((o["limit"] as? NSNumber)?.doubleValue ?? 0))
    }

    /// The menu offers "Ghim" / "Bỏ ghim" (official: only with `isEnablePin`).
    var offersPin: Bool { ready && canPin }
}

/// The board is full: the official "Cập nhật danh sách ghim" dialog, asked natively. Confirming replaces the oldest pin.
struct PollPinConfirm: Equatable, Sendable {
    /// Identifies the exact topic that would go (sent back with the confirmation).
    var ref: String
    var limit: Int
    var kind: String
    var title: String

    init?(json: Any?) {
        guard let o = json as? [String: Any], let ref = o["ref"] as? String, !ref.isEmpty else { return nil }
        self.ref = ref
        limit = max(0, clampedInt((o["limit"] as? NSNumber)?.doubleValue ?? 0))
        let replace = o["replace"] as? [String: Any]
        kind = replace?["kind"] as? String ?? ""
        title = replace?["title"] as? String ?? ""
    }

    /// STR_ONLY_PIN_MAX_CONTENT + STR_DIRECTION_PIN_LIMIT, then the pin that goes.
    var message: String {
        let label: String
        switch kind {
        case "poll": label = "Bình chọn"
        case "reminder": label = "Nhắc hẹn"
        case "message": label = "Tin nhắn"
        default: label = "Ghi chú"
        }
        let head = limit > 0 ? "Đã đạt giới hạn \(limit) ghim. " : ""
        return head + "Ghim cũ dưới đây sẽ được bỏ để cập nhật nội dung mới.\n" + (title.isEmpty ? label : "\(label): \(title)")
    }
}

enum PollPinOutcome: Equatable, Sendable {
    case done
    case needsConfirmation(PollPinConfirm)
    case failed(PollActionResult)
}

struct PollStore: Equatable {
    var details: [String: PollDetail] = [:]
    /// Board state per poll (read when a card / the sheet is on screen).
    var pins: [String: PollPinState] = [:]
    /// Polls whose last read failed (the card offers a retry).
    var failed: Set<String> = []
}

// MARK: - Engine

@MainActor
private enum PollClock {
    static var refreshTasks: [String: Task<Void, Never>] = [:]
    /// Poll event messages already answered with a refresh (each message once).
    static var seenMessages: Set<String> = []
    /// Polls on screen (id → conversation): re-registered with the page after a WebContent reload.
    static var watched: [String: String] = [:]
    static var lastAttempt: [String: Date] = [:]
}

extension ZaloEngine {
    /// Starts reading the poll (official `getPollDetail`: cache → DB → server) and keeps it live. Called when a card is on screen.
    func watchPoll(_ id: String, in conversationId: String) {
        guard !id.isEmpty else { return }
        PollClock.watched[id] = conversationId
        if PollClock.watched.count > 500, let drop = PollClock.watched.keys.first(where: { $0 != id }) { PollClock.watched[drop] = nil; PollClock.lastAttempt[drop] = nil }
        guard polls.details[id] == nil else { return }
        // A failed read is retried at most every 5 s by scrolling; the card's "Thử lại" button retries at once.
        if let last = PollClock.lastAttempt[id], Date.now.timeIntervalSince(last) < 5 { return }
        PollClock.lastAttempt[id] = .now
        polls.failed.remove(id)
        callPoll("watch", id, conversationId)
    }

    func retryPoll(_ id: String, in conversationId: String) {
        PollClock.lastAttempt[id] = .now
        polls.failed.remove(id)
        callPoll("watch", id, conversationId)
    }

    /// The main page (re)loaded: its JS context knows no watches, so register every poll on screen again.
    func rewatchPolls() {
        for (id, conversationId) in PollClock.watched { callPoll("watch", id, conversationId) }
    }

    func refreshPoll(_ id: String) { callPoll("refresh", id, false) }

    /// Who voted for what, from the official poll data + profile service. nil = could not be read.
    func pollVoters(_ id: String) async -> PollVoters? {
        PollVoters(json: await awaitPollWithin(45, "voters", id))
    }

    /// Reads the group's board topics (official `loadTopics`, once per group) and whether this poll is pinned. Read-only.
    @discardableResult
    func refreshPollPin(_ id: String, in conversationId: String) async -> PollPinState {
        let state = PollPinState(json: await awaitPollWithin(30, "pinState", conversationId, id))
        // A transient failure keeps what was known (the menu item does not flicker away).
        if (state.ready || polls.pins[id] == nil), polls.pins[id] != state { polls.pins[id] = state }
        return polls.pins[id] ?? state
    }

    /// WRITE (user chose "Ghim lên đầu trò chuyện"): official `callCreateOrPinTopic`. When the board is full the first call answers
    /// `.needsConfirmation` (nothing changed); the user's confirmation calls again with that `ref`, which drops the oldest pin first.
    func pinPoll(_ id: String, in conversationId: String, confirming ref: String? = nil) async -> PollPinOutcome {
        // Bounded on the page (about a minute at most); no answer at all means the result is not known.
        guard let answer = await awaitPollWithin(100, "pin", conversationId, id, ref ?? NSNull()) else {
            settlePollPin(id, in: conversationId, pinned: true, optimistic: false)
            return .failed(PollActionResult(ok: false, error: "unknown"))
        }
        if let json = answer as? [String: Any], json["error"] as? String == "confirm", let confirm = PollPinConfirm(json: json) { return .needsConfirmation(confirm) }
        let result = actionResult(answer)
        if result.ok { settlePollPin(id, in: conversationId, pinned: true) }
        return result.ok ? .done : .failed(result)
    }

    /// WRITE (user chose "Bỏ ghim bình chọn"): official `callUnpinTopic`.
    func unpinPoll(_ id: String, in conversationId: String) async -> PollActionResult {
        guard let answer = await awaitPollWithin(100, "unpin", conversationId, id) else {
            settlePollPin(id, in: conversationId, pinned: false, optimistic: false)
            return PollActionResult(ok: false, error: "unknown")
        }
        let result = actionResult(answer)
        if result.ok { settlePollPin(id, in: conversationId, pinned: false) }
        return result
    }

    /// The board is updated by the sync event: show the answer at once, then re-read until the board agrees (bounded).
    private func settlePollPin(_ id: String, in conversationId: String, pinned expected: Bool, optimistic: Bool = true) {
        if optimistic, var state = polls.pins[id], state.ready { state.pinned = expected; polls.pins[id] = state }
        Task { [weak self] in
            for delay in [1.0, 2.5, 5.0] {
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled else { return }
                if await refreshPollPin(id, in: conversationId).pinned == expected { return }
            }
        }
    }

    func pollCapabilities(in conversationId: String) async -> PollCapabilities {
        PollCapabilities(json: await awaitPollWithin(30, "capabilities", conversationId))
    }

    /// WRITE (user pressed "Xác nhận"): official `votePoll` — vote / change vote / unvote, plus options added by me.
    func votePoll(_ id: String, in conversationId: String, draft: PollVoteDraft, detail: PollDetail) async -> PollActionResult {
        let request = draft.request(for: detail)
        return actionResult(await awaitPoll("vote", conversationId, id, request.newOptions, request.votedIds))
    }

    /// WRITE (user confirmed "Khóa bình chọn"): official `lockPoll`.
    func lockPoll(_ id: String, in conversationId: String) async -> PollActionResult {
        actionResult(await awaitPoll("lock", conversationId, id))
    }

    /// WRITE (user chose "Gửi vào nhóm"): official `sharePollInGroup` — posts the poll again into the group.
    func sharePoll(_ id: String, in conversationId: String) async -> PollActionResult {
        actionResult(await awaitPoll("share", conversationId, id))
    }

    /// WRITE (user pressed "Tạo bình chọn"): official `createPoll`.
    func createPoll(in conversationId: String, draft: PollCreateDraft, config: PollConfig, canPin: Bool) async -> PollActionResult {
        actionResult(await awaitPoll("create", conversationId, draft.spec(config: config, canPin: canPin)))
    }

    private func actionResult(_ value: Any?) -> PollActionResult {
        guard let json = value as? [String: Any] else { return PollActionResult(ok: false, error: "unavailable") }
        return PollActionResult(ok: (json["ok"] as? NSNumber)?.boolValue ?? false, error: json["error"] as? String,
                                pinSkipped: (json["pinSkipped"] as? NSNumber)?.boolValue ?? false)
    }

    /// New poll event messages (vote / update / close by anyone) → re-read the poll if the official sync did not refresh it.
    func notePollMessages(_ incoming: [ChatMessage]) {
        for message in incoming {
            guard case .poll(let info) = message.kind, !info.pollId.isEmpty, polls.details[info.pollId] != nil,
                  message.date > Date.now.addingTimeInterval(-120), PollClock.seenMessages.insert(message.id).inserted else { continue }
            if PollClock.seenMessages.count > 2000 { PollClock.seenMessages = [message.id] }
            let id = info.pollId
            PollClock.refreshTasks[id]?.cancel()
            PollClock.refreshTasks[id] = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(1500))
                guard !Task.isCancelled else { return }
                PollClock.refreshTasks[id] = nil
                self?.callPoll("refresh", id, true)
            }
        }
    }

    func handlePoll(state: [String: Any]) {
        guard let json = state["poll"] as? [String: Any], let id = json["id"] as? String else { return }
        if let detail = (json["detail"] as? [String: Any]).flatMap(PollDetail.init(json:)) {
            polls.failed.remove(id)
            if polls.details[id] != detail { polls.details[id] = detail }
        } else if json["error"] != nil, polls.details[id] == nil {
            polls.failed.insert(id)
        }
    }

    func resetPolls() {
        polls = PollStore()
        PollClock.refreshTasks.values.forEach { $0.cancel() }
        PollClock.refreshTasks = [:]
        PollClock.seenMessages = []
        PollClock.watched = [:]
        PollClock.lastAttempt = [:]
        callPoll("reset")
    }

    /// `window.__zaloPoll[method](...args)` without waiting for the answer.
    private func callPoll(_ method: String, _ args: Any...) {
        guard let json = Self.pollArguments(args) else { return }
        let script = "const c = window.__zaloPoll; if (!c || !c.\(method)) return 'missing'; c.\(method)(...\(json)); return 'ok';"
        Task { [weak self] in
            let result = await self?.host?.evaluate(script)
            if (result as? String) != "ok" { EngineLog.shared.write("poll \(method) → \(result ?? "nil")") }
        }
    }

    /// `await window.__zaloPoll[method](...args)`.
    private func awaitPoll(_ method: String, _ args: Any...) async -> Any? {
        guard let json = Self.pollArguments(args) else { return nil }
        let script = "const c = window.__zaloPoll; if (!c || !c.\(method)) return null; return await c.\(method)(...\(json));"
        return await host?.evaluate(script)
    }

    /// `awaitPoll` that gives up after `seconds` (the page keeps working; its late answer is dropped). nil = no answer.
    private func awaitPollWithin(_ seconds: Double, _ method: String, _ args: Any...) async -> Any? {
        guard let json = Self.pollArguments(args) else { return nil }
        let script = "const c = window.__zaloPoll; if (!c || !c.\(method)) return null; return await c.\(method)(...\(json));"
        let answer = await raceTimeout(seconds) { [self] in JSBox(value: await host?.evaluate(script)) }
        return answer?.value
    }

    private static func pollArguments(_ args: [Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: args, options: [.fragmentsAllowed]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
