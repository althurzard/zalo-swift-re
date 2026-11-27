import SwiftUI

/// The menu-bar popover: the pinned chats as a strip, then the active conversation with a compact composer.
/// Reading and answering here goes through the official client, so the main window never has to open.
struct MenuBarPopover: View {
    let model: MenuBarModel

    @Environment(\.olazTextScale) private var textScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Typed text per conversation, so switching chats keeps the draft.
    @State private var drafts: [String: String] = [:]
    @State private var sending = false
    @State private var sendFailed = false
    @State private var sendFailureTick = 0
    @FocusState private var composerFocused: Bool

    /// Where the message list is scrolled (macOS 15+ scroll position API).
    @State private var position = ScrollPosition(edge: .bottom)
    /// The newest messages are on screen: a new message scrolls down, otherwise the position is kept.
    @State private var nearBottom = true
    /// The row briefly tinted after a quote jump, and the task that clears it.
    @State private var highlightId: String?
    @State private var jumpTask: Task<Void, Never>?

    /// Chat + newest message: a new message only scrolls when the chat did not change (a switch rebuilds the list).
    private struct ScrollSignature: Equatable {
        var chat: String?
        var last: String?
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.tab == .chats {
                chatsContent
            } else {
                draftsContent
            }
            footer
        }
        .frame(width: MenuBarController.panelSize.width, height: MenuBarController.panelSize.height)
        .onExitCommand { model.close() }
        .onAppear { model.markReadIfNeeded() }
        .onChange(of: model.showTick) { _, _ in
            model.markReadIfNeeded()
            if model.tab == .chats { composerFocused = true }
            position.scrollTo(edge: .bottom)
        }
        .onChange(of: model.activeId) { _, _ in
            model.markReadIfNeeded()
            if model.tab == .chats { composerFocused = true }
        }
        .onChange(of: ScrollSignature(chat: model.activeId, last: model.messages.last?.id)) { old, new in
            model.markReadIfNeeded()
            // A chat switch builds a fresh list already at the bottom; only a new message in the same chat scrolls.
            guard old.chat == new.chat, nearBottom else { return }
            withAnimation(.smooth(duration: 0.25)) { position.scrollTo(edge: .bottom) }
        }
        .onDisappear { jumpTask?.cancel() }
    }

    // MARK: Tabs

    @ViewBuilder private var chatsContent: some View {
        if !model.isSignedIn {
            placeholder(icon: "person.crop.circle.badge.questionmark", title: "Chưa đăng nhập Zalo",
                        caption: "Đăng nhập trong cửa sổ chính để dùng chat nhanh.")
        } else if model.pinned.isEmpty {
            placeholder(icon: "pin.slash", title: "Chưa có chat nào được ghim",
                        caption: "Ghim chat trong danh sách (chuột phải ▸ Ghim) để xem nhanh ở đây.")
        } else {
            pinnedStrip
            Divider()
            conversationHeader
            messageArea
            composer
        }
    }

    @ViewBuilder private var draftsContent: some View {
        if !model.isSignedIn {
            placeholder(icon: "person.crop.circle.badge.questionmark", title: "Chưa đăng nhập Zalo",
                        caption: "Đăng nhập trong cửa sổ chính để dùng chat nhanh.")
        } else if model.openDrafts.isEmpty {
            placeholder(icon: "tray", title: "Không có nháp chờ duyệt",
                        caption: model.assistantListening
                            ? "AI đề xuất trả lời sẽ hiện ở đây để bạn duyệt."
                            : "Bật Trợ lý AI trong Cài đặt ▸ Trợ lý AI để nhận nháp.",
                        buttonTitle: "Mở cửa sổ duyệt nháp",
                        action: { model.openDraftsWindow(focus: nil) })
        } else {
            draftsList
        }
    }

    private var draftsList: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                LazyVStack(spacing: 10) {
                    ForEach(model.openDrafts, id: \.id) { draft in
                        DraftCard(draft: draft, desk: model.desk)
                    }
                }
                .padding(12)
            }
            .scrollIndicators(.never)
            Button("Mở cửa sổ duyệt nháp (đã gửi, tạm dừng…)") { model.openDraftsWindow(focus: nil) }
                .buttonStyle(.borderless)
                .font(.caption)
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 2) {
            GlassEffectContainer(spacing: 2) {
                HStack(spacing: 2) {
                    tabSegment(.chats, title: "Đã ghim")
                    tabSegment(.drafts, title: "Nháp", badge: model.pendingDrafts)
                }
            }
            Spacer(minLength: 8)
            Button { model.openMainWindow() } label: {
                Image(systemName: "arrow.up.forward.app").font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help("Mở trong cửa sổ chính")
            Button { model.openSettings() } label: {
                Image(systemName: "gearshape").font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help("Cài đặt")
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .background {
            // ⌘[ / ⌘] switch tabs without a visible control.
            HStack(spacing: 0) {
                Button("") { selectTab(.chats) }
                    .keyboardShortcut("[", modifiers: .command)
                Button("") { selectTab(.drafts) }
                    .keyboardShortcut("]", modifiers: .command)
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder private func tabSegment(_ tab: MenuBarModel.Tab, title: String, badge: Int = 0) -> some View {
        if model.tab == tab {
            segmentButton(tab, title: title, badge: badge, selected: true)
                .glassEffect(.regular.tint(.accentColor.opacity(0.25)).interactive(), in: Capsule())
        } else {
            segmentButton(tab, title: title, badge: badge, selected: false)
        }
    }

    private func segmentButton(_ tab: MenuBarModel.Tab, title: String, badge: Int, selected: Bool) -> some View {
        Button {
            selectTab(tab)
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                if badge > 0 {
                    Text(badge > 99 ? "99+" : "\(badge)")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.red))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(tab == .chats ? "Chat đã ghim (⌘[)" : "Nháp chờ duyệt (⌘])")
    }

    private func selectTab(_ tab: MenuBarModel.Tab) {
        guard model.tab != tab else { return }
        withAnimation(.snappy(duration: 0.25)) { model.tab = tab }
    }

    // MARK: Pinned strip

    private var pinnedStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(Array(model.pinned.enumerated()), id: \.element.id) { index, conversation in
                        PopoverPinItem(model: model, conversation: conversation, index: index)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .scrollIndicators(.never)
            .onChange(of: model.activeId) { _, id in
                guard let id else { return }
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onAppear {
                if let id = model.activeId { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    // MARK: Conversation header

    private var conversationHeader: some View {
        HStack(spacing: 8) {
            if let active = model.active {
                ConversationListAvatar(conversation: active, size: 28, isSelf: model.isSelf(active.id))
                VStack(alignment: .leading, spacing: 1) {
                    Text(activeName)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    subtitleLine(for: active)
                }
            }
            Spacer(minLength: 6)
            if let index = model.pinned.firstIndex(where: { $0.id == model.activeId }), index < 9 {
                Text("⌘\(index + 1)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            // Cached messages stay on screen while the official client reopens the conversation.
            if model.isLoading && !model.messages.isEmpty {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder private func subtitleLine(for active: ZaloEngine.ConversationSummary) -> some View {
        if let typing = model.typingName {
            Text("\(typing) đang soạn tin…")
                .font(.caption)
                .foregroundStyle(.tint)
                .lineLimit(1)
        } else if active.isGroup, active.members > 0 {
            Text("\(active.members) thành viên")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            // Keeps the header from jumping when the typing line appears.
            Text(" ").font(.caption)
        }
    }

    // MARK: Messages

    @ViewBuilder private var messageArea: some View {
        if model.messages.isEmpty {
            VStack(spacing: 6) {
                if model.isLoading {
                    ProgressView().controlSize(.small)
                    Text("Đang tải tin nhắn…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Chưa có tin nhắn")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            messageList
        }
    }

    private var messageList: some View {
        let messages = model.messages
        return ScrollView(.vertical) {
            // A plain stack: at most a few hundred rows, and lazy height estimates cause jumps.
            VStack(spacing: 3) {
                if model.canShowOlder {
                    Button {
                        model.showOlder()
                    } label: {
                        Label("Xem tin cũ hơn", systemImage: "arrow.up.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderless)
                    .padding(.bottom, 2)
                }
                ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                    row(message, at: index, in: messages)
                        .id(message.id)
                }
            }
            .scrollTargetLayout()
            .padding(.leading, 12)
            // Room for the bubble tail, which overhangs the bubble's trailing edge.
            .padding(.trailing, 12 + BubbleShape.overhang)
            .padding(.vertical, 6)
        }
        // A legacy (always shown) scroller would draw its track over the bubbles' tails.
        .scrollIndicators(.never)
        // A chat switch builds a fresh list already at the bottom: no animated scroll across the old chat.
        .id(model.activeId)
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .textSelection(.enabled)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 60
        } action: { _, isNear in
            if nearBottom != isNear { nearBottom = isNear }
        }
    }

    private func row(_ message: ChatMessage, at index: Int, in messages: [ChatMessage]) -> some View {
        let previous = index > 0 ? messages[index - 1] : nil
        let next = index + 1 < messages.count ? messages[index + 1] : nil
        let starts = startsRun(message, after: previous)
        let ends = endsRun(message, before: next)
        let isGroup = model.active?.isGroup == true
        let showsStatus = message.id == model.lastMineId

        return VStack(spacing: 2) {
            if let previous, message.date.timeIntervalSince(previous.date) > 1800 {
                Text(timeLabel(message.date))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            if message.kind.isStandalone {
                standaloneText(message)
            } else if message.isMine {
                HStack(alignment: .bottom, spacing: 0) {
                    Spacer(minLength: 36)
                    VStack(alignment: .trailing, spacing: 3) {
                        bubbleColumn(message, tail: ends, chipAlignment: .leading)
                        if showsStatus {
                            let status = statusLabel(message.status)
                            Text(status.text)
                                .font(.caption2)
                                .foregroundStyle(status.style)
                        }
                    }
                }
            } else {
                HStack(alignment: .bottom, spacing: 6) {
                    if isGroup {
                        if ends {
                            RemoteAvatar(url: message.senderAvatar, name: message.senderName, size: 22)
                        } else {
                            Color.clear.frame(width: 22, height: 22)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        if isGroup, starts, !message.senderName.isEmpty {
                            Text(message.senderName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        bubbleColumn(message, tail: ends, chipAlignment: .trailing)
                    }
                    Spacer(minLength: 36)
                }
            }
        }
        .padding(.top, starts && index > 0 ? 5 : 0)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(TintShapeStyle().opacity(0.15))
                .opacity(highlightId == message.id ? 1 : 0)
        }
    }

    /// The bubble/media plus its reaction chips, which overlap the bottom edge by ~6 pt.
    private func bubbleColumn(_ message: ChatMessage, tail: Bool, chipAlignment: HorizontalAlignment) -> some View {
        VStack(alignment: chipAlignment, spacing: 0) {
            content(for: message, tail: tail)
            if !message.reactions.isEmpty {
                reactionsRow(message)
                    .offset(y: -6)
                    .padding(.bottom, 10)
            }
        }
    }

    private func reactionsRow(_ message: ChatMessage) -> some View {
        GlassEffectContainer(spacing: 3) {
            HStack(spacing: 3) {
                ForEach(message.reactions) { reaction in
                    PopoverReactionChip(conversationId: message.conversationId,
                                        messageId: message.id,
                                        reactions: message.reactions,
                                        reaction: reaction)
                }
            }
        }
    }

    @ViewBuilder private func content(for message: ChatMessage, tail: Bool) -> some View {
        switch message.kind {
        case .photo(let url, let width, let height):
            PhotoView(url: url, width: width, height: height,
                      conversationId: message.conversationId, messageId: message.id,
                      senderName: message.senderName, date: message.date,
                      encrypted: message.isE2EE, tile: nil)
                .frame(maxWidth: 220, maxHeight: 220)
        case .gif(let url):
            gifThumbnail(url, message: message)
        case .video(let thumbnail, let duration, let url):
            VideoThumb(thumbnail: thumbnail, duration: duration, url: url,
                       conversationId: message.conversationId, messageId: message.id,
                       senderName: message.senderName, date: message.date,
                       encrypted: message.isE2EE, tile: 160)
        case .sticker(let url): stickerImage(url)
        default: bubble(message, tail: tail)
        }
    }

    private func gifThumbnail(_ url: URL?, message: ChatMessage) -> some View {
        RemoteImage(url: url, contentMode: .fill, maxPixelSize: 360, animated: true) {
            Rectangle().fill(.quaternary)
        }
        .frame(width: 180, height: 140)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture {
            model.openMedia(MediaViewerItem(
                media: .photo(url: url, width: 0, height: 0, encrypted: false),
                conversationId: message.conversationId,
                messageId: message.id,
                senderName: message.senderName,
                date: message.date))
        }
    }

    private func stickerImage(_ url: URL?) -> some View {
        RemoteImage(url: url, contentMode: .fit, maxPixelSize: 180) { Color.clear }
            .frame(width: 90, height: 90)
    }

    private func bubble(_ message: ChatMessage, tail: Bool) -> some View {
        let mine = message.isMine
        return VStack(alignment: .leading, spacing: 5) {
            if let quote = message.quote {
                quoteBlock(quote, mine: mine)
            }
            Text(message.text.isEmpty ? "[Tin nhắn]" : message.text)
                .font(.system(size: 13 * textScale))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 250, alignment: .leading)
        }
        .foregroundStyle(mine ? Color.white : Color.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            BubbleShape(mine: mine, tail: tail)
                .fill(mine ? AnyShapeStyle(.tint) : AnyShapeStyle(ChatPalette.incoming))
        }
    }

    private func quoteBlock(_ quote: ChatMessage.Quote, mine: Bool) -> some View {
        Button {
            if let row = model.reveal(quote) { jump(to: row) }
        } label: {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(mine ? Color.white.opacity(0.7) : Color.secondary.opacity(0.5))
                    .frame(width: 2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(quote.senderName)
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Text(quote.text)
                        .font(.caption2)
                        .lineLimit(2)
                }
                .opacity(0.85)
                .frame(maxWidth: 220, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(quote.messageIds.isEmpty ? "" : "Đến tin nhắn gốc")
    }

    /// Brings a row to the middle, repeats the scroll once the page has grown, then tints it for a moment.
    private func jump(to id: String) {
        jumpTask?.cancel()
        withAnimation(.snappy(duration: 0.3)) { position.scrollTo(id: id, anchor: .center) }
        jumpTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            position.scrollTo(id: id, anchor: .center)
            withAnimation(.easeOut(duration: 0.2)) { highlightId = id }
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.4)) { highlightId = nil }
        }
    }

    @ViewBuilder private func standaloneText(_ message: ChatMessage) -> some View {
        if !message.text.isEmpty {
            Text(message.text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
        }
    }

    private func startsRun(_ message: ChatMessage, after previous: ChatMessage?) -> Bool {
        guard let previous else { return true }
        return previous.senderId != message.senderId || message.date.timeIntervalSince(previous.date) > 300
    }

    private func endsRun(_ message: ChatMessage, before next: ChatMessage?) -> Bool {
        guard let next else { return true }
        return next.senderId != message.senderId || next.date.timeIntervalSince(message.date) > 300
    }

    private func timeLabel(_ date: Date) -> String {
        let time = date.formatted(.dateTime.hour().minute())
        guard !Calendar.current.isDateInToday(date) else { return time }
        return "\(date.formatted(.dateTime.day().month())) \(time)"
    }

    private func statusLabel(_ status: ChatMessage.Status) -> (text: String, style: AnyShapeStyle) {
        switch status {
        case .sending: ("Đang gửi", AnyShapeStyle(.tertiary))
        case .sent: ("Đã gửi", AnyShapeStyle(.tertiary))
        case .delivered: ("Đã nhận", AnyShapeStyle(.tertiary))
        case .seen: ("Đã xem", AnyShapeStyle(.tertiary))
        case .failed: ("Gửi không thành công", AnyShapeStyle(Color.red))
        }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if sendFailed {
                Text("Chưa gửi được, thử lại")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .padding(.leading, 14)
                    .transition(.opacity)
            }
            HStack(alignment: .center, spacing: 8) {
                TextField("Nhắn tới \(activeName)…", text: draftBinding, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...5)
                    .focused($composerFocused)
                    .onSubmit(sendDraft)
                    .padding(.leading, 14)
                    .padding(.trailing, 6)
                    .padding(.vertical, 8)
                Button(action: sendDraft) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .opacity(canSend ? 1 : 0.35)
                .help("Gửi")
                .padding(.trailing, 8)
            }
            .frame(minHeight: 38)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 19))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var draftBinding: Binding<String> {
        Binding(get: { drafts[model.activeId ?? ""] ?? "" },
                set: { drafts[model.activeId ?? ""] = $0 })
    }

    private var canSend: Bool {
        !(drafts[model.activeId ?? ""] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !sending
    }

    private var activeName: String {
        guard let active = model.active else { return "" }
        return model.isSelf(active.id) ? "Cloud của tôi" : active.displayName
    }

    private func sendDraft() {
        let key = model.activeId ?? ""
        let text = (drafts[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        Task {
            let sent = await model.send(text)
            sending = false
            if sent {
                drafts[key] = ""
                sendFailed = false
            } else {
                sendFailureTick += 1
                let tick = sendFailureTick
                withAnimation(.easeOut(duration: 0.2)) { sendFailed = true }
                try? await Task.sleep(for: .seconds(3))
                if sendFailureTick == tick {
                    withAnimation(.easeOut(duration: 0.2)) { sendFailed = false }
                }
            }
        }
    }

    // MARK: Footer and states

    private var footer: some View {
        HStack {
            Text(model.tab == .drafts ? "⌘[ ⌘] đổi tab" : "⌥⌘Z mở/đóng")
            Spacer()
            Text(model.tab == .drafts ? "Esc đóng" : "Esc đóng · Enter gửi")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    private func placeholder(icon: String, title: String, caption: String,
                             buttonTitle: String = "Mở Olaz",
                             action: (() -> Void)? = nil) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(buttonTitle) {
                if let action { action() } else { model.openMainWindow() }
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One reaction chip: tapping it shows who reacted.
private struct PopoverReactionChip: View {
    let conversationId: String
    let messageId: String
    let reactions: [ChatMessage.Reaction]
    let reaction: ChatMessage.Reaction

    @State private var showsDetail = false

    var body: some View {
        Button { showsDetail = true } label: {
            HStack(spacing: 3) {
                ReactionIconView(icon: reaction.icon, size: 13)
                if reaction.count > 1 {
                    Text("\(reaction.count)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .glassEffect(reaction.includesMe ? Glass.regular.tint(.accentColor.opacity(0.35)) : Glass.regular,
                         in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(reaction.tooltip ?? "")
        .popover(isPresented: $showsDetail, arrowEdge: .bottom) {
            ReactionDetailView(conversationId: conversationId, messageId: messageId, reactions: reactions)
        }
    }
}

/// One pinned chat in the strip: avatar with the selection ring and the unread count, name below.
private struct PopoverPinItem: View {
    let model: MenuBarModel
    let conversation: ZaloEngine.ConversationSummary
    let index: Int

    @State private var hovering = false

    private var isSelf: Bool { model.isSelf(conversation.id) }
    private var name: String { isSelf ? "Cloud của tôi" : conversation.displayName }
    private var selected: Bool { model.activeId == conversation.id }

    var body: some View {
        if index < 9 {
            button.keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
        } else {
            button
        }
    }

    private var button: some View {
        Button {
            model.select(conversation.id)
        } label: {
            VStack(spacing: 4) {
                ConversationListAvatar(conversation: conversation, size: 44, isSelf: isSelf)
                    .padding(2)
                    .overlay {
                        Circle()
                            .strokeBorder(.tint, lineWidth: 2)
                            .opacity(selected ? 1 : 0)
                            .animation(.spring(duration: 0.3), value: selected)
                    }
                    .overlay(alignment: .topTrailing) { unreadBadge }
                    .scaleEffect(hovering ? 1.06 : 1)
                    .animation(.spring(duration: 0.25), value: hovering)
                Text(name)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity)
            }
            .frame(width: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(name)
    }

    @ViewBuilder private var unreadBadge: some View {
        if conversation.unread > 0 {
            Text(conversation.unread > 99 ? "99+" : "\(conversation.unread)")
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(.red))
                .offset(x: 7, y: -4)
        }
    }
}
