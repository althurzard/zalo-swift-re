import SwiftUI

/// Native chat pane for one conversation. All data comes from `ZaloEngine`.
struct ChatView: View {
    let conversation: ZaloEngine.ConversationSummary

    @Environment(ZaloEngine.self) private var engine
    @Environment(ShellModel.self) private var shell
    @Environment(\.scenePhase) private var scenePhase

    @State private var draft = ""
    @State private var draftMentions: [Mention] = []
    @State private var replyTo: ChatMessage?
    @State private var focusTick = 0
    @State private var sendTick = 0
    @State private var notice: SendNotice?
    @State private var lastMarkedId: String?
    /// Width of the chat column; the header's room in the toolbar is what the buttons leave of it.
    @State private var columnWidth: CGFloat = 400
    /// A loaded message to bring on screen (a pin of the pinned bar).
    @State private var jumpTarget: String?

    private enum SendNotice { case restored, like }

    private var id: String { conversation.id }

    var body: some View {
        @Bindable var shell = shell
        let loaded = engine.messages[id]
        Group {
            if let loaded {
                if loaded.isEmpty {
                    ContentUnavailableView {
                        Label("Chưa có tin nhắn", systemImage: "bubble.left")
                    } description: {
                        Text("Tin nhắn cũ nằm trên điện thoại của bạn. Đồng bộ để xem lịch sử trò chuyện với \(conversation.displayName) trên máy tính.")
                    } actions: {
                        if engine.canStartTransfer {
                            Button("Đồng bộ tin nhắn", systemImage: "iphone.and.arrow.forward") { engine.startTransfer() }
                                .buttonStyle(.glassProminent)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .tourAnchor(.message, arrowEdge: .trailing)
                } else {
                    MessageList(conversation: conversation, scrollToBottomTick: sendTick, jumpTarget: $jumpTarget, onReply: reply)
                }
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Đang tải tin nhắn…").font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .tourAnchor(.message, arrowEdge: .trailing)
            }
        }
        .background { ChatWallpaperBackground() }
        .safeAreaBar(edge: .top, spacing: 0) {
            PinnedBar(conversationId: id, open: openPin)
        }
        .safeAreaBar(edge: .bottom, spacing: 0) {
            ChatComposer(
                name: conversation.displayName,
                conversationId: id,
                isGroup: conversation.isGroup,
                draft: $draft,
                mentions: $draftMentions,
                replyTo: $replyTo,
                typingName: engine.typing[id],
                focusTick: focusTick,
                send: send,
                sendLike: {
                    sendTick += 1
                    Task { if await !engine.sendText("👍", to: id) { notice = .like } }
                })
        }
        .alert("Chưa gửi được tin nhắn", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(notice == .like ? "Không gửi được biểu tượng 👍. Hãy thử lại." : "Nội dung đã được trả lại vào ô soạn thảo. Hãy thử gửi lại.")
        }
        .toolbar {
            // macOS 27 lays the detail column's toolbar items out from its leading edge, so the header (avatar, name, subtitle)
            // is the first item, like Mail's, and the flexible spacer keeps the buttons at the trailing edge. A toolbar item has a
            // fixed ideal width, so the header is capped at what the column leaves beside the buttons, or a long name would push
            // them into the overflow menu; the name truncates instead.
            ToolbarItem(placement: .primaryAction) {
                header(subtitle: subtitle(last: loaded?.last))
                    .frame(maxWidth: max(0, columnWidth - Self.toolbarButtonsRoom), alignment: .leading)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.flexible, placement: .primaryAction)
            ToolbarItemGroup(placement: .primaryAction) {
                ChatCallButtons(conversation: conversation)
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    shell.toggleInspector()
                } label: {
                    Label("Thông tin", systemImage: "sidebar.right")
                }
                .help("Thông tin (⌥⌘I)")
                .tourAnchor(.toolbar, arrowEdge: .bottom)
                ConversationHeaderMenu(conversationId: id)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { columnWidth = $0 }
        .cardActionPresenter()
        .messageActionPresenter(conversationId: id)
        .onAppear {
            focusTick += 1
            restoreFailedDraft()
            markReadIfNeeded(last: loaded?.last, newIncomingOnly: false)
        }
        .onChange(of: engine.failedDrafts.revision) { _, _ in restoreFailedDraft() }
        .onChange(of: loaded?.last?.id) { _, _ in markReadIfNeeded(last: engine.messages[id]?.last, newIncomingOnly: true) }
        .onChange(of: conversation.unread) { _, _ in markReadIfNeeded(last: engine.messages[id]?.last, newIncomingOnly: false) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { markReadIfNeeded(last: engine.messages[id]?.last, newIncomingOnly: false) }
        }
        // ⌘R: reply to the newest incoming message.
        .onChange(of: shell.replyTick) { _, _ in
            if let newest = engine.messages[id]?.last(where: { !$0.isMine && !$0.kind.isStandalone && $0.kind != .recalled }) { reply(newest) }
        }
    }

    /// Toolbar room kept free of the header: the call buttons, the info button and the "⋯" menu with their spacing.
    private static let toolbarButtonsRoom: CGFloat = 230

    /// Avatar, name and subtitle: the first toolbar item of the chat column.
    private func header(subtitle: String) -> some View {
        HStack(spacing: 10) {
            RemoteAvatar(url: conversation.avatar, name: conversation.displayName, size: 30)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    Text(conversation.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    MutedBell(conversationId: id, size: 11)
                }
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(engine.typing[id] != nil ? AnyShapeStyle(TintShapeStyle()) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func subtitle(last: ChatMessage?) -> String {
        if let name = engine.typing[id] { return "\(name) đang soạn tin…" }
        if conversation.isGroup, conversation.members > 0 { return "\(conversation.members) thành viên" }
        if last?.isE2EE == true { return "Mã hóa đầu cuối" }
        return ""
    }

    /// Marks read only when there is something unread: `unread > 0`, or an incoming
    /// last message whose id has not been marked yet. Avoids redundant server round trips.
    private func markReadIfNeeded(last: ChatMessage?, newIncomingOnly: Bool) {
        guard scenePhase == .active, engine.openConversationId == id else { return }
        if let last, !last.isMine, last.id != lastMarkedId, newIncomingOnly || conversation.unread > 0 {
            lastMarkedId = last.id
            engine.markRead(id)
        } else if !newIncomingOnly, conversation.unread > 0 {
            engine.markRead(id)
        }
        if lastMarkedId == nil { lastMarkedId = last?.id }
    }

    private func reply(_ message: ChatMessage) {
        replyTo = message
        focusTick += 1
    }

    /// A pin of the pinned bar: its message when it is loaded, a poll's detail, otherwise its full text.
    private func openPin(_ item: PinnedItem) {
        switch item.kind {
        case .message:
            if let target = item.message(in: engine.messages[id] ?? []) {
                jumpTarget = target.id
            } else {
                CardActionCenter.shared.show("Tin nhắn đã ghim chưa được tải. Kéo lên để xem tin nhắn cũ hơn.", in: id)
            }
        case .poll:
            if let pollId = item.ref.split(separator: ":").last.map(String.init), !pollId.isEmpty {
                CardActionCenter.shared.poll = PollRequest(conversationId: id, pollId: pollId)
            }
        case .note, .link, .reminder:
            CardActionCenter.shared.show(item.title.isEmpty ? item.label : item.title, in: id)
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let staged = engine.takeStagedImages(for: id)
        guard !text.isEmpty || !staged.isEmpty else { return }
        // Untrimmed draft: the engine re-bases mention offsets when it trims.
        let (sentDraft, sentMentions, sentReply) = (draft, draftMentions, replyTo)
        draft = ""
        draftMentions = []
        replyTo = nil
        sendTick += 1
        let (engine, id) = (engine, id)
        Task {
            if !staged.isEmpty {
                let singlePhotoCaption = staged.count == 1 && !text.isEmpty && sentMentions.isEmpty && sentReply == nil
                let outcome = await engine.sendMedia(staged.map(\.fileURL), to: id, caption: singlePhotoCaption ? sentDraft : nil)
                switch outcome {
                case .done, .pending:
                    break
                case .failed, .cancelled:
                    engine.restoreStagedImages(staged, in: id)
                    if singlePhotoCaption {
                        engine.failedDrafts.stash(ComposerDraft(text: sentDraft, mentions: sentMentions, replyTo: sentReply), for: id, silent: true)
                    }
                }
                engine.report(outcome, in: id)
                if singlePhotoCaption || text.isEmpty { return }
            }
            guard await !engine.sendText(sentDraft, to: id, quoting: sentReply?.id, mentions: sentMentions) else { return }
            // Nothing was sent. The view may be gone by now (conversation switched): the engine keeps the text and the
            // composer shown for this conversation takes it back (`restoreFailedDraft`).
            engine.failedDrafts.stash(ComposerDraft(text: sentDraft, mentions: sentMentions, replyTo: sentReply), for: id)
        }
    }

    /// Puts a failed draft back after whatever is in the composer now (typed meanwhile, or restored earlier);
    /// a reply target chosen meanwhile wins.
    private func restoreFailedDraft() {
        guard let (failed, showsNotice) = engine.failedDrafts.takeWithNotice(for: id) else { return }
        let merged = ComposerDraft(text: draft, mentions: draftMentions, replyTo: replyTo).appending(failed)
        draft = merged.text
        draftMentions = merged.mentions
        replyTo = merged.replyTo
        if showsNotice { notice = .restored }
    }
}

// MARK: - Row model (memoized)

struct ChatRow: Identifiable {
    enum Kind {
        case day(Date)
        case message(ChatMessage, first: Bool, last: Bool, status: Bool)
    }
    /// Prefix of a day separator's id; the rest is the id of the day's first message.
    static let dayPrefix = "day-"
    let id: String
    let kind: Kind

    /// The row to bring back to the top after older history was prepended: the row that was there, unless it is gone. A
    /// day separator is keyed by the day's first message, so older messages of that same day replace it; its message
    /// stays.
    static func restoreTarget(_ saved: String?, fallback: String, in rows: [ChatRow]) -> String {
        guard let saved else { return fallback }
        if rows.contains(where: { $0.id == saved }) { return saved }
        if saved.hasPrefix(dayPrefix) {
            let message = String(saved.dropFirst(dayPrefix.count))
            if rows.contains(where: { $0.id == message }) { return message }
        }
        return fallback
    }
}

/// Rebuilds rows only when the message array actually changed.
private final class RowCache {
    private var source: [ChatMessage] = []
    private var rows: [ChatRow] = []

    func rows(for msgs: [ChatMessage]) -> [ChatRow] {
        if msgs == source { return rows }
        source = msgs
        rows = Self.build(msgs)
        return rows
    }

    private static func build(_ msgs: [ChatMessage]) -> [ChatRow] {
        let cal = ChatFormat.calendar
        let days = msgs.map { cal.startOfDay(for: $0.date) }
        // Notices / e-cards are not bubbles: they never carry the status line and do not take part in grouping.
        let lastMineId = msgs.last(where: { $0.isMine && !$0.kind.isStandalone })?.id
        func grouped(_ i: Int, _ j: Int) -> Bool {
            let a = msgs[i], b = msgs[j]
            if a.kind.isStandalone || b.kind.isStandalone { return false }
            return a.senderId == b.senderId && a.isMine == b.isMine
                && abs(b.date.timeIntervalSince(a.date)) < 300 && days[i] == days[j]
        }
        var out: [ChatRow] = []
        out.reserveCapacity(msgs.count + 8)
        for i in msgs.indices {
            let m = msgs[i]
            if i == 0 || days[i - 1] != days[i] {
                out.append(ChatRow(id: ChatRow.dayPrefix + m.id, kind: .day(m.date)))
            }
            let first = i == 0 || !grouped(i - 1, i)
            let last = i == msgs.count - 1 || !grouped(i, i + 1)
            out.append(ChatRow(id: m.id, kind: .message(m, first: first, last: last, status: m.id == lastMineId)))
        }
        return out
    }
}

// MARK: - Message list

private struct MessageList: View {
    let conversation: ZaloEngine.ConversationSummary
    let scrollToBottomTick: Int
    @Binding var jumpTarget: String?
    var onReply: (ChatMessage) -> Void

    @Environment(ZaloEngine.self) private var engine
    @Environment(ShellModel.self) private var shell

    @State private var cache = RowCache()
    @State private var atTop = false
    @State private var nearBottom = true
    @State private var lastContentHeight: CGFloat = 0
    @State private var loadingOlder = false
    @State private var olderTask: Task<Void, Never>?
    @State private var topId: String?
    @State private var restoreId: String?
    /// False from the moment an older page lands until the reader leaves the top: one page per pull, like the official
    /// client, instead of paging on and on while the restored position still reads as "at the top".
    @State private var olderArmed = true

    private var id: String { conversation.id }

    private struct Metrics: Equatable {
        var top: CGFloat
        var fromBottom: CGFloat
        var content: CGFloat
        var visible: CGFloat
    }

    var body: some View {
        let msgs = engine.messages[id] ?? []
        let rows = cache.rows(for: msgs)
        let hasMore = engine.hasMoreHistory[id] ?? false
        let newestId = msgs.last?.id
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if loadingOlder {
                        ProgressView().controlSize(.small).padding(.vertical, 10)
                    }
                    ForEach(rows) { row in
                        switch row.kind {
                        case .day(let date):
                            DaySeparator(date: date)
                        case .message(let m, let first, let last, let status):
                            MessageRow(message: m, isGroup: conversation.isGroup,
                                       firstInGroup: first, lastInGroup: last, showStatus: status,
                                       isNewest: m.id == newestId,
                                       onReply: onReply,
                                       onReact: { emoji, msg in engine.react(emoji, to: msg.id, in: id) })
                        }
                    }
                    Color.clear.frame(height: 8).id("bottom")
                }
                .scrollTargetLayout()
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            // Only the initial offset is anchored; later size changes must not yank the view.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .scrollPosition(id: $topId, anchor: .top)
            .scrollEdgeEffectStyle(.hard, for: .top)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .onScrollGeometryChange(for: Metrics.self) { geo in
                Metrics(top: geo.contentOffset.y + geo.contentInsets.top,
                        fromBottom: geo.contentSize.height - geo.visibleRect.maxY,
                        content: geo.contentSize.height,
                        visible: geo.visibleRect.height)
            } action: { _, m in
                let top = m.top < 120
                // Re-armed once the reader is away from the top, or when the history is too short to ever leave the top band.
                if !olderArmed, !top || m.content - m.visible < 120 { olderArmed = true }
                if top != atTop { atTop = top }
                // Only user scrolling (not content growth) changes "near bottom".
                if abs(m.content - lastContentHeight) < 1 {
                    let near = m.fromBottom < 160
                    if near != nearBottom { nearBottom = near }
                }
                lastContentHeight = m.content
            }
            .onChange(of: atTop) { _, _ in maybeLoadOlder(hasMore: hasMore, count: msgs.count) }
            .onChange(of: olderArmed) { _, _ in maybeLoadOlder(hasMore: hasMore, count: msgs.count) }
            .onChange(of: hasMore) { _, now in
                if !now { loadingOlder = false; olderTask?.cancel() }
                maybeLoadOlder(hasMore: now, count: msgs.count)
            }
            .onChange(of: msgs.first?.id) { old, _ in
                // Older history was prepended: put the row that was at the top back there, and wait for the reader to
                // scroll up again before the next page.
                guard let old, let idx = msgs.firstIndex(where: { $0.id == old }), idx > 0 else { return }
                olderArmed = false
                // A pull saved its row; a prepend nobody asked for keeps the row on screen now (the binding still holds it).
                let target = ChatRow.restoreTarget(restoreId ?? topId, fallback: old, in: rows)
                restoreId = nil
                topId = target
                proxy.scrollTo(target, anchor: .top)
            }
            .onChange(of: engine.historyTicks[id] ?? 0) { _, _ in
                // An older page arrived but every message in it is a hidden card: ask for the next one.
                loadingOlder = false
                olderTask?.cancel()
                maybeLoadOlder(hasMore: hasMore, count: msgs.count)
            }
            .onChange(of: msgs.count) { _, _ in
                loadingOlder = false
                olderTask?.cancel()
                maybeLoadOlder(hasMore: hasMore, count: msgs.count)
            }
            .onChange(of: msgs.last?.id) { old, _ in
                guard old != nil else { return }
                if nearBottom || msgs.last?.isMine == true { scrollToBottom(proxy) }
            }
            .onChange(of: scrollToBottomTick) { _, _ in scrollToBottom(proxy) }
            .onChange(of: jumpTarget) { _, target in
                guard let target else { return }
                jumpTarget = nil
                withAnimation(.snappy(duration: 0.3)) { proxy.scrollTo(target, anchor: .center) }
            }
            // The tour's message step points at the newest row: make sure it exists in the lazy stack.
            .onChange(of: shell.tour) { _, step in if step == .message { scrollToBottom(proxy) } }
            .onAppear {
                DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onDisappear { olderTask?.cancel() }
            .overlay(alignment: .bottomTrailing) {
                if !nearBottom {
                    Button {
                        scrollToBottom(proxy)
                    } label: {
                        Image(systemName: "chevron.down").font(.system(size: 13, weight: .bold))
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .padding(14)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityLabel("Cuộn xuống tin nhắn mới nhất")
                }
            }
            .animation(.snappy(duration: 0.2), value: nearBottom)
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.snappy(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    private func maybeLoadOlder(hasMore: Bool, count: Int) {
        guard atTop, olderArmed, hasMore, !loadingOlder, count > 0 else { return }
        olderTask?.cancel()
        olderTask = Task {
            try? await Task.sleep(for: .milliseconds(250)) // debounce
            guard !Task.isCancelled, atTop, olderArmed, engine.hasMoreHistory[id] == true else { return }
            restoreId = topId
            loadingOlder = true
            engine.loadOlderMessages(id)
            try? await Task.sleep(for: .seconds(6)) // give up the spinner if nothing arrives
            if !Task.isCancelled { loadingOlder = false }
        }
    }
}

// MARK: - Day separator

/// "Hôm nay 09:41" in a small glass capsule; the time is the day's first loaded message.
private struct DaySeparator: View {
    let date: Date
    var body: some View {
        HStack(spacing: 4) {
            Text(ChatFormat.daySeparator(date)).fontWeight(.semibold)
            Text(ChatFormat.time(date))
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 11).padding(.vertical, 4)
        .glassEffect(.regular, in: Capsule())
        .frame(maxWidth: .infinity)
        .padding(.top, 14).padding(.bottom, 6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
