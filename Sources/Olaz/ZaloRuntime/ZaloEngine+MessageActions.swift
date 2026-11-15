import AppKit

// Message context-menu actions — Chia sẻ, Copy, Thu hồi, Xóa chỉ ở phía tôi, Ghim tin nhắn, Đánh dấu tin nhắn — bridged to
// `HostScripts/message-actions-adapter.js` (`window.__zaloMsgActions`), which runs the official services and says which items each message
// gets (`ChatMessage.menu`). Copy is native (pasteboard). The pinned list of the open conversation arrives as `pins` states.

/// Result of a message action (message-actions-adapter.js `{status, text, …}`).
enum MessageActionOutcome: Equatable, Sendable {
    /// `text`: the official confirmation to show, if the official client shows one.
    case done(text: String?)
    /// The official client would ask first (delete confirm, "Cập nhật danh sách ghim").
    case confirm(title: String, message: String, ok: String, cancel: String, ref: String?)
    case failed(String)
    /// Started but not answered in time: it may still happen, so the wording never invites a retry.
    case pending(String)

    init(json: Any?, failure: String) {
        guard let root = json as? [String: Any], let status = root["status"] as? String else {
            self = .failed(failure)
            return
        }
        let text = (root["text"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        switch status {
        case "done": self = .done(text: text)
        case "confirm":
            self = .confirm(title: root["title"] as? String ?? "", message: root["message"] as? String ?? "",
                            ok: root["ok"] as? String ?? "OK", cancel: root["cancel"] as? String ?? "Hủy",
                            ref: (root["ref"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        case "pending": self = .pending(text ?? CardActionOutcome.defaultPending)
        case "not-ready": self = .failed(text ?? "Zalo chưa sẵn sàng, hãy thử lại sau giây lát.")
        case "not-open": self = .failed(text ?? "Cuộc trò chuyện chưa sẵn sàng, hãy thử lại sau giây lát.")
        default: self = .failed(text ?? failure)
        }
    }

    var logName: String {
        switch self {
        case .done: "done"
        case .confirm: "confirm"
        case .failed: "failed"
        case .pending: "pending"
        }
    }
}

/// A confirmation a message action asks for, answered natively.
struct MessageActionConfirm: Identifiable, Equatable {
    enum Action: Equatable {
        case deleteForMe(ChatMessage)
        /// Replace the pin `ref` (the oldest) to pin this message.
        case pin(ChatMessage, replacing: String)
        case unpin(ref: String)
    }
    let id = UUID()
    var conversationId: String
    var action: Action
    var title: String
    var message: String
    var ok: String
    var cancel: String = "Hủy"
    var destructive = false
}

/// "N tin nhắn đã xóa · Khôi phục": the official undo window of a delete-for-me.
struct DeleteUndo: Identifiable, Equatable {
    let id: String
    var conversationId: String
    var count: Int
    var deadline: Date
}

/// "Chia sẻ": the message waiting for the conversations to forward it to.
struct ForwardRequest: Identifiable, Equatable {
    let id = UUID()
    var conversationId: String
    var message: ChatMessage
}

/// One pin of a conversation (official group board topic / 1:1 pin topic), newest first.
struct PinnedItem: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case message, note, link, poll, reminder }
    var ref: String
    var kind: Kind
    var title: String
    var sender: String
    var thumbnail: URL?
    var msgId: String
    var cliMsgId: String
    var id: String { ref }

    /// The official board's label of the pin's type (STR_MSG_PINNED…).
    var label: String {
        switch kind {
        case .message: "Tin nhắn"
        case .note, .link: "Ghi chú"
        case .poll: "Bình chọn"
        case .reminder: "Nhắc hẹn"
        }
    }

    /// The loaded chat message this pin points at (own messages are keyed by client id, others by server id).
    func message(in list: [ChatMessage]) -> ChatMessage? {
        guard kind == .message else { return nil }
        return list.last { (!msgId.isEmpty && $0.id == msgId) || (!cliMsgId.isEmpty && $0.id == cliMsgId) }
    }
}

struct PinnedList: Equatable, Sendable {
    /// The pins could be read (groups with the topic board on, friends with 1:1 pins on).
    var ready = false
    /// I may pin / unpin here (group allowance; friends always).
    var canPin = false
    var items: [PinnedItem] = []

    init(json: [String: Any]) {
        ready = json["ready"] as? Bool ?? false
        canPin = json["canPin"] as? Bool ?? false
        items = (json["items"] as? [[String: Any]] ?? []).compactMap { row in
            guard let ref = row["ref"] as? String, !ref.isEmpty else { return nil }
            return PinnedItem(ref: ref, kind: PinnedItem.Kind(rawValue: row["kind"] as? String ?? "") ?? .note,
                              title: row["title"] as? String ?? "", sender: row["sender"] as? String ?? "",
                              thumbnail: (row["thumb"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) },
                              msgId: row["msgId"] as? String ?? "", cliMsgId: row["cliMsgId"] as? String ?? "")
        }
    }
}

extension ChatMessage {
    /// What "Copy tin nhắn" puts on the pasteboard: the text of a text / link message, nil for kinds the official menu copies otherwise.
    var copyableText: String? {
        switch kind {
        case .text: return text.isEmpty ? nil : text
        case .link(let title, let url, _, _, _):
            if !text.isEmpty, !text.hasPrefix("[Link]") { return text }
            return url?.absoluteString ?? (title.isEmpty ? nil : title)
        default: return nil
        }
    }

    /// The caption of a photo / video ("Copy chú thích"); nil when it has none (non-text kinds carry "[Hình ảnh]"-style fallbacks).
    var caption: String? {
        switch kind {
        case .photo, .video: return !text.isEmpty && !text.hasPrefix("[") ? text : nil
        default: return nil
        }
    }
}

extension ZaloEngine {
    // MARK: Copy (native)

    /// Copies are refused under "Chặn chia sẻ", read fresh: it may have been turned on after the message's menu was built.
    func copyText(_ text: String, in conversationId: String) {
        Task {
            guard await copyAllowed(in: conversationId) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            CardActionCenter.shared.show("Đã sao chép", in: conversationId)
        }
    }

    /// "Copy hình ảnh": the photo as the official loader has it (local copy first, then the CDN), on the pasteboard as an image.
    func copyPhoto(_ message: ChatMessage) {
        guard case .photo(let url, _, _) = message.kind else { return }
        let conversation = message.conversationId
        Task {
            guard await copyAllowed(in: conversation) else { return }
            var data: Data?
            if case .file(let file) = await resolveMedia(conversationId: conversation, messageId: message.id, kind: .photo),
               MediaLoader.isAllowedLocalFile(file) {
                data = try? Data(contentsOf: file)
            }
            if data == nil, !message.isE2EE, let url, url.scheme == "https" {
                data = try? await MediaLoader.shared.data(for: url)
            }
            guard let data, let image = NSImage(data: data) else {
                CardActionCenter.shared.show("Không sao chép được hình ảnh. Hãy thử lại.", in: conversation)
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
            CardActionCenter.shared.show("Đã sao chép", in: conversation)
        }
    }

    private func copyAllowed(in conversationId: String) async -> Bool {
        let answer = await raceTimeout(5) { [self] in JSBox(value: await evaluateActions("isProtected", [conversationId])) }
        // Fails closed: only an explicit "not protected" answer allows the copy (a timeout, reload or unknown shape must not
        // bypass "Chặn chia sẻ").
        switch answer?.value as? Bool {
        case false?:
            return true
        case true?:
            CardActionCenter.shared.show("Trò chuyện này đã bật Chặn chia sẻ", in: conversationId)
        case nil:
            EngineLog.shared.write("message isProtected → no answer, copy refused")
            CardActionCenter.shared.show("Chưa kiểm tra được quyền sao chép. Hãy thử lại sau.", in: conversationId)
        }
        return false
    }

    // MARK: Chia sẻ

    func requestForward(_ message: ChatMessage) {
        guard message.menu.forward == .available else {
            if message.menu.forward == .blocked { CardActionCenter.shared.show("Trò chuyện này đã bật Chặn chia sẻ", in: message.conversationId) }
            return
        }
        forwardRequest = ForwardRequest(conversationId: message.conversationId, message: message)
    }

    /// Forwards to every conversation in `targets` through the official forward module; `.done` once at least one got it.
    func forward(_ message: ChatMessage, to targets: [String]) async -> MessageActionOutcome {
        await callActions("forward", [message.conversationId, message.id, targets], timeout: 75, failure: "Có lỗi khi chia sẻ tin nhắn")
    }

    // MARK: Thu hồi

    func recall(_ message: ChatMessage) {
        runAction(message, "recall", [message.conversationId, message.id], failure: "Thu hồi tin nhắn không thành công")
    }

    // MARK: Xóa chỉ ở phía tôi

    func deleteForMe(_ message: ChatMessage, confirmed: Bool = false) {
        let conversation = message.conversationId
        let key = "\(conversation)|\(message.id)|delete"
        guard messageActionsBusy.insert(key).inserted else { return }
        Task {
            defer { messageActionsBusy.remove(key) }
            let answer = await raceTimeout(45) { [self] in JSBox(value: await evaluateActions("deleteForMe", [conversation, message.id, confirmed])) }
            guard let answer else { CardActionCenter.shared.show(CardActionOutcome.noAnswerText, in: conversation); return }
            let outcome = MessageActionOutcome(json: answer.value, failure: "Không thể xóa tin nhắn")
            EngineLog.shared.write("message deleteForMe → \(outcome.logName)")
            switch outcome {
            case .done:
                guard let undo = (answer.value as? [String: Any])?["undo"] as? [String: Any], let id = undo["id"] as? String else { return }
                let ms = (undo["ms"] as? NSNumber)?.doubleValue ?? 0
                showDeleteUndo(DeleteUndo(id: id, conversationId: conversation, count: max(1, (undo["count"] as? NSNumber)?.intValue ?? 1),
                                          deadline: Date().addingTimeInterval(max(1, ms / 1000))))
            case .confirm(let title, let text, let ok, let cancel, _):
                ask(MessageActionConfirm(conversationId: conversation, action: .deleteForMe(message), title: title,
                                         message: text, ok: ok, cancel: cancel, destructive: true))
            case .failed(let text), .pending(let text):
                CardActionCenter.shared.show(text, in: conversation)
            }
        }
    }

    private func showDeleteUndo(_ undo: DeleteUndo) {
        // A newer delete takes the bar: the earlier one just runs out, as its official snackbar would.
        if let previous = deleteUndo { callChat("dropDelete", previous.id, object: "__zaloMsgActions") }
        deleteUndo = undo
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0.5, undo.deadline.timeIntervalSinceNow)))
            guard let self, self.deleteUndo == undo else { return }
            self.deleteUndo = nil
            self.callChat("dropDelete", undo.id, object: "__zaloMsgActions")
        }
    }

    /// "Khôi phục": the deleted message comes back (official undoDeleteMsgs).
    func undoDelete() {
        guard let undo = deleteUndo else { return }
        deleteUndo = nil
        Task {
            let outcome = await callActions("undoDelete", [undo.id], timeout: 30, failure: "Không thể khôi phục")
            switch outcome {
            case .done: CardActionCenter.shared.show("Khôi phục thành công", in: undo.conversationId)
            case .failed(let text), .pending(let text): CardActionCenter.shared.show(text, in: undo.conversationId)
            case .confirm: break
            }
        }
    }

    /// The bar's close button: the official client deletes for good at once.
    func dismissDeleteUndo() {
        guard let undo = deleteUndo else { return }
        deleteUndo = nil
        callChat("commitDelete", undo.id, object: "__zaloMsgActions")
    }

    // MARK: Đánh dấu tin nhắn

    func setStarred(_ message: ChatMessage, _ on: Bool) {
        if on, message.menu.star == .blocked {
            CardActionCenter.shared.show("Trò chuyện này đã bật Chặn chia sẻ", in: message.conversationId)
            return
        }
        runAction(message, on ? "star" : "unstar", [message.conversationId, message.id, on], method: "star", failure: "Có lỗi xảy ra")
    }

    // MARK: Ghim tin nhắn

    func pin(_ message: ChatMessage, replacing ref: String? = nil) {
        let conversation = message.conversationId
        let key = "\(conversation)|\(message.id)|pin"
        guard messageActionsBusy.insert(key).inserted else { return }
        Task {
            defer { messageActionsBusy.remove(key) }
            let outcome = await callActions("pin", [conversation, message.id, ref ?? NSNull()], timeout: 60, failure: "Ghim tin nhắn không thành công.")
            switch outcome {
            case .done: break
            case .confirm(let title, let text, let ok, let cancel, let replacing):
                guard let replacing else { CardActionCenter.shared.show("Ghim tin nhắn không thành công.", in: conversation); return }
                ask(MessageActionConfirm(conversationId: conversation, action: .pin(message, replacing: replacing),
                                         title: title, message: text, ok: ok, cancel: cancel))
            case .failed(let text), .pending(let text): CardActionCenter.shared.show(text, in: conversation)
            }
        }
    }

    /// Asks the official "Bạn muốn bỏ ghim tin nhắn?" first.
    func requestUnpin(_ item: PinnedItem, in conversationId: String) {
        ask(MessageActionConfirm(conversationId: conversationId, action: .unpin(ref: item.ref),
                                 title: item.kind == .message ? "Bỏ ghim tin nhắn" : "Bỏ ghim",
                                 message: item.kind == .message ? "Bạn muốn bỏ ghim tin nhắn?" : "Bạn muốn bỏ ghim nội dung này?",
                                 ok: "Bỏ ghim", destructive: true))
    }

    /// A confirm belongs to the conversation on screen and comes one at a time: a late answer for a conversation left meanwhile, or one
    /// arriving while another is asked, is dropped (the action simply did not run; the user can start it again).
    private func ask(_ confirm: MessageActionConfirm) {
        guard openConversationId == confirm.conversationId, messageConfirm == nil else {
            EngineLog.shared.write("message confirm dropped (conversation left or another confirm open)")
            return
        }
        messageConfirm = confirm
    }

    /// Unpins the message's own pin (the context menu's "Bỏ ghim tin nhắn").
    func requestUnpin(_ message: ChatMessage) {
        guard let item = pins[message.conversationId]?.items.first(where: { $0.message(in: [message]) != nil }) else { return }
        requestUnpin(item, in: message.conversationId)
    }

    private func unpin(_ ref: String, in conversationId: String) {
        let key = "\(conversationId)|\(ref)|unpin"
        guard messageActionsBusy.insert(key).inserted else { return }
        Task {
            defer { messageActionsBusy.remove(key) }
            let outcome = await callActions("unpin", [conversationId, ref], timeout: 40, failure: "Yêu cầu thực hiện không thành công")
            switch outcome {
            case .failed(let text), .pending(let text): CardActionCenter.shared.show(text, in: conversationId)
            case .done, .confirm: break
            }
        }
    }

    func answerMessageConfirm(_ confirm: MessageActionConfirm, ok: Bool) {
        guard messageConfirm?.id == confirm.id else { return }
        messageConfirm = nil
        guard ok else { return }
        switch confirm.action {
        case .deleteForMe(let message): deleteForMe(message, confirmed: true)
        case .pin(let message, let replacing): pin(message, replacing: replacing)
        case .unpin(let ref): unpin(ref, in: confirm.conversationId)
        }
    }

    // MARK: Pins of the open conversation

    func handlePins(state: [String: Any]) {
        guard let json = state["pins"] as? [String: Any], let conversation = json["convId"] as? String, !conversation.isEmpty else { return }
        let list = PinnedList(json: json)
        if pins[conversation] != list { pins[conversation] = list }
    }

    /// The page reloaded: watch the open conversation's pins again.
    func rewatchPins() {
        guard let id = openConversationId else { return }
        callChat("watchPins", id, object: "__zaloMsgActions")
    }

    /// Another conversation opens: a picker or confirm of the previous one must not answer for it.
    func dropMessagePrompts() {
        forwardRequest = nil
        messageConfirm = nil
    }

    /// Logout: nothing of the previous account may be asked, undone or shown in the next.
    func resetMessageActions() {
        forwardRequest = nil
        messageConfirm = nil
        deleteUndo = nil
        pins = [:]
        messageActionsBusy = []
    }

    // MARK: Calls into message-actions-adapter.js

    /// One action at a time per message and kind; failures and pending answers become the conversation's toast, an official info
    /// text (e.g. "Đã bỏ đánh dấu tin nhắn") too.
    private func runAction(_ message: ChatMessage, _ name: String, _ args: [Any], method: String? = nil, failure: String) {
        let conversation = message.conversationId
        let key = "\(conversation)|\(message.id)|\(name)"
        guard messageActionsBusy.insert(key).inserted else { return }
        Task {
            defer { messageActionsBusy.remove(key) }
            let outcome = await callActions(method ?? name, args, timeout: 45, failure: failure)
            switch outcome {
            case .done(let text): if let text { CardActionCenter.shared.show(text, in: conversation) }
            case .failed(let text), .pending(let text): CardActionCenter.shared.show(text, in: conversation)
            case .confirm: break
            }
        }
    }

    private func callActions(_ method: String, _ args: [Any], timeout: Double, failure: String) async -> MessageActionOutcome {
        let answer = await raceTimeout(timeout) { [self] in JSBox(value: await evaluateActions(method, args)) }
        guard let answer else { return .pending(CardActionOutcome.noAnswerText) }
        let outcome = MessageActionOutcome(json: answer.value, failure: failure)
        EngineLog.shared.write("message \(method) → \(outcome.logName)")
        return outcome
    }

    private func evaluateActions(_ method: String, _ args: [Any]) async -> Any? {
        guard let data = try? JSONSerialization.data(withJSONObject: args, options: [.fragmentsAllowed]),
              let json = String(data: data, encoding: .utf8), let host else { return nil }
        return await host.evaluate("const c = window.__zaloMsgActions; if (!c || !c.\(method)) return {status: 'not-ready'}; return await c.\(method)(...\(json));")
    }
}
