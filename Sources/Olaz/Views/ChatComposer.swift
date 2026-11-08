import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Floating glass composer: typing indicator, reply banner, suggestions, then one row of "+" menu, text capsule and send / like button.
struct ChatComposer: View {
    let name: String
    /// Group conversations offer @mentions of the official member list.
    var conversationId: String = ""
    var isGroup: Bool = false
    @Binding var draft: String
    @Binding var mentions: [Mention]
    @Binding var replyTo: ChatMessage?
    let typingName: String?
    let focusTick: Int
    let send: () -> Void
    let sendLike: () -> Void

    @Environment(ZaloEngine.self) private var engine
    @AppStorage(OlazPrefs.accent) private var accentStored = OlazAccent.blue.rawValue
    @Namespace private var glassNamespace
    @State private var textHeight: CGFloat = ComposerTextView.lineHeight
    @State private var handle = ComposerHandle()
    @State private var query: MentionQuery?
    @State private var candidates: [MentionCandidate] = []
    @State private var selected = 0
    @State private var showPollCreate = false
    @State private var showStickers = false
    @State private var showMyCard = false
    @State private var reminderInfo: ReminderComposeInfo?
    @State private var spreadsheetPaste: SpreadsheetPastePayload?
    @State private var isDropTargeted = false
    @State private var uploadingCount = 0
    @State private var pasteMonitor: Any?
    @State private var lastPasteGuard: (changeCount: Int, time: TimeInterval)?

    private enum AttachmentKind { case media, files }
    /// Stickers suggested for the draft (official suggestion logic); they show only while the draft still is the text they were found for.
    @State private var typingStickers = TypingStickerState()
    @State private var sendingSuggestion: String?

    private var suggestionsOpen: Bool { isGroup && query != nil && !candidates.isEmpty }
    private var stickerStripOpen: Bool {
        typingStickers.isVisible(draft: draft, mentionListOpen: suggestionsOpen, settingEnabled: StickerSuggestState.shared.setting?.enabled)
    }

    private var staged: [StagedImage] { engine.stagedImages[conversationId] ?? [] }
    private var isEmpty: Bool { draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && staged.isEmpty }

    var body: some View {
        VStack(spacing: 8) {
            if let typingName {
                HStack(spacing: 6) {
                    Image(systemName: "ellipsis.bubble").symbolEffect(.pulse)
                    Text("\(typingName) đang soạn tin…")
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 11).padding(.vertical, 4)
                .glassEffect(.regular, in: Capsule())
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
            }
            if uploadingCount > 0 {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.mini)
                    Text("Đang gửi tệp đính kèm…")
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 11).padding(.vertical, 4)
                .glassEffect(.regular, in: Capsule())
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
            }
            if let replyTo {
                HStack(spacing: 8) {
                    Rectangle().fill(.tint).frame(width: 2.5)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Trả lời \(replyTo.isMine ? "chính mình" : replyTo.senderName)")
                            .font(.system(size: 11.5, weight: .semibold))
                        Text(replyTo.text.isEmpty ? "Tin nhắn" : replyTo.text)
                            .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button("Hủy trả lời", systemImage: "xmark") { self.replyTo = nil }
                        .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if !staged.isEmpty {
                StagedImageStrip(
                    images: staged,
                    remove: { engine.removeStagedImage($0, in: conversationId) },
                    clearAll: { engine.clearStagedImages(in: conversationId) }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if suggestionsOpen {
                MentionSuggestions(candidates: candidates, selected: $selected, pick: pick)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if stickerStripOpen {
                TypingStickerStrip(stickers: typingStickers.stickers, sending: sendingSuggestion, pick: sendSuggestion,
                                   dismiss: { typingStickers.dismissed = true })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            // Container spacing below the stack spacing: the discs and the field stay separate shapes instead of melting together.
            GlassEffectContainer(spacing: 4) {
                HStack(alignment: .bottom, spacing: 8) {
                    // Extra room: with Dictation on, macOS shows its glass mic chip just left of the insertion point,
                    // which reaches past the field's leading edge.
                    plusMenu
                        .padding(.trailing, 8)
                    field
                    sendControl
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .animation(.snappy(duration: 0.18), value: suggestionsOpen)
        .animation(.snappy(duration: 0.18), value: stickerStripOpen)
        .animation(.snappy(duration: 0.18), value: replyTo?.id)
        .animation(.snappy(duration: 0.18), value: staged.map(\.id))
        .animation(.snappy(duration: 0.18), value: typingName)
        .animation(.snappy(duration: 0.18), value: uploadingCount > 0)
        .onChange(of: staged.count) { old, now in if now > old { handle.focus() } }
        .onAppear {
            ComposerTextView.accent = NSColor(ChatPalette.accent(accentStored))
            handle.conversationId = conversationId
            installPasteKeyMonitor()
        }
        .onChange(of: conversationId) { _, now in
            handle.conversationId = now
        }
        .onDisappear {
            removePasteKeyMonitor()
        }
        .onChange(of: accentStored) { _, now in ComposerTextView.accent = NSColor(ChatPalette.accent(now)) }
        .task(id: query) { await loadCandidates() }
        .task(id: draft) { await loadStickerSuggestions() }
        .onChange(of: draft) { _, _ in typingStickers.dismissed = false }
        .sheet(isPresented: $showPollCreate) { PollCreateSheet(conversationId: conversationId) }
        .sheet(isPresented: $showMyCard) { MyCardSheet(conversationId: conversationId, conversationName: name) }
        .sheet(isPresented: Binding(get: { reminderInfo != nil }, set: { if !$0 { reminderInfo = nil } })) {
            if let reminderInfo { ReminderComposeSheet(conversationId: conversationId, info: reminderInfo) }
        }
        .sheet(item: $spreadsheetPaste) { payload in
            SpreadsheetPasteChoiceSheet(
                conversationId: conversationId,
                conversationName: name,
                payload: payload,
                onInsertTextToDraft: { inserted in
                    if handle.textView != nil {
                        handle.insertPlainText(inserted)
                    } else {
                        draft = draft.isEmpty ? inserted : draft + "\n" + inserted
                    }
                },
                onSent: {}
            )
        }
        .onDrop(of: [.fileURL, .png, .tiff, .pdf, .image], isTargeted: $isDropTargeted) { providers in
            engine.handleDroppedProviders(providers, in: conversationId)
        }
    }

    // MARK: Parts

    /// The official toolbar's attachments (photo / video, file, screenshot, my contact card) and its "…" menu (reminder, poll),
    /// then sticker and the system emoji palette.
    private var plusMenu: some View {
        Menu {
            if !conversationId.isEmpty {
                Button("Ảnh hoặc Video", systemImage: "photo.on.rectangle") { pickAttachments(as: .media) }
                Button("Tệp", systemImage: "paperclip") { pickAttachments(as: .files) }
                Menu("Chụp màn hình", systemImage: "camera.viewfinder") {
                    Button("Chụp kèm cửa sổ \(AppBrand.name)") { engine.startScreenCapture(in: conversationId, withOlaz: true) }
                    Button("Chụp không kèm cửa sổ \(AppBrand.name)") { engine.startScreenCapture(in: conversationId, withOlaz: false) }
                }
                Button("Danh thiếp của tôi", systemImage: "person.crop.rectangle") { showMyCard = true }
                Divider()
                Button("Nhắc hẹn", systemImage: "alarm") { openReminder() }
            }
            if isGroup && !conversationId.isEmpty {
                Button("Bình chọn", systemImage: "chart.bar.doc.horizontal") { showPollCreate = true }
            }
            if !conversationId.isEmpty {
                Button("Sticker", systemImage: "face.dashed") { showStickers = true }
            }
            Button("Emoji", systemImage: "face.smiling") { NSApp.orderFrontCharacterPalette(nil) }
        } label: {
            // Drawn like the send disc: a glass-styled Menu renders an extra pull-down segment beside the button.
            CenteredSymbol("plus", size: 16, weight: .semibold, box: 22)
                .frame(width: 36, height: 36)
                .contentShape(Circle())
                .glassEffect(.regular.interactive(), in: Circle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .help("Thêm")
        .accessibilityLabel("Thêm")
        .tourAnchor(.composer, arrowEdge: .top)
    }

    private var field: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ComposerTextView(
                text: $draft, mentions: $mentions, height: $textHeight, focusTick: focusTick,
                handle: handle, mentionsEnabled: isGroup,
                hasStagedImages: !staged.isEmpty,
                onMentionQuery: { query = $0 },
                onSuggestionKey: suggestionKey,
                onPasteboardAction: handlePasteboard,
                onDropTargetChange: { isDropTargeted = $0 },
                onSend: send)
                .frame(height: textHeight)
                .overlay(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text("Tin nhắn tới \(name)")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.vertical, 10)
            if !conversationId.isEmpty {
                Button {
                    showStickers.toggle()
                } label: {
                    Image(systemName: "face.smiling").font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 4)
                .help("Gửi Sticker")
                .accessibilityLabel("Gửi Sticker")
                .popover(isPresented: $showStickers, arrowEdge: .top) {
                    StickerPicker(conversationId: conversationId) { showStickers = false }
                }
            }
        }
        .padding(.leading, 14).padding(.trailing, 6)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 19, style: .continuous)
                    .strokeBorder(.tint, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
            }
        }
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 19, style: .continuous))
    }

    /// 👍 while the box is empty, the arrow once there is something to send; the two glass discs morph into each other.
    private var sendControl: some View {
        Group {
            if isEmpty {
                Button(action: sendLike) {
                    Text("👍").font(.system(size: 18)).frame(width: 36, height: 36).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Circle())
                .glassEffectID("send", in: glassNamespace)
                .help("Gửi biểu tượng thích")
                .accessibilityLabel("Gửi biểu tượng thích")
            } else {
                Button(action: send) {
                    CenteredSymbol("arrow.up", size: 15, weight: .bold, box: 22).foregroundStyle(.white)
                        .frame(width: 36, height: 36).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(ChatPalette.accent(accentStored)).interactive(), in: Circle())
                .glassEffectID("send", in: glassNamespace)
                .help("Gửi")
                .accessibilityLabel("Gửi tin nhắn")
            }
        }
        .animation(.bouncy(duration: 0.3), value: isEmpty)
    }

    // MARK: Attachments, reminder

    private func pickAttachments(as kind: AttachmentKind) {
        guard !conversationId.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        switch kind {
        case .media:
            panel.title = "Chọn Ảnh hoặc Video"
            panel.canChooseDirectories = false
            panel.allowedContentTypes = [.image, .movie]
        case .files:
            panel.title = "Chọn Tệp hoặc Thư mục"
            panel.canChooseDirectories = true
            panel.treatsFilePackagesAsDirectories = false
            panel.allowedContentTypes = [.item]
        }
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            sendAttachments(panel.urls, as: kind)
        }
    }

    private func installPasteKeyMonitor() {
        guard pasteMonitor == nil else { return }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isPasteShortcut = (flags == .command || flags == [.command, .shift])
                && (event.keyCode == 9 || event.charactersIgnoringModifiers?.lowercased() == "v")
            let activeConvId = handle.conversationId.isEmpty ? conversationId : handle.conversationId
            guard isPasteShortcut, !activeConvId.isEmpty else { return event }
            guard !showPollCreate, !showMyCard, reminderInfo == nil, spreadsheetPaste == nil else { return event }
            guard let window = handle.textView?.window ?? NSApp.keyWindow,
                  window.isKeyWindow,
                  window.attachedSheet == nil,
                  engine.composerConfirm == nil,
                  engine.screenshotShare == nil else { return event }

            // Do not hijack ⌘V when the user is editing another text field (e.g. sidebar search or quick switcher).
            if let responderTV = window.firstResponder as? NSTextView,
               responderTV !== handle.textView,
               responderTV.isEditable {
                return event
            }

            if handlePasteboard(NSPasteboard.general, isDrop: false, targetConversationId: activeConvId) {
                return nil
            }

            // If focus was outside FieldTextView (e.g. conversation list or message list) and the clipboard holds plain text,
            // focus the composer and insert the text directly.
            if window.firstResponder !== handle.textView,
               let plain = NSPasteboard.general.string(forType: .string),
               !plain.isEmpty {
                if handle.textView != nil {
                    handle.insertPlainText(plain)
                } else {
                    draft += plain
                }
                return nil
            }
            return event
        }
    }

    private func removePasteKeyMonitor() {
        if let monitor = pasteMonitor {
            NSEvent.removeMonitor(monitor)
            pasteMonitor = nil
        }
    }

    private func handlePasteboard(_ pasteboard: NSPasteboard, isDrop: Bool) -> Bool {
        let activeConvId = handle.conversationId.isEmpty ? conversationId : handle.conversationId
        return handlePasteboard(pasteboard, isDrop: isDrop, targetConversationId: activeConvId)
    }

    private func handlePasteboard(_ pasteboard: NSPasteboard, isDrop: Bool, targetConversationId: String) -> Bool {
        guard !targetConversationId.isEmpty else { return false }
        if !isDrop {
            let now = Date().timeIntervalSinceReferenceDate
            let cc = pasteboard.changeCount
            if let guardEntry = lastPasteGuard, guardEntry.changeCount == cc, now - guardEntry.time < 0.15 {
                return true
            }
        }
        let inspected = ClipboardPasteContent.inspect(pasteboard)
        switch inspected {
        case .files(let urls):
            if !isDrop { lastPasteGuard = (pasteboard.changeCount, Date().timeIntervalSinceReferenceDate) }
            EngineLog.shared.write("pasteboard \(isDrop ? "drop" : "paste") → files(\(urls.count))")
            sendAttachments(urls, as: .media, to: targetConversationId)
            return true
        case .spreadsheetOrRichImageAndText(let imageData, let imageSize, let text):
            if !isDrop { lastPasteGuard = (pasteboard.changeCount, Date().timeIntervalSinceReferenceDate) }
            EngineLog.shared.write("pasteboard \(isDrop ? "drop" : "paste") → spreadsheet(\(imageData.count)B)")
            spreadsheetPaste = SpreadsheetPastePayload(imageData: imageData, imageSize: imageSize, text: text)
            return true
        case .imageOnly(let imageData, _):
            if let fileURL = ZaloEngine.writeTemporaryPasteImage(imageData, prefix: isDrop ? "dropped-image" : "clipboard") {
                if !isDrop { lastPasteGuard = (pasteboard.changeCount, Date().timeIntervalSinceReferenceDate) }
                EngineLog.shared.write("pasteboard \(isDrop ? "drop" : "paste") → image(\(imageData.count)B)")
                if isDrop {
                    sendAttachments([fileURL], as: .media, to: targetConversationId)
                } else {
                    engine.stageImageFile(fileURL, image: NSImage(data: imageData), in: targetConversationId)
                    handle.focus()
                }
                return true
            }
            return false
        case .plainText, .empty:
            return false
        }
    }

    /// The picked files go to the conversation they were picked in, even if another one is open by the time they are sent.
    private func sendAttachments(_ urls: [URL], as kind: AttachmentKind, to overrideTarget: String? = nil) {
        let target = overrideTarget ?? (handle.conversationId.isEmpty ? conversationId : handle.conversationId)
        guard !target.isEmpty else { return }
        uploadingCount += 1
        Task {
            defer { uploadingCount = max(0, uploadingCount - 1) }
            let outcome = kind == .media ? await engine.sendMedia(urls, to: target) : await engine.sendFiles(urls, to: target)
            engine.report(outcome, in: target)
        }
    }

    /// The chat-bar gate decides on click, as the official menu item does (its warning when I may not create one here).
    private func openReminder() {
        let target = conversationId
        Task {
            guard let info = await engine.reminderComposeInfo(for: target) else {
                CardActionCenter.shared.show("Chưa đọc được thông tin nhắc hẹn từ Zalo. Hãy thử lại sau giây lát.", in: target)
                return
            }
            guard info.allowed else {
                CardActionCenter.shared.show(info.text.isEmpty ? "Không thể tạo nhắc hẹn trong cuộc trò chuyện này." : info.text, in: target)
                return
            }
            if engine.openConversationId == target { reminderInfo = info }
        }
    }

    // MARK: @mention suggestions

    /// Debounced lookup against the official member list; stale answers are discarded.
    private func loadCandidates() async {
        guard isGroup, let query else { candidates = []; return }
        try? await Task.sleep(for: .milliseconds(40))
        guard !Task.isCancelled else { return }
        let found = await engine.mentionCandidates(in: conversationId, query: query.text,
                                                   excluding: mentions.map(\.uid))
        guard !Task.isCancelled else { return }
        candidates = found
        selected = 0
    }

    private func pick(_ candidate: MentionCandidate) {
        guard let range = query?.range else { return }
        handle.insertMention(candidate, replacing: range)
        query = nil
        candidates = []
    }

    // MARK: Sticker suggestions

    /// Official `_handleSuggestTextChange` → `_checkStickerSuggestion` (debounced): the text is matched by the official suggestion logic. Swift only
    /// skips what can never match (blank, over the 200 UTF-16 units JS accepts); length, "#…" and line rules stay in the adapter. While the setting is
    /// off, or while an IME composition is open, nothing is asked.
    private func loadStickerSuggestions() async {
        let text = draft
        let state = StickerSuggestState.shared
        guard !conversationId.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf16.count <= 200, !suggestionsOpen else {
            typingStickers.clear()
            return
        }
        await state.loadIfNeeded(from: engine)
        guard state.setting?.enabled == true else { typingStickers.clear(); return }
        try? await Task.sleep(for: .milliseconds(state.delay))
        // Marked text is a half-typed syllable: wait for the composition to end (a bounded wait), never ask about it.
        var waits = 0
        while handle.textView?.hasMarkedText() == true, waits < 20, !Task.isCancelled {
            waits += 1
            try? await Task.sleep(for: .milliseconds(300))
        }
        guard !Task.isCancelled else { return }
        guard handle.textView?.hasMarkedText() != true, draft == text, !typingStickers.isHeld(text) else { typingStickers.clear(); return }
        let found = await engine.typingStickerSuggestions(in: conversationId, text: text)
        guard !Task.isCancelled else { return }
        typingStickers.offer(found, for: text)
    }

    /// Official `_sendSuggestionSticker`: the box is cleared first (the typed text is not sent), then the sticker goes out with the suggestion
    /// source. A send that fails gives the text back, after whatever was typed meanwhile.
    private func sendSuggestion(_ sticker: StickerEntry, index: Int) {
        // A click on a strip that no longer matches the text, or during an IME composition (the draft would not be what the user sees), is ignored.
        guard sendingSuggestion == nil, stickerStripOpen, handle.textView?.hasMarkedText() != true else { return }
        let target = conversationId
        guard engine.openConversationId == target else {
            CardActionCenter.shared.show(StickerNotice.notReady, in: target)
            return
        }
        let taken = typingStickers.take(ComposerDraft(text: draft, mentions: mentions))
        sendingSuggestion = sticker.id
        draft = ""
        mentions = []
        Task {
            let outcome = await engine.sendSticker(sticker, in: target, source: .suggestion, typed: taken.typed, index: index)
            sendingSuggestion = nil
            switch outcome {
            case .done: break
            case .pending(let text):
                // No answer: the sticker may be on its way. The text is not given back (nothing invites a second send), the strip stays away
                // for that text, and the notice says to check the conversation.
                typingStickers.hold(taken.typed)
                CardActionCenter.shared.show(text, in: target)
            case .locked(let text), .failed(let text), .unsupported(let text):
                // The composer for this conversation takes the text back (ChatView `restoreFailedDraft`, also when the view is gone). Silently:
                // this toast is the one message about this failure.
                engine.failedDrafts.stash(taken.draft, for: target, silent: true)
                CardActionCenter.shared.show(text, in: target)
            default: break
            }
        }
    }

    /// Keys the text view forwards while the popover is open; returns whether it consumed the key.
    private func suggestionKey(_ key: MentionKey) -> Bool {
        // Esc hides the sticker suggestions (they take no other keys: Return keeps sending the text).
        if !suggestionsOpen, stickerStripOpen, key == .cancel { typingStickers.dismissed = true; return true }
        guard suggestionsOpen else { return false }
        switch key {
        case .down: selected = (selected + 1) % candidates.count
        case .up: selected = (selected - 1 + candidates.count) % candidates.count
        case .confirm: pick(candidates[min(selected, candidates.count - 1)])
        case .cancel: query = nil; candidates = []
        }
        return true
    }
}

// MARK: - @mention popover

/// The "@…" being typed: `range` covers the "@" and everything typed after it.
struct MentionQuery: Equatable {
    var range: NSRange
    var text: String
}

enum MentionKey { case up, down, confirm, cancel }

private struct MentionSuggestions: View {
    let candidates: [MentionCandidate]
    @Binding var selected: Int
    let pick: (MentionCandidate) -> Void

    private let rowHeight: CGFloat = 38

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                        row(candidate, isSelected: index == selected)
                            .id(candidate.id)
                            .onHover { inside in if inside { selected = index } }
                    }
                }
                .padding(6)
            }
            .scrollIndicators(.hidden)
            .onChange(of: selected) { _, now in
                guard candidates.indices.contains(now) else { return }
                withAnimation(.snappy(duration: 0.12)) { proxy.scrollTo(candidates[now].id) }
            }
        }
        .frame(height: min(CGFloat(candidates.count) * (rowHeight + 2) + 12, 6.5 * (rowHeight + 2)))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Gợi ý nhắc thành viên")
    }

    private func row(_ candidate: MentionCandidate, isSelected: Bool) -> some View {
        Button { pick(candidate) } label: {
            HStack(spacing: 10) {
                if candidate.isAll {
                    Image(systemName: "at")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(.tint))
                } else {
                    RemoteAvatar(url: candidate.avatar, name: candidate.name, size: 26)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(candidate.isAll ? "Tất cả" : candidate.name)
                        .font(.system(size: 13.5, weight: .medium))
                        .lineLimit(1)
                    if candidate.isAll {
                        Text("Nhắc tất cả thành viên")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: rowHeight)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(TintShapeStyle().opacity(0.16)) : AnyShapeStyle(Color.clear)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(candidate.isAll ? "Nhắc tất cả thành viên" : "Nhắc \(candidate.name)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Lets SwiftUI insert a chosen mention or pasted plain text into the NSTextView.
@MainActor
final class ComposerHandle {
    weak var textView: NSTextView?
    var conversationId: String = ""

    func insertMention(_ candidate: MentionCandidate, replacing range: NSRange) {
        guard let tv = textView, let storage = tv.textStorage,
              NSMaxRange(range) <= storage.length,
              (storage.string as NSString).character(at: range.location) == 0x40 else { return }
        let label = "@" + candidate.name.replacingOccurrences(of: "\n", with: " ")
        let token = MentionToken(uid: candidate.isAll ? "-1" : candidate.id, label: label, isAll: candidate.isAll)
        let inserted = NSMutableAttributedString(string: label, attributes: ComposerTextView.tokenAttributes(token))
        inserted.append(NSAttributedString(string: " ", attributes: ComposerTextView.baseAttributes))
        guard tv.shouldChangeText(in: range, replacementString: inserted.string) else { return }
        storage.replaceCharacters(in: range, with: inserted)
        tv.didChangeText()
        tv.setSelectedRange(NSRange(location: range.location + inserted.length, length: 0))
        tv.window?.makeFirstResponder(tv)
    }

    func focus() {
        guard let tv = textView else { return }
        tv.window?.makeFirstResponder(tv)
        DispatchQueue.main.async { [weak tv] in
            guard let tv, let window = tv.window, window.attachedSheet == nil else { return }
            window.makeFirstResponder(tv)
        }
    }

    func insertPlainText(_ text: String) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let sel = tv.selectedRange()
        let start = min(max(0, sel.location), storage.length)
        let len = min(max(0, sel.length), max(0, storage.length - start))
        let range = NSRange(location: start, length: len)
        let inserted = NSAttributedString(string: text, attributes: ComposerTextView.baseAttributes)
        guard tv.shouldChangeText(in: range, replacementString: inserted.string) else { return }
        storage.replaceCharacters(in: range, with: inserted)
        tv.didChangeText()
        tv.setSelectedRange(NSRange(location: range.location + inserted.length, length: 0))
        tv.window?.makeFirstResponder(tv)
    }
}

/// Inline preview strip inside `ChatComposer` for images pasted with ⌘V.
struct StagedImageStrip: View {
    let images: [StagedImage]
    let remove: (UUID) -> Void
    let clearAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.tint)
                Text("Đính kèm \(images.count) ảnh")
                    .font(.system(size: 11.5, weight: .semibold))
                Text("• Nhấn Enter để gửi kèm tin nhắn")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button(images.count > 1 ? "Xóa tất cả" : "Xóa", systemImage: "xmark", action: clearAll)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(images.count > 1 ? "Xóa tất cả ảnh đính kèm" : "Xóa ảnh đính kèm")
            }
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(Array(images.enumerated()), id: \.element.id) { index, item in
                        ZStack(alignment: .topTrailing) {
                            Image(nsImage: item.image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 68, height: 68)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                                )
                                .accessibilityLabel("Ảnh đính kèm \(index + 1)")
                            Button {
                                remove(item.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 15))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.65))
                            }
                            .buttonStyle(.plain)
                            .offset(x: 4, y: -4)
                            .help("Bỏ ảnh này")
                            .accessibilityLabel("Bỏ ảnh \(index + 1)")
                        }
                        .padding(.top, 4)
                        .padding(.trailing, 4)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Attribute payload of an atomic mention inside the composer text.
final class MentionToken: NSObject {
    let uid: String
    let label: String
    let isAll: Bool
    init(uid: String, label: String, isAll: Bool) { self.uid = uid; self.label = label; self.isAll = isAll }
}

extension NSAttributedString.Key {
    static let zaloMention = NSAttributedString.Key("app.olaz.mention")
}

// MARK: - NSTextView-backed field

/// Multi-line field that respects the caret and IME composition (Vietnamese Telex):
/// Return sends only when there is no marked text; Shift/Option+Return inserts a newline
/// at the caret.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var mentions: [Mention]
    @Binding var height: CGFloat
    var focusTick: Int
    var handle: ComposerHandle? = nil
    var mentionsEnabled = false
    var hasStagedImages = false
    var onMentionQuery: (MentionQuery?) -> Void = { _ in }
    /// While the popover is open: ↑ ↓ Return/Tab Esc. Returns true when consumed.
    var onSuggestionKey: (MentionKey) -> Bool = { _ in false }
    /// Handles pasteboard attachments/spreadsheets on `⌘V` or drag-and-drop; returns `true` when consumed.
    var onPasteboardAction: (NSPasteboard, Bool) -> Bool = { _, _ in false }
    var onDropTargetChange: (Bool) -> Void = { _ in }
    var onSend: () -> Void

    static let font = NSFont.systemFont(ofSize: 14)
    static let baseAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
    /// Color of mention tokens: the accent picked in Settings (set by `ChatComposer`; an `NSColor` cannot read `.tint`).
    static var accent = NSColor(ZaloTheme.blue)
    static func tokenAttributes(_ token: MentionToken) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 14, weight: .semibold),
         .foregroundColor: accent,
         .backgroundColor: accent.withAlphaComponent(0.12),
         .zaloMention: token]
    }
    /// Sets text set from outside (restored draft) together with its mentions, rebuilding their token styling
    /// so `syncMentions` publishes them back instead of wiping them. Offsets that no longer read "@…" are skipped.
    static func setContent(_ tv: NSTextView, text: String, mentions: [Mention]) {
        tv.string = text
        tv.typingAttributes = baseAttributes
        guard let storage = tv.textStorage, !mentions.isEmpty else { return }
        let ns = text as NSString
        for m in mentions where m.pos >= 0 && m.len > 1 && m.pos + m.len <= ns.length && ns.character(at: m.pos) == 0x40 {
            let range = NSRange(location: m.pos, length: m.len)
            storage.setAttributes(tokenAttributes(MentionToken(uid: m.uid, label: ns.substring(with: range), isAll: m.isAll)), range: range)
        }
    }
    static var lineHeight: CGFloat { ceil(font.ascender - font.descender + font.leading) }
    private static let maxLines: CGFloat = 6

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = FieldTextView()
        tv.delegate = context.coordinator
        tv.font = Self.font
        tv.textColor = .labelColor
        tv.drawsBackground = false
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.setAccessibilityLabel("Nhập tin nhắn")
        Self.setContent(tv, text: text, mentions: mentions)
        context.coordinator.parent.handle?.textView = tv
        tv.hasStagedImages = hasStagedImages
        tv.onWidthChange = { [weak coordinator = context.coordinator, weak tv] in
            guard let tv else { return }
            coordinator?.remeasure(tv)
        }
        tv.onPasteboardAction = { [weak coordinator = context.coordinator] pb, isDrop in
            coordinator?.parent.onPasteboardAction(pb, isDrop) ?? false
        }
        tv.onDropTargetChange = { [weak coordinator = context.coordinator] targeted in
            coordinator?.parent.onDropTargetChange(targeted)
        }
        tv.onSuggestionKey = { [weak coordinator = context.coordinator] key in
            coordinator?.parent.onSuggestionKey(key) ?? false
        }
        tv.onSend = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onSend()
        }

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.hasHorizontalScroller = false
        scroll.documentView = tv
        context.coordinator.lastFocusTick = focusTick
        DispatchQueue.main.async { [weak tv] in tv?.window?.makeFirstResponder(tv) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? FieldTextView else { return }
        handle?.textView = tv
        tv.hasStagedImages = hasStagedImages
        if tv.string != text, tv.hasMarkedText() {
            // IME composition in progress: keep the external text until it is committed (`textDidChange`).
            context.coordinator.deferExternal(base: tv.string, text: text, mentions: mentions)
        } else if tv.string != text {
            context.coordinator.pending = nil
            Self.setContent(tv, text: text, mentions: mentions)
            tv.undoManager?.removeAllActions()
            DispatchQueue.main.async { [weak coordinator = context.coordinator, weak tv] in
                guard let tv else { return }
                coordinator?.syncMentions(tv)
                coordinator?.refreshQuery(tv)
            }
        }
        if context.coordinator.lastFocusTick != focusTick {
            context.coordinator.lastFocusTick = focusTick
            DispatchQueue.main.async { [weak tv] in tv?.window?.makeFirstResponder(tv) }
        }
        context.coordinator.remeasure(tv)
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        var lastFocusTick = 0
        init(_ parent: ComposerTextView) { self.parent = parent }

        /// Text set from outside (restored draft) while composing: `base` is what the field held then.
        var pending: (base: String, text: String, mentions: [Mention])?

        func deferExternal(base: String, text: String, mentions: [Mention]) {
            pending = (pending?.base ?? base, text, mentions)
        }

        /// After the composition ended: the external text wins, but whatever was typed since goes first
        /// (external text is then `base` + restored tail, so only the tail is appended).
        private func applyPending(_ tv: NSTextView) {
            guard let p = pending else { return }
            pending = nil
            let current = tv.string
            let baseLen = (p.base as NSString).length, currentLen = (current as NSString).length
            var text = p.text, mentions = p.mentions
            if current != p.base, p.text.hasPrefix(p.base) {
                text = current + (p.text as NSString).substring(from: baseLen)
                mentions = currentMentions(tv) + p.mentions.filter { $0.pos >= baseLen }.map {
                    Mention(uid: $0.uid, pos: $0.pos + currentLen - baseLen, len: $0.len, isAll: $0.isAll)
                }
            }
            ComposerTextView.setContent(tv, text: text, mentions: mentions)
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            if pending != nil {
                if tv.hasMarkedText() { remeasure(tv); return }
                applyPending(tv)
            }
            sanitizeTokens(tv)
            if parent.text != tv.string { parent.text = tv.string }
            syncMentions(tv)
            refreshQuery(tv)
            remeasure(tv)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            // Typing next to a mention must never extend it.
            tv.typingAttributes = ComposerTextView.baseAttributes
            refreshQuery(tv)
        }

        /// A mention is atomic: any edit touching it replaces/deletes the whole token.
        func textView(_ tv: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            guard let storage = tv.textStorage, storage.length > 0, !tv.hasMarkedText() else { return true }
            var expanded = range
            var touched = false
            storage.enumerateAttribute(.zaloMention, in: NSRange(location: 0, length: storage.length)) { value, tokenRange, _ in
                guard value != nil else { return }
                let hits = range.length == 0
                    ? range.location > tokenRange.location && range.location < NSMaxRange(tokenRange)
                    : NSIntersectionRange(range, tokenRange).length > 0
                if hits { expanded = NSUnionRange(expanded, tokenRange); touched = true }
            }
            guard touched, expanded.location != NSNotFound else { return true }
            let replacement = NSAttributedString(string: replacementString ?? "", attributes: ComposerTextView.baseAttributes)
            guard tv.shouldChangeText(in: expanded, replacementString: replacement.string) else { return false }
            storage.replaceCharacters(in: expanded, with: replacement)
            tv.didChangeText()
            tv.setSelectedRange(NSRange(location: expanded.location + replacement.length, length: 0))
            return false
        }

        /// Drops mention styling from runs that no longer read exactly "@Name".
        private func sanitizeTokens(_ tv: NSTextView) {
            guard let storage = tv.textStorage, storage.length > 0 else { return }
            var broken: [NSRange] = []
            storage.enumerateAttribute(.zaloMention, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                guard let token = value as? MentionToken else { return }
                if (storage.string as NSString).substring(with: range) != token.label { broken.append(range) }
            }
            guard !broken.isEmpty else { return }
            storage.beginEditing()
            for range in broken {
                storage.removeAttribute(.zaloMention, range: range)
                storage.setAttributes(ComposerTextView.baseAttributes, range: range)
            }
            storage.endEditing()
        }

        /// Publishes the current tokens as official-style mentions (UTF-16 offsets).
        func syncMentions(_ tv: NSTextView) {
            let found = currentMentions(tv)
            if parent.mentions != found { parent.mentions = found }
        }

        private func currentMentions(_ tv: NSTextView) -> [Mention] {
            guard let storage = tv.textStorage, storage.length > 0 else { return [] }
            var found: [Mention] = []
            storage.enumerateAttribute(.zaloMention, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                if let token = value as? MentionToken {
                    found.append(Mention(uid: token.uid, pos: range.location, len: range.length, isAll: token.isAll))
                }
            }
            return found
        }

        /// "@query" ending at the caret: "@" at the start or after whitespace, not inside a token.
        func refreshQuery(_ tv: NSTextView) {
            guard parent.mentionsEnabled else { return }
            var result: MentionQuery?
            let selection = tv.selectedRange()
            if selection.length == 0, let storage = tv.textStorage, selection.location <= storage.length {
                let ns = storage.string as NSString
                var index = selection.location
                let floor = max(0, selection.location - 40)
                while index > floor {
                    let unit = ns.character(at: index - 1)
                    if unit == 0x0A { break }
                    if unit == 0x40 {
                        let at = index - 1
                        let startsWord = at == 0 || CharacterSet.whitespacesAndNewlines.contains(Unicode.Scalar(ns.character(at: at - 1)) ?? "x")
                        let insideToken = storage.attribute(.zaloMention, at: at, effectiveRange: nil) != nil
                        if startsWord, !insideToken {
                            let range = NSRange(location: at, length: selection.location - at)
                            let typed = ns.substring(with: range).dropFirst()
                            if !typed.hasPrefix(" ") { result = MentionQuery(range: range, text: String(typed)) }
                        }
                        break
                    }
                    index -= 1
                }
            }
            if lastQuery != result {
                lastQuery = result
                parent.onMentionQuery(result)
            }
        }
        private var lastQuery: MentionQuery?

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let isReturn = selector == #selector(NSResponder.insertNewline(_:))
                || selector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))
                || selector == #selector(NSResponder.insertLineBreak(_:))
            switch selector {
            case #selector(NSResponder.moveUp(_:)): if parent.onSuggestionKey(.up) { return true }
            case #selector(NSResponder.moveDown(_:)): if parent.onSuggestionKey(.down) { return true }
            case #selector(NSResponder.insertTab(_:)): if parent.onSuggestionKey(.confirm) { return true }
            case #selector(NSResponder.cancelOperation(_:)): if parent.onSuggestionKey(.cancel) { return true }
            default:
                if isReturn {
                    let mods = NSApp.currentEvent?.modifierFlags ?? []
                    if !mods.contains(.shift), !mods.contains(.option), !textView.hasMarkedText(),
                       parent.onSuggestionKey(.confirm) { return true }
                }
            }
            guard isReturn else { return false }
            let mods = NSApp.currentEvent?.modifierFlags ?? []
            if mods.contains(.shift) || mods.contains(.option) {
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            // Return confirming IME composition never reaches here, but be defensive.
            if textView.hasMarkedText() {
                guard parent.hasStagedImages else { return false }
                textView.inputContext?.discardMarkedText()
                textView.unmarkText()
                textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
            }
            parent.onSend()
            return true
        }

        func remeasure(_ tv: NSTextView) {
            guard let lm = tv.layoutManager, let container = tv.textContainer else { return }
            lm.ensureLayout(for: container)
            let line = ComposerTextView.lineHeight
            let used = lm.usedRect(for: container).height
            let h = min(max(line, ceil(used)), line * ComposerTextView.maxLines)
            if abs(parent.height - h) > 0.5 {
                DispatchQueue.main.async { [weak self] in self?.parent.height = h }
            }
        }
    }

    final class FieldTextView: NSTextView {
        var onWidthChange: (() -> Void)?
        var onPasteboardAction: ((NSPasteboard, Bool) -> Bool)?
        var onDropTargetChange: ((Bool) -> Void)?
        var onSuggestionKey: ((MentionKey) -> Bool)?
        var onSend: (() -> Void)?
        var hasStagedImages = false
        private var keyMonitor: Any?

        override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
            var types = super.readablePasteboardTypes
            let extra = ClipboardPasteContent.supportedImagePasteboardTypes + [
                .fileURL,
                .tabularText,
                NSPasteboard.PasteboardType("public.html")
            ]
            for type in extra where !types.contains(type) {
                types.append(type)
            }
            return types
        }

        override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
            if item.action == #selector(NSText.paste(_:))
                || item.action == #selector(NSTextView.pasteAsPlainText(_:))
                || item.action == #selector(NSTextView.pasteAsRichText(_:)) {
                return isEditable && ClipboardPasteContent.hasPasteableContent(NSPasteboard.general)
            }
            return super.validateUserInterfaceItem(item)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
                self.keyMonitor = nil
            }
            guard let window else { return }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let consumed = MainActor.assumeIsolated { self?.handleWindowKeyDown(event) ?? false }
                return consumed ? nil : event
            }
            guard window.attachedSheet == nil else { return }
            if let responderTV = window.firstResponder as? NSTextView, responderTV.isEditable { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let win = self.window, win.attachedSheet == nil else { return }
                if let responderTV = win.firstResponder as? NSTextView, responderTV.isEditable { return }
                win.makeFirstResponder(self)
            }
        }

        override func keyDown(with event: NSEvent) {
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if (event.keyCode == 36 || event.keyCode == 76), flags.isEmpty {
                if !hasMarkedText() {
                    if onSuggestionKey?(.confirm) == true { return }
                    onSend?()
                    return
                } else if hasStagedImages {
                    inputContext?.discardMarkedText()
                    unmarkText()
                    delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: self))
                    if onSuggestionKey?(.confirm) == true { return }
                    onSend?()
                    return
                }
            }
            super.keyDown(with: event)
        }

        private func handleWindowKeyDown(_ event: NSEvent) -> Bool {
            guard isEditable,
                  !isHiddenOrHasHiddenAncestor,
                  let window = self.window,
                  event.window === window,
                  window.attachedSheet == nil else {
                return false
            }
            if let other = window.firstResponder as? NSTextView, other !== self, other.isEditable {
                return false
            }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard (event.keyCode == 36 || event.keyCode == 76), flags.isEmpty else {
                return false
            }
            if window.firstResponder === self {
                if !hasMarkedText() {
                    if onSuggestionKey?(.confirm) == true { return true }
                    onSend?()
                    return true
                } else if hasStagedImages {
                    inputContext?.discardMarkedText()
                    unmarkText()
                    delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: self))
                    if onSuggestionKey?(.confirm) == true { return true }
                    onSend?()
                    return true
                }
                return false
            }
            if hasStagedImages || !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                window.makeFirstResponder(self)
                if onSuggestionKey?(.confirm) == true { return true }
                onSend?()
                return true
            }
            return false
        }

        override func setFrameSize(_ newSize: NSSize) {
            let changed = abs(newSize.width - frame.width) > 0.5
            super.setFrameSize(newSize)
            if changed { DispatchQueue.main.async { [weak self] in self?.onWidthChange?() } }
        }

        override func paste(_ sender: Any?) {
            if onPasteboardAction?(NSPasteboard.general, false) == true {
                hasStagedImages = true
                return
            }
            super.pasteAsPlainText(sender)
        }

        override func pasteAsPlainText(_ sender: Any?) {
            if onPasteboardAction?(NSPasteboard.general, false) == true {
                hasStagedImages = true
                return
            }
            super.pasteAsPlainText(sender)
        }

        override func pasteAsRichText(_ sender: Any?) {
            if onPasteboardAction?(NSPasteboard.general, false) == true {
                hasStagedImages = true
                return
            }
            super.pasteAsPlainText(sender)
        }

        private func hasAttachmentInDrag(_ sender: NSDraggingInfo) -> Bool {
            let pb = sender.draggingPasteboard
            if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
               urls.contains(where: { $0.isFileURL }) {
                return true
            }
            if pb.availableType(from: ClipboardPasteContent.supportedImagePasteboardTypes) != nil {
                return true
            }
            return false
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            if hasAttachmentInDrag(sender) {
                onDropTargetChange?(true)
                return .copy
            }
            return super.draggingEntered(sender)
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            if hasAttachmentInDrag(sender) {
                return .copy
            }
            return super.draggingUpdated(sender)
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            onDropTargetChange?(false)
            super.draggingExited(sender)
        }

        override func concludeDragOperation(_ sender: NSDraggingInfo?) {
            onDropTargetChange?(false)
            super.concludeDragOperation(sender)
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            onDropTargetChange?(false)
            if hasAttachmentInDrag(sender) {
                let handled = onPasteboardAction?(sender.draggingPasteboard, true) ?? false
                if handled { hasStagedImages = true }
                return handled
            }
            return super.performDragOperation(sender)
        }
    }
}
