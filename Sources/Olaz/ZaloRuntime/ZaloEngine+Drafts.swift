import Foundation

// Per-conversation composer drafts: the text typed (with its mentions) survives switching conversations. In memory only,
// cleared on logout (`resetAccountState`). Unsent text the official client refused is a separate store (`failedDrafts`).

/// Unsent composer text by conversation id.
struct ConversationDraftStore: Equatable {
    struct Entry: Equatable {
        var text: String
        var mentions: [Mention]
    }

    private(set) var entries: [String: Entry] = [:]

    func entry(for convId: String) -> Entry? { entries[convId] }

    /// Empty (or whitespace-only) text removes the draft.
    mutating func save(_ text: String, mentions: [Mention], for convId: String) {
        guard !convId.isEmpty else { return }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            entries[convId] = nil
        } else {
            entries[convId] = Entry(text: text, mentions: mentions)
        }
    }
}

extension ZaloEngine {
    /// The unsent text (and its mentions, UTF-16 offsets into that text) last saved for `convId`; nil when none.
    func draft(for convId: String) -> (text: String, mentions: [Mention])? {
        conversationDrafts.entry(for: convId).map { ($0.text, $0.mentions) }
    }

    /// Keeps `text` as the draft of `convId`; empty (or whitespace-only) text removes it.
    func saveDraft(_ text: String, mentions: [Mention], for convId: String) {
        conversationDrafts.save(text, mentions: mentions, for: convId)
    }
}
