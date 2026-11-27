import AppKit
import Observation

/// State of the menu-bar panel: the pinned conversations, which one it shows, sending and read state.
///
/// The official renderer syncs messages only for the one conversation it has open, so showing a chat here opens it there
/// too; the main window follows (`shell.selection`) so both always show the same conversation. Reopening the panel keeps
/// the conversation it showed last, so a quick look costs no conversation switch in the official client.
@MainActor
@Observable
final class MenuBarModel {
    let engine: ZaloEngine
    let shell: ShellModel

    /// The conversation the panel shows; nil until the panel first opens.
    private(set) var activeId: String?
    /// Bumped every time the panel opens: the view scrolls to the newest message and focuses the composer.
    private(set) var showTick = 0
    private(set) var isShown = false
    /// How many of the newest messages are on screen; grows with "Xem tin cũ hơn" and quote jumps.
    private(set) var visibleCount = MenuBarModel.pageSize

    enum Tab: Hashable { case chats, drafts }
    /// Pinned chats or the AI reply drafts waiting for review (kept between openings).
    var tab: Tab = .chats

    /// Set by `MenuBarController`.
    @ObservationIgnored var closePanel: () -> Void = {}
    /// conversation id → id of the newest message already marked read from here.
    @ObservationIgnored private var lastMarked: [String: String] = [:]

    /// Messages added to the screen per page.
    static let pageSize = 40

    init(engine: ZaloEngine, shell: ShellModel) {
        self.engine = engine
        self.shell = shell
    }

    var isSignedIn: Bool { engine.profile != nil }

    /// Pinned conversations, as the inbox's pinned tiles show them: the official pin flag (`conversationActions`, the
    /// summary's own `pinned` is not filled), in the official list order; hidden chats never show here.
    var pinned: [ZaloEngine.ConversationSummary] {
        let actions = engine.conversationActions
        let pins = engine.conversations.filter { actions.isPinned($0.id) && !actions.isHidden($0.id) }
        let order = Dictionary(engine.conversationExtras.listIds.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return pins.enumerated()
            .sorted { (order[$0.element.id] ?? Int.max, $0.offset) < (order[$1.element.id] ?? Int.max, $1.offset) }
            .map(\.element)
    }

    var unreadTotal: Int { pinned.reduce(0) { $0 + $1.unread } }

    // MARK: AI drafts ("Duyệt nháp trả lời")

    var desk: AssistantDesk { engine.assistant }
    /// Drafts still to act on (pending, queued, sending), newest first.
    var openDrafts: [AssistantDesk.Draft] { desk.openDrafts.reversed() }
    /// Drafts waiting for a click on Gửi: the count on the "Nháp" tab and the menu-bar icon.
    var pendingDrafts: Int { desk.pendingCount }
    /// The assistant socket is on (Settings ▸ Trợ lý AI); without it no draft can arrive.
    var assistantListening: Bool { desk.isListening }

    /// The full review window (finished drafts, pause switch).
    func openDraftsWindow(focus draftId: String? = nil) {
        closePanel()
        NSApp.activate()
        // The main window's root view opens the review window (`revealRequest`): reopen it first when it was closed.
        if shell.window?.isVisible == true {
            desk.reveal(draftId: draftId)
        } else {
            _ = NSApp.delegate?.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false)
            Task { @MainActor [desk] in
                try? await Task.sleep(for: .milliseconds(400))
                desk.reveal(draftId: draftId)
            }
        }
    }

    var active: ZaloEngine.ConversationSummary? {
        guard let activeId else { return nil }
        return pinned.first { $0.id == activeId }
    }

    func isSelf(_ id: String) -> Bool { id == engine.selfConversationId }

    private var allMessages: [ChatMessage] { activeId.flatMap { engine.messages[$0] } ?? [] }

    /// The newest `visibleCount` messages of the active conversation, oldest first.
    var messages: [ChatMessage] { Array(allMessages.suffix(visibleCount)) }

    /// Older messages exist: already loaded but off screen, or still on the server.
    var canShowOlder: Bool {
        guard let activeId else { return false }
        return allMessages.count > visibleCount || engine.hasMoreHistory[activeId] == true
    }

    /// My newest message: the delivery status ("Đã gửi / Đã nhận / Đã xem") goes under it, as in the main window.
    var lastMineId: String? { allMessages.last { $0.isMine && !$0.kind.isStandalone }?.id }

    /// The active conversation is still being opened in the official client (no messages to show yet).
    var isLoading: Bool {
        guard let activeId else { return false }
        return engine.openConversationId != activeId || engine.messages[activeId] == nil
    }

    /// "Đang soạn tin…" line for the active conversation.
    var typingName: String? { activeId.flatMap { engine.typing[$0] } }

    // MARK: Lifecycle (MenuBarController)

    func willShow() {
        isShown = true
        showTick += 1
        // New drafts waiting and no unread pinned chat: they are what the user opened the panel for.
        if pendingDrafts > 0, unreadTotal == 0 { tab = .drafts }
        let list = pinned
        if let activeId, list.contains(where: { $0.id == activeId }) {
            select(activeId)
        } else if let open = engine.openConversationId, list.contains(where: { $0.id == open }) {
            select(open)
        } else if let first = list.first(where: { $0.unread > 0 }) ?? list.first {
            select(first.id)
        } else {
            activeId = nil
        }
    }

    func didClose() { isShown = false }

    // MARK: Actions

    /// Shows `id` here and opens it in the official client; the main window follows.
    func select(_ id: String) {
        if activeId != id { visibleCount = Self.pageSize }
        activeId = id
        guard engine.openConversationId != id else { markReadIfNeeded(); return }
        if shell.selection != id {
            // As a notification click does: back to the unfiltered list so the conversation is visible there.
            shell.destination = .inbox
            shell.search = ""
            shell.selection = id
        }
        // The main window may be closed (nothing observes `selection` then): open it directly, never a locked hidden chat.
        if engine.conversationActions.hiddenKnown, !engine.isConversationLocked(id) {
            engine.openConversation(id)
        }
    }

    /// ⌘1…⌘9.
    func select(index: Int) {
        let list = pinned
        guard list.indices.contains(index) else { return }
        select(list[index].id)
    }

    /// One more page: loaded messages first, then an older page from the official client.
    func showOlder() {
        guard let activeId else { return }
        if allMessages.count > visibleCount {
            visibleCount = min(allMessages.count, visibleCount + Self.pageSize)
        } else if engine.hasMoreHistory[activeId] == true, engine.openConversationId == activeId {
            visibleCount += Self.pageSize
            engine.loadOlderMessages(activeId)
        }
    }

    /// The on-screen row a quote points at, widening the page when the message is loaded but older than the screen.
    /// nil when it is not loaded here: the main window (which pages history until it finds it) takes over.
    func reveal(_ quote: ChatMessage.Quote) -> String? {
        let wanted = Set(quote.messageIds)
        guard !wanted.isEmpty else { return nil }
        let all = allMessages
        // An album photo's row is "<message id>#<n>" when its own id is unknown.
        guard let index = all.lastIndex(where: { wanted.contains($0.id) || wanted.contains(String($0.id.split(separator: "#").first ?? "")) })
        else {
            openMainWindow()
            return nil
        }
        visibleCount = max(visibleCount, all.count - index)
        return all[index].id
    }

    /// Returns false when the official client did not take the message (the caller keeps the text).
    func send(_ text: String) async -> Bool {
        guard let id = activeId, engine.openConversationId == id else { return false }
        return await engine.sendText(text, to: id)
    }

    /// Photos and videos open in the app's media viewer (full screen capable); the panel waits behind it.
    func openMedia(_ item: MediaViewerItem) {
        MediaViewer.shared.show(item, engine: engine, shell: shell)
    }

    /// Marks the active conversation read while the panel shows it: when it has unread messages, or a new incoming
    /// message arrived since the last mark. Call on open, on conversation change and when its messages change.
    func markReadIfNeeded() {
        guard isShown, let conversation = active, engine.openConversationId == conversation.id else { return }
        let last = engine.messages[conversation.id]?.last
        let key = last?.id ?? ""
        let previous = lastMarked[conversation.id]
        let newIncoming = last.map { !$0.isMine } == true && previous != nil && previous != key
        if (conversation.unread > 0 && previous != key) || newIncoming {
            engine.markRead(conversation.id)
        }
        lastMarked[conversation.id] = key
    }

    /// Brings the main window forward (reopening it when it was closed), showing the active conversation.
    func openMainWindow() {
        closePanel()
        NSApp.activate()
        if let window = shell.window, window.isVisible || window.isMiniaturized {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            // SwiftUI's app delegate opens a new main window on a reopen with nothing visible (as a Dock click does).
            _ = NSApp.delegate?.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false)
        }
    }

    func openSettings() {
        closePanel()
        NSApp.activate()
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    /// Esc / ⌘W.
    func close() { closePanel() }
}
