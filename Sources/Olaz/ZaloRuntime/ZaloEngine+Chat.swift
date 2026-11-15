import Foundation
import AppKit

// Chat + phone→PC transfer, bridged to `HostScripts/chat-adapter.js` (`window.__zaloChat`).
// Contract: ChatModels.swift. All actions run through the official client's own services.
extension ZaloEngine {
    func openConversation(_ id: String) {
        if openConversationId != id { dropMessagePrompts() }
        openConversationId = id
        callChat("open", id)
        callChat("watchPins", id, object: "__zaloMsgActions")
    }

    func closeConversation() {
        guard let id = openConversationId else { return }
        openConversationId = nil
        dropMessagePrompts()
        callChat("close", id)
        callChat("watchPins", nil, object: "__zaloMsgActions")
    }

    func loadOlderMessages(_ id: String) { callChat("loadMore", id) }

    /// `mentions` are offsets (UTF-16) into `text` as typed; they are re-based when the text is trimmed
    /// and dropped when they no longer point at their "@Name".
    /// Returns false when the official client could not take the message (nothing was sent).
    @discardableResult
    func sendText(_ text: String, to id: String, quoting messageId: String? = nil, mentions: [Mention] = []) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let leading = text.utf16.prefix { unit in
            guard let scalar = Unicode.Scalar(unit) else { return false }
            return CharacterSet.whitespacesAndNewlines.contains(scalar)
        }.count
        let body = trimmed as NSString
        let wire: [[String: Any]] = mentions.compactMap { mention in
            let pos = mention.pos - leading
            guard pos >= 0, mention.len > 1, pos + mention.len <= body.length,
                  body.character(at: pos) == 0x40 else { return nil }
            return ["pos": pos, "len": mention.len, "uid": mention.uid, "type": mention.isAll ? 1 : 0]
        }.sorted { ($0["pos"] as? Int ?? 0) < ($1["pos"] as? Int ?? 0) }
        let args = [id, trimmed, messageId ?? NSNull(), wire] as [Any]
        guard let data = try? JSONSerialization.data(withJSONObject: args, options: [.fragmentsAllowed]),
              let json = String(data: data, encoding: .utf8) else { return false }
        let script = "const c = window.__zaloChat; if (!c || !c.sendText) return 'missing'; return await c.sendText(...\(json));"
        // A hung official send must not spin forever. No answer in time means "may still be sent": reported as pending and
        // treated as taken (true), so the text is not handed back as failed and re-sent into a duplicate.
        guard let answer = await raceTimeout(Self.sendTextTimeout, { [self] in JSBox(value: await host?.evaluate(script)) }) else {
            EngineLog.shared.write("chat sendText → no answer in \(Int(Self.sendTextTimeout)) s (pending)")
            CardActionCenter.shared.show(CardActionOutcome.noAnswerText, in: id)
            return true
        }
        let result = answer.value as? String
        if result != "sent" { EngineLog.shared.write("chat sendText → \(result ?? "nil")") }
        return result == "sent"
    }

    /// Swift-side cap on one official text send (the page's own network retries normally answer well before).
    static let sendTextTimeout: Double = 60

    /// Logout: messages, history paging and typing banners of the previous account.
    func resetChatState() {
        messages = [:]
        hasMoreHistory = [:]
        historyTicks = [:]
        typing = [:]
        ChatTypingClock.tasks.values.forEach { $0.cancel() }
        ChatTypingClock.tasks = [:]
    }

    /// Group members matching `query` (what follows the "@"), from the official suggestion engine:
    /// same filtering/ordering as Zalo PC, "Tất cả" first when the official rules allow mention-all.
    func mentionCandidates(in id: String, query: String, excluding mentioned: [String]) async -> [MentionCandidate] {
        let args = [id, query, mentioned] as [Any]
        guard let data = try? JSONSerialization.data(withJSONObject: args, options: [.fragmentsAllowed]),
              let json = String(data: data, encoding: .utf8) else { return [] }
        let script = "const c = window.__zaloChat; if (!c || !c.mentionCandidates) return []; return await c.mentionCandidates(...\(json));"
        guard let rows = await host?.evaluate(script) as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let uid = row["id"] as? String, !uid.isEmpty else { return nil }
            let isAll = row["isAll"] as? Bool ?? false
            let name = (row["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard isAll || !name.isEmpty else { return nil }
            return MentionCandidate(id: uid, name: isAll ? "All" : name,
                                    avatar: (row["avatar"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) },
                                    isAll: isAll)
        }
    }

    /// Who reacted to a message, from the official reaction cache + profile service (read-only).
    /// nil when the client could not answer (not ready, error); an empty detail when nobody reacted.
    func reactors(for messageId: String, in conversationId: String) async -> ReactionDetail? {
        let args = [conversationId, messageId] as [Any]
        guard let data = try? JSONSerialization.data(withJSONObject: args, options: [.fragmentsAllowed]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        let script = "const c = window.__zaloChat; if (!c || !c.reactors) return null; return await c.reactors(...\(json));"
        return ReactionDetail(json: await host?.evaluate(script))
    }

    /// The PNG of an official reaction icon (`pc-dist/emoji/…`, read from the install's asar), cached by path.
    func reactionImage(_ path: String) -> NSImage? {
        guard !path.isEmpty else { return nil }
        if let cached = Self.reactionImages.object(forKey: path as NSString) { return cached }
        guard let data = host?.install.asar.read("pc-dist/" + path), let image = NSImage(data: data) else { return nil }
        Self.reactionImages.setObject(image, forKey: path as NSString)
        return image
    }
    private static let reactionImages = NSCache<NSString, NSImage>()

    func markRead(_ id: String) { callChat("markRead", id) }

    func react(_ emoji: String, to messageId: String, in id: String) { callChat("react", id, messageId, emoji) }

    func handleChat(state: [String: Any]) {
        if let chat = state["chat"] as? [String: Any], let convId = chat["convId"] as? String {
            mergeChat(chat, convId: convId)
        }
        if let typingState = state["typing"] as? [String: Any], let convId = typingState["convId"] as? String {
            showTyping(typingState["name"] as? String ?? "", in: convId)
        }
    }

    /// `reset` replaces the list; otherwise changed messages merge by id (a pending message
    /// keeps its id when it is confirmed) and `removed` ids drop out. Kept oldest first.
    private func mergeChat(_ chat: [String: Any], convId: String) {
        let incoming = (chat["messages"] as? [[String: Any]] ?? []).compactMap { Self.chatMessage($0, fallbackConversation: convId) }
        let removed = Set(chat["removed"] as? [String] ?? [])
        let reset = chat["reset"] as? Bool ?? false
        var list = reset ? [] : (messages[convId] ?? [])
        if !removed.isEmpty { list.removeAll { removed.contains($0.id) } }
        var index = list.enumerated().reduce(into: [String: Int]()) { $0[$1.element.id] = $1.offset }
        var needsSort = reset
        for message in incoming {
            if let at = index[message.id] {
                if list[at].date != message.date { needsSort = true }
                list[at] = message
            } else {
                if let last = list.last, message.date < last.date { needsSort = true }
                index[message.id] = list.count
                list.append(message)
            }
        }
        if needsSort {
            // Stable: equal timestamps keep the order the official client gave them.
            list = list.enumerated().sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }.map(\.element)
        }
        EngineLog.shared.write("chat merge conv=\(convId.prefix(4))… reset=\(reset) in=\(incoming.count) removed=\(removed.count) total=\(list.count) hasMore=\(chat["hasMore"] ?? "-")")
        if messages[convId] != list { messages[convId] = list }
        notePollMessages(incoming)
        if let hasMore = chat["hasMore"] as? Bool, hasMoreHistory[convId] != hasMore { hasMoreHistory[convId] = hasMore }
        if chat["grew"] as? Bool == true { historyTicks[convId, default: 0] += 1 }
        if typing[convId] != nil, let newest = incoming.last, !newest.isMine, newest.date > Date().addingTimeInterval(-5) {
            clearTyping(convId)
        }
    }

    private func showTyping(_ name: String, in convId: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { clearTyping(convId); return }
        typing[convId] = trimmed
        ChatTypingClock.tasks[convId]?.cancel()
        ChatTypingClock.tasks[convId] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.clearTyping(convId)
        }
    }

    private func clearTyping(_ convId: String) {
        ChatTypingClock.tasks[convId]?.cancel()
        ChatTypingClock.tasks[convId] = nil
        typing[convId] = nil
    }

    private static func chatMessage(_ json: [String: Any], fallbackConversation: String) -> ChatMessage? {
        ChatMessage(json: json, fallbackConversation: fallbackConversation)
    }

    /// `window.__zaloChat[method](...args)`; arguments are JSON-encoded.
    func callChat(_ method: String, _ args: Any?..., object: String = "__zaloChat") {
        let values = args.map { $0 ?? NSNull() }
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.fragmentsAllowed]),
              let json = String(data: data, encoding: .utf8) else { return }
        let script = "return (() => { const c = window.\(object); if (!c || !c.\(method)) return 'missing'; c.\(method)(...\(json)); return 'ok'; })()"
        Task { [weak self] in
            let result = await self?.host?.evaluate(script)
            if (result as? String) != "ok" { EngineLog.shared.write("chat \(method) → \(result ?? "nil")") }
        }
    }
}

/// Auto-clear timers for "is typing" banners (extensions cannot hold stored properties).
@MainActor
private enum ChatTypingClock {
    static var tasks: [String: Task<Void, Never>] = [:]
}
