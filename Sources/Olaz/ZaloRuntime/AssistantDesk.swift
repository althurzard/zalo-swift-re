import Foundation
import UserNotifications

/// Local assistant channel for AI tools (the `olaz-mcp` server): read conversations and **propose** replies.
///
/// Nothing is ever sent on its own. A proposal lands in `drafts`; only the user's click in the "Duyệt nháp" window sends it,
/// and even then `SendGuard` paces and caps what goes out so the account does not look like a spam bot.
///
/// Off by default (Settings ▸ Trợ lý AI). Socket: `~/Library/Application Support/Olaz/assistant.sock`, mode 0600, one JSON
/// object per line: `{"id":1,"method":"list_conversations","params":{}}` → `{"id":1,"result":…}` or `{"id":1,"error":"…"}`.
@MainActor
@Observable
final class AssistantDesk {
    static let enabledKey = "olaz.assistant.enabled"
    /// Lets the AI approve a draft the user OK'd in chat ("duyệt"). Off by default.
    static let chatApprovalKey = "olaz.assistant.chatApproval"
    static let minDraftAgeForChatApproval: TimeInterval = 5
    static var socketPath: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Olaz", isDirectory: true).appendingPathComponent("assistant.sock").path
    }

    struct Draft: Identifiable, Equatable {
        enum State: Equatable {
            case pending
            /// Approved, waiting for `SendGuard` to allow it (`notBefore`).
            case queued(notBefore: Date)
            case sending
            case sent(Date)
            case discarded
            case failed(String)
        }
        let id: String
        let conversationId: String
        var conversationName: String
        var text: String
        var quoteMessageId: String?
        /// Why the AI proposes this (shown to the reviewer, never sent).
        var note: String
        /// The customer message it answers (for the reviewer's context).
        var replyingTo: String
        let created: Date
        var state: State = .pending
        var warnings: [String] = []

        var isOpen: Bool {
            switch state { case .pending, .queued, .sending: true; default: false }
        }
    }

    private(set) var drafts: [Draft] = []
    private(set) var isListening = false
    private(set) var lastError: String?
    /// Kill switch: while paused nothing queued goes out (proposals still arrive).
    var paused = false { didSet { if !paused { pumpQueue() } } }
    let guardrail = SendGuard()

    var pendingCount: Int { drafts.filter { $0.state == .pending }.count }
    var openDrafts: [Draft] { drafts.filter(\.isOpen) }

    @ObservationIgnored private weak var engine: ZaloEngine?
    @ObservationIgnored private var server: UnixSocketServer?
    @ObservationIgnored private var buffers: [Int: Data] = [:]
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private var consecutiveFailures = 0

    static let maxPendingPerConversation = 3
    static let maxPendingTotal = 30
    static let maxTextLength = 2000

    func attach(_ engine: ZaloEngine) {
        self.engine = engine
        if UserDefaults.standard.bool(forKey: Self.enabledKey) { startListening() }
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        on ? startListening() : stopListening()
    }

    // MARK: Socket

    private func startListening() {
        guard server == nil else { return }
        let path = Self.socketPath
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let server = UnixSocketServer(path: path)
        server.onData = { [weak self] id, data in self?.receive(data, from: id) }
        server.onEnd = { [weak self] id in self?.buffers[id] = nil }
        do {
            try server.start()
            self.server = server
            isListening = true
            lastError = nil
            EngineLog.shared.write("assistant: listening on \(path)")
        } catch {
            lastError = error.localizedDescription
            EngineLog.shared.write("assistant: listen failed \(error.localizedDescription)")
        }
    }

    private func stopListening() {
        server?.stop()
        server = nil
        buffers = [:]
        isListening = false
    }

    private func receive(_ data: Data, from connection: Int) {
        var buffer = buffers[connection, default: Data()] + data
        guard buffer.count < 1_000_000 else { buffers[connection] = nil; return }
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer = Data(buffer[buffer.index(after: newline)...])
            guard !line.isEmpty else { continue }
            Task { await self.handle(Data(line), connection: connection) }
        }
        buffers[connection] = buffer
    }

    private func handle(_ line: Data, connection: Int) async {
        guard let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        let id = request["id"] ?? NSNull()
        var reply: [String: Any] = ["id": id]
        do {
            reply["result"] = try await dispatch(request["method"] as? String ?? "", request["params"] as? [String: Any] ?? [:])
        } catch {
            reply["error"] = (error as? AssistantError)?.message ?? error.localizedDescription
        }
        guard var out = try? JSONSerialization.data(withJSONObject: reply) else { return }
        out.append(0x0A)
        server?.write(out, to: connection)
    }

    struct AssistantError: Error { let message: String; init(_ m: String) { message = m } }

    // MARK: Methods

    private func dispatch(_ method: String, _ p: [String: Any]) async throws -> Any {
        guard let engine else { throw AssistantError("Olaz chưa sẵn sàng") }
        guard engine.phase == .ready || method == "status" else { throw AssistantError("Olaz chưa đăng nhập xong") }
        switch method {
        case "status":
            return ["ready": engine.phase == .ready, "account": engine.profile?.displayName ?? "", "paused": paused,
                    "pendingDrafts": pendingCount, "limits": guardrail.describe()]
        case "list_conversations":
            let unreadOnly = p["unreadOnly"] as? Bool ?? false
            let limit = min(p["limit"] as? Int ?? 30, 200)
            let query = (p["query"] as? String ?? "").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            let rows = engine.conversations
                .filter { !unreadOnly || $0.unread > 0 }
                .filter { query.isEmpty || $0.displayName.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(query) }
                .prefix(limit)
            return rows.map { c -> [String: Any] in
                var row: [String: Any] = ["id": c.id, "name": c.id == engine.selfConversationId ? "My Cloud (chính bạn)" : c.displayName, "isSelf": c.id == engine.selfConversationId, "isGroup": c.isGroup, "unread": c.unread, "pinned": c.pinned]
                if let preview = c.preview {
                    row["lastMessage"] = ["text": preview.text, "fromMe": preview.fromMe, "date": preview.date.map(Self.iso) ?? NSNull()]
                }
                if let label = engine.conversationExtras.label(of: c.id) { row["label"] = label.name }
                return row
            }
        case "read_messages":
            let convId = try string(p, "conversationId")
            guard engine.conversations.contains(where: { $0.id == convId }) else { throw AssistantError("Không thấy hội thoại \(convId)") }
            let limit = min(p["limit"] as? Int ?? 30, 100)
            // Messages are only synced for the conversation on screen: open it (the reviewer sees what the AI reads).
            if engine.openConversationId != convId { engine.navigationRequest = convId }
            for _ in 0..<40 where (engine.messages[convId] ?? []).isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
            let list = (engine.messages[convId] ?? []).suffix(limit)
            return list.map { m -> [String: Any] in
                var row: [String: Any] = ["id": m.id, "from": m.isMine ? "me" : m.senderName, "isMine": m.isMine,
                                          "text": m.text, "date": Self.iso(m.date)]
                if let quote = m.quote { row["quoting"] = quote.text }
                return row
            }
        case "propose_reply":
            let draft = try propose(engine, convId: try string(p, "conversationId"), text: try string(p, "text"),
                                    quote: p["quoteMessageId"] as? String, note: p["note"] as? String ?? "")
            return ["draftId": draft.id, "state": "pending",
                    "message": "Đã đưa vào hàng chờ duyệt. Người dùng phải bấm Gửi trong Olaz; không có gì được gửi tự động.",
                    "warnings": draft.warnings]
        case "list_drafts":
            return drafts.suffix(50).map(Self.describe)
        case "get_draft":
            let id = try string(p, "draftId")
            guard let d = drafts.first(where: { $0.id == id }) else { throw AssistantError("Không có nháp \(id)") }
            return Self.describe(d)
        case "approve_draft":
            guard UserDefaults.standard.bool(forKey: Self.chatApprovalKey) else {
                throw AssistantError("Duyệt qua chat đang tắt (Olaz ▸ Cài đặt ▸ Trợ lý AI). Hãy duyệt trong cửa sổ Duyệt nháp (⌘⇧D).")
            }
            let id = try string(p, "draftId")
            guard let i = drafts.firstIndex(where: { $0.id == id }) else { throw AssistantError("Không có nháp \(id)") }
            guard drafts[i].state == .pending else { throw AssistantError("Nháp không còn chờ duyệt") }
            // The approval must be for exactly the text the user read in the preview.
            guard (p["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) == drafts[i].text else {
                throw AssistantError("Nội dung không khớp với nháp hiện tại — hãy gửi lại preview cho người dùng đọc trước khi duyệt")
            }
            guard Date().timeIntervalSince(drafts[i].created) >= Self.minDraftAgeForChatApproval else {
                throw AssistantError("Nháp vừa tạo — người dùng cần đọc preview và nói \"duyệt\" trước")
            }
            approve(id)
            // Wait for the outcome (SendGuard may queue it for a while).
            for _ in 0..<120 {
                if let d = drafts.first(where: { $0.id == id }), !(d.state == .sending), !{ if case .queued = d.state { true } else { false } }() { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            return drafts.first { $0.id == id }.map(Self.describe) ?? [:]
        case "withdraw_draft":
            let id = try string(p, "draftId")
            guard let i = drafts.firstIndex(where: { $0.id == id }), drafts[i].state == .pending else {
                throw AssistantError("Nháp không còn ở trạng thái chờ duyệt")
            }
            drafts[i].state = .discarded
            return ["ok": true]
        default:
            throw AssistantError("Không hỗ trợ: \(method)")
        }
    }

    private func propose(_ engine: ZaloEngine, convId: String, text raw: String, quote: String?, note: String) throws -> Draft {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AssistantError("Nội dung trống") }
        guard text.count <= Self.maxTextLength else { throw AssistantError("Dài quá \(Self.maxTextLength) ký tự, hãy rút gọn") }
        guard let conv = engine.conversations.first(where: { $0.id == convId }) else { throw AssistantError("Không thấy hội thoại \(convId)") }
        guard openDrafts.count < Self.maxPendingTotal else { throw AssistantError("Đã có \(Self.maxPendingTotal) nháp chờ duyệt — đợi người dùng xử lý") }
        guard openDrafts.filter({ $0.conversationId == convId }).count < Self.maxPendingPerConversation else {
            throw AssistantError("Hội thoại này đã có \(Self.maxPendingPerConversation) nháp chờ duyệt")
        }
        // Reply only: no cold outreach to people who have not written recently.
        let incoming = (engine.messages[convId] ?? []).last { !$0.isMine }
        let lastIncomingDate = incoming?.date ?? ((conv.preview?.fromMe == false) ? conv.preview?.date : nil)
        // My Cloud (the account's own chat) is exempt: it is how the user tests the assistant safely.
        let isSelf = convId == engine.selfConversationId
        guard isSelf || (lastIncomingDate.map { $0 > Date().addingTimeInterval(-SendGuard.replyWindow) } ?? false) else {
            throw AssistantError("Chỉ được trả lời khách đã nhắn trong 7 ngày gần đây (chống spam). Hãy gọi read_messages trước nếu khách vừa nhắn.")
        }
        var warnings = guardrail.warnings(for: text, isGroup: conv.isGroup)
        if let duplicate = guardrail.duplicateCount(text), duplicate > 0 {
            warnings.append("Nội dung giống hệt đã gửi cho \(duplicate) hội thoại trong 1 giờ qua")
        }
        let draft = Draft(id: UUID().uuidString.prefix(8).lowercased(), conversationId: convId, conversationName: conv.displayName,
                          text: text, quoteMessageId: quote, note: note,
                          replyingTo: incoming?.text ?? conv.preview?.text ?? "", created: Date(), warnings: warnings)
        drafts.append(draft)
        if drafts.count > 300 { drafts.removeFirst(drafts.count - 300) }
        Self.notify(draft)
        return draft
    }

    // MARK: Reviewer actions (UI)

    func edit(_ id: String, text: String) {
        guard let i = drafts.firstIndex(where: { $0.id == id }), drafts[i].state == .pending else { return }
        drafts[i].text = text
        drafts[i].warnings = guardrail.warnings(for: text, isGroup: engine?.conversations.first { $0.id == drafts[i].conversationId }?.isGroup ?? false)
    }

    func discard(_ id: String) {
        guard let i = drafts.firstIndex(where: { $0.id == id }), drafts[i].isOpen, drafts[i].state != .sending else { return }
        drafts[i].state = .discarded
    }

    /// The only way a draft is sent: the user approved it. `SendGuard` decides when.
    func approve(_ id: String) {
        guard let i = drafts.firstIndex(where: { $0.id == id }), drafts[i].state == .pending else { return }
        let text = drafts[i].text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let block = guardrail.blockReason(text: text, conversationId: drafts[i].conversationId) {
            drafts[i].state = .failed(block)
            return
        }
        drafts[i].state = .queued(notBefore: guardrail.nextSlot())
        pumpQueue()
    }

    func retry(_ id: String) {
        guard let i = drafts.firstIndex(where: { $0.id == id }), case .failed = drafts[i].state else { return }
        drafts[i].state = .pending
    }

    func clearFinished() { drafts.removeAll { !$0.isOpen } }

    private func pumpQueue() {
        guard pump == nil else { return }
        pump = Task { [weak self] in
            while let self, !Task.isCancelled {
                guard !self.paused, let i = self.drafts.firstIndex(where: { if case .queued = $0.state { true } else { false } }) else { break }
                guard case .queued(let notBefore) = self.drafts[i].state else { break }
                let wait = max(notBefore.timeIntervalSinceNow, self.guardrail.nextSlot().timeIntervalSinceNow)
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)); continue }
                let draft = self.drafts[i]
                if let block = self.guardrail.blockReason(text: draft.text, conversationId: draft.conversationId) {
                    self.update(draft.id, .failed(block)); continue
                }
                self.update(draft.id, .sending)
                let ok = await self.engine?.sendText(draft.text, to: draft.conversationId, quoting: draft.quoteMessageId) ?? false
                if ok {
                    self.guardrail.record(text: draft.text, conversationId: draft.conversationId)
                    self.update(draft.id, .sent(Date()))
                    self.consecutiveFailures = 0
                } else {
                    self.update(draft.id, .failed("Zalo không nhận tin (thử lại sau)"))
                    self.consecutiveFailures += 1
                    // Two failures in a row: something is off (rate limit, session) — stop and let the user look.
                    if self.consecutiveFailures >= 2 { self.paused = true; self.lastError = "Tạm dừng: gửi lỗi 2 lần liên tiếp" }
                }
            }
            self?.pump = nil
        }
    }

    private func update(_ id: String, _ state: Draft.State) {
        if let i = drafts.firstIndex(where: { $0.id == id }) { drafts[i].state = state }
    }

    // MARK: Helpers

    private func string(_ p: [String: Any], _ key: String) throws -> String {
        guard let v = p[key] as? String, !v.isEmpty else { throw AssistantError("Thiếu tham số \(key)") }
        return v
    }

    private static func notify(_ draft: Draft) {
        let content = UNMutableNotificationContent()
        content.title = "Nháp trả lời chờ duyệt"
        content.body = "\(draft.conversationName): \(draft.text.prefix(120))"
        content.threadIdentifier = "olaz.assistant"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "olaz.assistant.\(draft.id)", content: content, trigger: nil))
    }

    private static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    private static func describe(_ d: Draft) -> [String: Any] {
        let state: String
        var detail: Any = NSNull()
        switch d.state {
        case .pending: state = "pending"
        case .queued(let t): state = "queued"; detail = iso(t)
        case .sending: state = "sending"
        case .sent(let t): state = "sent"; detail = iso(t)
        case .discarded: state = "discarded"
        case .failed(let why): state = "failed"; detail = why
        }
        return ["draftId": d.id, "conversationId": d.conversationId, "conversation": d.conversationName, "text": d.text,
                "state": state, "detail": detail, "created": iso(d.created)]
    }
}

/// Anti-ban pacing for everything the assistant sends. Limits are deliberately below what a busy human manages by hand.
/// The send log survives relaunches (UserDefaults), so quitting does not reset the daily cap.
@MainActor
final class SendGuard {
    static let minGap: TimeInterval = 12          // seconds between two sends, plus 0–8 s jitter
    static let maxJitter: TimeInterval = 8
    static let burstWindow: TimeInterval = 600     // 10 minutes
    static let maxPerBurst = 15
    static let maxPerDay = 150                     // rolling 24 h
    static let maxPerConversationHour = 6
    static let maxSameTextConversations = 3        // identical text to >3 chats in an hour looks like a broadcast
    static let replyWindow: TimeInterval = 7 * 86_400

    private struct Entry: Codable { var date: Date; var conv: String; var hash: Int }
    private static let storeKey = "olaz.assistant.sendLog"
    private var log: [Entry]
    private var jitter: TimeInterval = 0

    init() {
        log = (UserDefaults.standard.data(forKey: Self.storeKey)).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
        prune()
    }

    func describe() -> [String: Any] {
        prune()
        let now = Date()
        return ["minGapSeconds": Self.minGap, "per10Min": "\(log.filter { now.timeIntervalSince($0.date) < Self.burstWindow }.count)/\(Self.maxPerBurst)",
                "per24h": "\(log.count)/\(Self.maxPerDay)", "perConversationHour": Self.maxPerConversationHour,
                "replyOnlyWithinDays": 7, "autoSend": false]
    }

    /// When the next send may go out (gap + jitter, burst window).
    func nextSlot() -> Date {
        prune()
        var slot = Date()
        if let last = log.last?.date { slot = max(slot, last.addingTimeInterval(Self.minGap + jitter)) }
        let recent = log.filter { Date().timeIntervalSince($0.date) < Self.burstWindow }
        if recent.count >= Self.maxPerBurst, let oldest = recent.first { slot = max(slot, oldest.date.addingTimeInterval(Self.burstWindow + 1)) }
        return slot
    }

    /// Hard stops (the draft is refused, not delayed).
    func blockReason(text: String, conversationId: String) -> String? {
        prune()
        let now = Date()
        if log.count >= Self.maxPerDay { return "Đã đủ \(Self.maxPerDay) tin/24 giờ — để mai gửi tiếp" }
        if log.filter({ $0.conv == conversationId && now.timeIntervalSince($0.date) < 3600 }).count >= Self.maxPerConversationHour {
            return "Hội thoại này đã nhận \(Self.maxPerConversationHour) tin trong 1 giờ"
        }
        if let same = duplicateCount(text), same >= Self.maxSameTextConversations,
           !log.contains(where: { $0.conv == conversationId && $0.hash == Self.hash(text) }) {
            return "Cùng một nội dung đã gửi cho \(same) hội thoại trong 1 giờ — hãy sửa cho riêng khách này"
        }
        return nil
    }

    func duplicateCount(_ text: String) -> Int? {
        let h = Self.hash(text), now = Date()
        return Set(log.filter { $0.hash == h && now.timeIntervalSince($0.date) < 3600 }.map(\.conv)).count
    }

    func warnings(for text: String, isGroup: Bool) -> [String] {
        var out: [String] = []
        if text.range(of: #"https?://|www\."#, options: .regularExpression) != nil { out.append("Có đường link — Zalo soi kỹ tin có link") }
        if text.range(of: #"\d{9,}"#, options: .regularExpression) != nil { out.append("Có dãy số dài (SĐT/STK?) — kiểm tra lại") }
        if isGroup { out.append("Đây là nhóm — mọi thành viên đều thấy") }
        return out
    }

    func record(text: String, conversationId: String) {
        log.append(Entry(date: Date(), conv: conversationId, hash: Self.hash(text)))
        jitter = Double.random(in: 0...Self.maxJitter)
        prune()
        if let data = try? JSONEncoder().encode(log) { UserDefaults.standard.set(data, forKey: Self.storeKey) }
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-86_400)
        log.removeAll { $0.date < cutoff }
    }

    private static func hash(_ text: String) -> Int {
        // Stable across launches (Hasher is seeded per process).
        let normalized = text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
        return normalized.unicodeScalars.reduce(5381) { ($0 &<< 5) &+ $0 &+ Int($1.value) }
    }
}
