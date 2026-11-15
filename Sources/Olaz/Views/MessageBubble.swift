import SwiftUI
import AVFoundation
import AppKit
import UniformTypeIdentifiers

// MARK: - Formatting helpers

enum ChatFormat {
    static let vi = Locale(identifier: "vi_VN")
    static let calendar = Calendar.current

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = vi
        f.setLocalizedDateFormatFromTemplate(format)
        return f
    }
    private static let timeFormatter = formatter("HHmm")
    private static let dayThisYear = formatter("EEEEddMM")
    private static let dayOtherYear = formatter("ddMMyyyy")

    static func time(_ date: Date) -> String { timeFormatter.string(from: date) }

    static func daySeparator(_ date: Date) -> String {
        if calendar.isDateInToday(date) { return "Hôm nay" }
        if calendar.isDateInYesterday(date) { return "Hôm qua" }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: .now)
        return (sameYear ? dayThisYear : dayOtherYear).string(from: date)
    }

    static func clock(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    static func bytes(_ size: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    static func host(_ url: URL?) -> String {
        guard let host = url?.host else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    private final class Box { let value: AttributedString; init(_ v: AttributedString) { value = v } }
    nonisolated(unsafe) private static let linkCache: NSCache<NSString, Box> = {
        let c = NSCache<NSString, Box>(); c.countLimit = 2000; return c
    }()

    /// Link-detected text; cached because `NSDataDetector` is expensive to run per render.
    static func linkified(_ s: String, mine: Bool) -> AttributedString {
        let key = ((mine ? "1" : "0") + s) as NSString
        if let hit = linkCache.object(forKey: key) { return hit.value }
        var out = AttributedString(s)
        if let detector {
            for match in detector.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
                guard let url = match.url, let r = Range(match.range, in: s),
                      let range = Range<AttributedString.Index>(r, in: out) else { continue }
                out[range].link = url
                out[range].underlineStyle = .single
                if mine { out[range].foregroundColor = .white }
            }
        }
        linkCache.setObject(Box(out), forKey: key)
        return out
    }

    /// URL scheme used for clickable @mentions (handled by `MessageRow`, never opened externally).
    static let mentionScheme = "zalomention"

    /// URL scheme used for clickable detected bank-transfer entities (handled by `MessageRow`, never opened externally).
    static let bankScheme = "olazbank"

    /// Link-detected text plus official @mention highlighting. Ranges are the message's
    /// `mentions` (UTF-16 offsets); a range that does not start with "@" is ignored.
    /// Mentions of me (or everyone) get a subtle background.
    static func mentioned(_ s: String, mentions: [Mention], mine: Bool, myId: String?,
                          size: CGFloat = 14, accent: Color = ZaloTheme.blue) -> AttributedString {
        var out = linkified(s, mine: mine)
        guard !mentions.isEmpty else { return out }
        let ns = s as NSString
        for mention in mentions {
            guard mention.pos >= 0, mention.len > 1, mention.pos + mention.len <= ns.length,
                  ns.character(at: mention.pos) == 0x40,
                  let r = Range(NSRange(location: mention.pos, length: mention.len), in: s),
                  let range = Range<AttributedString.Index>(r, in: out) else { continue }
            let aimsAtMe = mention.isAll || (myId != nil && mention.uid == myId)
            out[range].font = .system(size: size, weight: .semibold)
            out[range].foregroundColor = mine ? .white : accent
            if aimsAtMe {
                out[range].backgroundColor = mine ? Color.white.opacity(0.22) : accent.opacity(0.16)
            }
            if !mention.isAll, mention.uid != myId, let url = URL(string: "\(mentionScheme):\(mention.uid)") {
                out[range].link = url
                out[range].underlineStyle = nil
            } else {
                out[range].link = nil
                out[range].underlineStyle = nil
            }
        }
        return out
    }

    /// Formats message text with web links, @mentions, and clickable bank-transfer entities.
    static func formattedText(
        _ s: String,
        mentions: [Mention] = [],
        bankMatches: [BankTransferMatch] = [],
        mine: Bool,
        myId: String?,
        size: CGFloat = 14,
        accent: Color = ZaloTheme.blue
    ) -> AttributedString {
        var out = mentions.isEmpty
            ? linkified(s, mine: mine)
            : mentioned(s, mentions: mentions, mine: mine, myId: myId, size: size, accent: accent)
        guard !bankMatches.isEmpty else { return out }

        for (idx, match) in bankMatches.enumerated() {
            guard let url = URL(string: "\(bankScheme):\(idx)") else { continue }
            for rawRange in [match.accountRange, match.bankRange] {
                guard let attrRange = Range<AttributedString.Index>(rawRange, in: out) else { continue }
                let hasExistingLink = out[attrRange].runs.contains { $0.link != nil }
                guard !hasExistingLink else { continue }
                out[attrRange].link = url
                out[attrRange].underlineStyle = .single
                out[attrRange].foregroundColor = mine ? .white : accent
            }
        }
        return out
    }
}

// MARK: - Row

/// The brand color on a neutral surface, white on my tinted bubble (or the reverse with `onMine: !mine` for a control sitting on a white disc).
private func brandStyle(onMine mine: Bool) -> AnyShapeStyle {
    mine ? AnyShapeStyle(Color.white) : AnyShapeStyle(TintShapeStyle())
}

private extension View {
    /// Carries the coach mark of the tour's "message" step (the newest message of the chat). It sits in a background so the row
    /// keeps its identity when a newer message takes the mark over.
    func messageTourAnchor(_ active: Bool) -> some View {
        background { if active { Color.clear.tourAnchor(.message, arrowEdge: .trailing) } }
    }
}

struct MessageRow: View {
    let message: ChatMessage
    let isGroup: Bool
    let firstInGroup: Bool
    let lastInGroup: Bool
    /// Status line is shown only under my most recent message.
    let showStatus: Bool
    /// The chat's newest message: it carries the coach mark of the tour.
    var isNewest = false
    var onReply: (ChatMessage) -> Void
    var onReact: (String, ChatMessage) -> Void

    @Environment(ZaloEngine.self) private var engine
    @Environment(\.olazTextScale) private var textScale
    @AppStorage(OlazPrefs.accent) private var accentStored = OlazAccent.blue.rawValue
    @AppStorage(OlazPrefs.wallpaper) private var wallpaperStored = ChatWallpaper.none.rawValue
    @State private var hovering = false
    @State private var showsReactionPicker = false
    @State private var selectedBankMatch: BankTransferMatch?
    private static let reactionEmojis = ["❤️", "👍", "😆", "😮", "😢", "😡"]

    private var mine: Bool { message.isMine }
    private var hasWallpaper: Bool { wallpaperStored != ChatWallpaper.none.rawValue }
    private var translationStore: MessageTranslationStore { .shared }
    private var translationState: MessageTranslationState {
        message.translatableText == nil ? .idle : translationStore.state(for: message)
    }
    private func scaled(_ size: CGFloat) -> CGFloat { size * textScale }
    private func toggleTranslation() {
        if translationState.isActiveOrVisible {
            translationStore.collapse(conversationId: message.conversationId, messageId: message.id)
        } else {
            translationStore.translate(message: message)
        }
    }

    var body: some View {
        switch message.kind {
        case .system:
            NoticeRow(text: message.text)
                .messageTourAnchor(isNewest)
        case .notice(let symbol, let text):
            NoticeRow(symbol: symbol, text: text, buttons: message.cardButtons)
                .cardActionHost(message)
                .messageTourAnchor(isNewest)
        case .ecard(let card):
            ECardView(card: card, buttons: message.cardButtons, suggestsStickers: message.suggestsStickers)
                .cardActionHost(message)
                .accessibilityLabel(message.text)
                .messageTourAnchor(isNewest)
        default:
            bubbleRow
        }
    }

    private var showsName: Bool { isGroup && !mine && firstInGroup }

    private var bubbleRow: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if mine {
                Spacer(minLength: 100)
            } else if isGroup {
                // Messages puts the avatar at the bottom of a run, level with the last bubble.
                if lastInGroup {
                    RemoteAvatar(url: message.senderAvatar, name: message.senderName, size: 28)
                } else {
                    Color.clear.frame(width: 28, height: 1)
                }
            }
            VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
                if showsName {
                    Text(message.senderName)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .legibleOnWallpaper(hasWallpaper)
                        .padding(.leading, hasWallpaper ? 4 : 12)
                }
                bubbleStack
                if message.translatableText != nil, translationState.showsCard {
                    MessageTranslationCard(
                        message: message,
                        state: translationState,
                        mine: mine,
                        allowCopy: MessageTranslationStore.allowsCopy(for: message),
                        onSelectLanguage: { targetCode in
                            translationStore.translate(message: message, targetCode: targetCode)
                        },
                        onCopy: { translatedText in
                            engine.copyText(translatedText, in: message.conversationId)
                        },
                        onHide: {
                            translationStore.collapse(conversationId: message.conversationId, messageId: message.id)
                        },
                        onRetry: {
                            translationStore.retry(message: message)
                        }
                    )
                    .padding(.top, 2)
                }
                if mine && showStatus { statusLine }
            }
            .frame(maxWidth: 520, alignment: mine ? .trailing : .leading)
            if !mine { Spacer(minLength: 100) }
        }
        .padding(.top, (firstInGroup ? 8 : 2) + (message.reactions.isEmpty ? 0 : 10))
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) { hovering = inside }
        }
    }

    /// The bubble with its Tapback chips on the top corner and, while hovered, the time + react / reply bar beside it.
    private var bubbleStack: some View {
        content
            .contextMenu { menu }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText)
            .accessibilityAction(named: "Trả lời") { if message.kind != .recalled { onReply(message) } }
            .accessibilityValue(message.menu.starred ? "Đã đánh dấu" : "")
            .overlay(alignment: mine ? .topLeading : .topTrailing) {
                if !message.reactions.isEmpty {
                    ReactionChips(reactions: message.reactions, conversationId: message.conversationId, messageId: message.id)
                        .offset(x: mine ? -10 : 10, y: -12)
                }
            }
            // "Đã đánh dấu": a small star on the bubble's inner top corner (the reactions sit on the outer one).
            .overlay(alignment: mine ? .topTrailing : .topLeading) {
                if message.menu.starred {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.yellow)
                        .padding(4)
                        .background(Circle().fill(.background))
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                        .offset(x: mine ? 6 : -6, y: -6)
                        .help("Đã đánh dấu")
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: mine ? .bottomLeading : .bottomTrailing) {
                // Sits just outside the bubble, on the side facing the middle of the chat: a zero-size anchor on the
                // bubble's corner, with the bar hanging off it, so the bar never covers the bubble whatever its width.
                Color.clear
                    .frame(width: 0, height: 0)
                    .overlay(alignment: mine ? .bottomTrailing : .bottomLeading) {
                        if hovering || showsReactionPicker {
                            hoverBar
                                .fixedSize()
                                .padding(mine ? .trailing : .leading, 8)
                                .transition(.opacity)
                        }
                    }
            }
            .messageTourAnchor(isNewest)
    }

    private var hoverBar: some View {
        HStack(spacing: 0) {
            Text(ChatFormat.time(message.date))
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
            if message.isE2EE {
                Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.tertiary)
                    .padding(.trailing, 4)
                    .help("Mã hóa đầu cuối")
            }
            if message.kind != .recalled {
                barButton("Thả cảm xúc", symbol: "face.smiling") { showsReactionPicker.toggle() }
                    .popover(isPresented: $showsReactionPicker, arrowEdge: .top) {
                        ReactionPicker(emojis: Self.reactionEmojis, mine: Set(message.reactions.filter(\.includesMe).map(\.emoji))) { emoji in
                            showsReactionPicker = false
                            onReact(emoji, message)
                        }
                    }
                barButton("Trả lời", symbol: "arrowshape.turn.up.left") { onReply(message) }
                if message.translatableText != nil {
                    let showing = translationState.isActiveOrVisible
                    barButton(showing ? "Ẩn bản dịch" : "Dịch tin nhắn", symbol: "translate") {
                        toggleTranslation()
                    }
                }
                if message.menu.forward == .available {
                    barButton("Chia sẻ", symbol: "arrowshape.turn.up.right") { engine.requestForward(message) }
                }
            }
        }
        .padding(.horizontal, 3).padding(.vertical, 3)
        .glassEffect(.regular, in: Capsule())
    }

    private func barButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }

    private var statusLine: some View {
        HStack(spacing: 4) {
            if message.isE2EE {
                Image(systemName: "lock.fill").font(.system(size: 8.5)).help("Mã hóa đầu cuối")
            }
            Text(statusText).foregroundStyle(message.status == .failed ? Color.red : Color.secondary)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.tertiary)
        .legibleOnWallpaper(hasWallpaper)
        .padding(.horizontal, 4)
        .padding(.top, 1)
    }

    private var statusText: String {
        switch message.status {
        case .sending: "Đang gửi"
        case .sent: "Đã gửi"
        case .delivered: "Đã nhận"
        case .seen: "Đã xem"
        case .failed: "Gửi thất bại"
        }
    }

    private var accessibilityText: String {
        let who = message.isMine ? "Bạn" : message.senderName
        return "\(who), \(ChatFormat.time(message.date)): \(summary)"
    }

    private var summary: String {
        switch message.kind {
        case .photo: "Hình ảnh"
        case .sticker: "Sticker"
        case .gif: "Ảnh GIF"
        case .video: "Video"
        case .voice: "Tin nhắn thoại"
        case .file(let name, _, _): "Tệp \(name)"
        case .link(let title, _, _, _, _): "Liên kết \(title)"
        case .contactCard(let card): "Danh thiếp \(card.name)"
        case .location(let info): "Vị trí \(info.title.isEmpty ? info.address : info.title)"
        case .call(let video, let missed, _, _, _): (missed ? "Cuộc gọi nhỡ " : "") + (video ? "video" : "thoại")
        case .ecard, .oaMessage, .poll, .stickerSet, .zinstant, .notice, .placeholder: message.text
        case .recalled: "Tin nhắn đã được thu hồi"
        case .unsupported(let type): "Tin nhắn không hỗ trợ \(type)"
        case .text, .system: message.text
        }
    }

    // MARK: Context menu

    /// The official message menu, in its order: quick actions (reply, forward), copy, reactions, pin / star, then recall and delete.
    /// Which items show comes from the official builder (`message.menu`); copying follows "Chặn chia sẻ" too.
    @ViewBuilder
    private var menu: some View {
        let actions = message.menu
        if message.kind != .recalled {
            Button("Trả lời", systemImage: "arrowshape.turn.up.left") { onReply(message) }
            if actions.forward != .hidden {
                Button("Chia sẻ", systemImage: "arrowshape.turn.up.right") { engine.requestForward(message) }
                    .disabled(actions.forward == .blocked)
            }
            if !actions.isProtected {
                if let text = message.copyableText {
                    Button("Copy tin nhắn", systemImage: "doc.on.doc") { engine.copyText(text, in: message.conversationId) }
                }
                if case .photo = message.kind {
                    Button("Copy hình ảnh", systemImage: "photo.on.rectangle") { engine.copyPhoto(message) }
                }
                if let caption = message.caption {
                    Button("Copy chú thích", systemImage: "text.quote") { engine.copyText(caption, in: message.conversationId) }
                }
            }
            if message.translatableText != nil {
                if translationState.isActiveOrVisible {
                    Button("Ẩn bản dịch", systemImage: "eye.slash") {
                        translationStore.collapse(conversationId: message.conversationId, messageId: message.id)
                    }
                } else {
                    Button("Dịch tin nhắn", systemImage: "translate") {
                        translationStore.translate(message: message)
                    }
                }
            }
            Menu("Biểu cảm", systemImage: "face.smiling") {
                ForEach(Self.reactionEmojis, id: \.self) { emoji in
                    Button(emoji) { onReact(emoji, message) }
                }
            }
            if actions.pin || actions.star != nil {
                Divider()
                if actions.pinned {
                    Button("Bỏ ghim tin nhắn", systemImage: "pin.slash") { engine.requestUnpin(message) }
                } else if actions.pin {
                    Button("Ghim tin nhắn", systemImage: "pin") { engine.pin(message) }
                }
                switch actions.star {
                case .unstar: Button("Bỏ đánh dấu tin nhắn", systemImage: "star.slash") { engine.setStarred(message, false) }
                case .star: Button("Đánh dấu tin nhắn", systemImage: "star") { engine.setStarred(message, true) }
                case .blocked: Button("Đánh dấu tin nhắn", systemImage: "star") {}.disabled(true)
                case nil: EmptyView()
                }
            }
            if actions.isProtected {
                Text("Trò chuyện này đã bật Chặn chia sẻ")
            }
        }
        if actions.recall || actions.delete != nil {
            Divider()
            if actions.recall && message.kind != .recalled {
                Button("Thu hồi", systemImage: "arrow.uturn.backward", role: .destructive) { engine.recall(message) }
            }
            if let delete = actions.delete {
                Button(delete == .plain ? "Xóa" : "Xóa chỉ ở phía tôi", systemImage: "trash", role: .destructive) { engine.deleteForMe(message) }
            }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch message.kind {
        case .sticker(let url):
            RemoteImage(url: url, contentMode: .fit, maxPixelSize: 320, animated: true) { stickerPlaceholder }
                .onFailure { reason, retry in MediaFailureView(failure: reason, subject: .sticker, compact: true, retry: retry) }
                .frame(width: 130, height: 130)
        case .photo(let url, let w, let h):
            VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
                PhotoView(url: url, width: w, height: h, conversationId: message.conversationId, messageId: message.id,
                          senderName: mine ? "Bạn" : message.senderName, date: message.date,
                          encrypted: message.isE2EE || url?.query?.contains("e2esession") == true)
                caption
            }
        case .gif(let url):
            RemoteImage(url: url, contentMode: .fit, maxPixelSize: 560, animated: true) { mediaPlaceholder }
                .onFailure { reason, retry in
                    MediaFailureView(failure: reason, subject: .photo, retry: retry).frame(width: 200, height: 150)
                }
                .frame(maxWidth: 260, maxHeight: 260)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    Text("GIF").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.5), in: Capsule()).padding(8)
                }
        case .video(let thumbnail, let duration, let url):
            if message.caption != nil {
                VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
                    VideoThumb(thumbnail: thumbnail, duration: duration, url: url, conversationId: message.conversationId, messageId: message.id,
                               senderName: mine ? "Bạn" : message.senderName, date: message.date,
                               encrypted: message.isE2EE || url?.query?.contains("e2esession") == true)
                    caption
                }
            } else {
                VideoThumb(thumbnail: thumbnail, duration: duration, url: url, conversationId: message.conversationId, messageId: message.id,
                           senderName: mine ? "Bạn" : message.senderName, date: message.date,
                           encrypted: message.isE2EE || url?.query?.contains("e2esession") == true)
            }
        case .recalled:
            bubble(muted: true) {
                Text("Tin nhắn đã được thu hồi").font(.system(size: scaled(13.5))).italic()
            }
        case .unsupported(let type):
            bubble(muted: true) {
                Text("[\(type)]").font(.system(size: scaled(13.5)))
            }
        case .text:
            let bankMatches = BankEntityDetector.detect(in: message.text)
            if bankMatches.isEmpty {
                bubble { textBody(message.text) }
            } else {
                VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
                    bubble(tail: false) { textBody(message.text, bankMatches: bankMatches) }
                    BankTransferChipStrip(matches: bankMatches, mine: mine, selectedMatch: $selectedBankMatch)
                }
                .popover(item: $selectedBankMatch, arrowEdge: mine ? .leading : .trailing) { match in
                    BankQRPopoverView(match: match)
                }
            }
        case .voice(let url, let duration):
            bubble { VoiceView(url: url, duration: duration, mine: mine) }
        case .file(let name, let size, let url):
            // Files are cards, not bubbles: neutral for both sides, no tail.
            VStack(alignment: .leading, spacing: 6) {
                if let quote = message.quote { QuoteBlock(quote: quote, mine: false) }
                FileCard(name: name, size: size, url: url, mine: false)
            }
            .padding(10)
            .cardChrome(radius: 16)
            .opacity(message.status == .sending ? 0.7 : 1)
        case .link(let title, let url, let thumbnail, let description, let source):
            VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
                if !message.text.isEmpty, message.text != url?.absoluteString, message.text != title, !message.text.hasPrefix("[Link]") {
                    bubble(tail: false) { textBody(message.text) }
                }
                LinkCard(title: title, url: url, thumbnail: thumbnail, description: description, source: source)
            }
        case .contactCard(let card):
            ContactCardView(card: card)
                .cardActionHost(message)
        case .location(let info):
            LocationCard(info: info, mine: mine)
        case .call(let video, let missed, let duration, let title, let detail):
            bubble(padding: 10) {
                HStack(spacing: 10) {
                    let ink: AnyShapeStyle = missed ? AnyShapeStyle(Color.red) : brandStyle(onMine: mine)
                    Image(systemName: callSymbol(video: video, missed: missed))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(ink)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(ink.opacity(0.15)))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title.isEmpty ? (video ? "Cuộc gọi video" : "Cuộc gọi thoại") : title)
                            .font(.system(size: scaled(13.5), weight: .semibold))
                            .foregroundStyle(missed ? Color.red : (mine ? .white : .primary))
                        Text(detail.isEmpty ? (missed ? "Cuộc gọi nhỡ" : (duration > 0 ? ChatFormat.clock(duration) : "Đã kết thúc")) : detail)
                            .font(.system(size: scaled(11.5))).opacity(0.75)
                    }
                    if let callBack = message.cardButtons.first(where: { $0.ref == "call:back" }) {
                        Button(callBack.label) { engine.startCall(to: message.conversationId, video: video) }
                            .buttonStyle(.plain)
                            .font(.system(size: 11.5, weight: .bold))
                            .foregroundStyle(engine.canCall ? brandStyle(onMine: mine) : AnyShapeStyle(Color.secondary))
                            .padding(.leading, 6)
                            .disabled(!engine.canCall)
                            .help(engine.canCall ? (video ? "Gọi lại video" : "Gọi lại") : CardActionText.callUnsupported)
                    }
                }
            }
        case .oaMessage(let parts):
            if parts.isEmpty { bubble { textBody(message.text) } } else { OAMessageCard(parts: parts) }
        case .poll(let poll):
            PollCard(poll: poll, message: message)
        case .stickerSet(let title, let thumbnail):
            StickerSetCard(title: title, thumbnail: thumbnail)
        case .zinstant(let title, let text, let thumbnail):
            if title.isEmpty, text.isEmpty, thumbnail == nil {
                bubble { textBody(message.text.isEmpty ? "Tin nhắn chưa hỗ trợ hiển thị trên phiên bản hiện tại" : message.text) }
            } else {
                ZInstantCard(title: title, text: text, thumbnail: thumbnail, buttons: message.cardButtons)
                    .cardActionHost(message)
            }
        case .placeholder(let symbol, let text):
            bubble(muted: true) {
                Label(text, systemImage: symbol).font(.system(size: scaled(13)))
            }
        case .system, .notice, .ecard:
            EmptyView()
        }
    }

    private func callSymbol(video: Bool, missed: Bool) -> String {
        if video { return missed ? "video.slash.fill" : "video.fill" }
        return missed ? "phone.arrow.down.left.fill" : "phone.fill"
    }

    @ViewBuilder
    private var caption: some View {
        if !message.text.isEmpty, !message.text.hasPrefix("[") {
            bubble(tail: false) { textBody(message.text) }
        }
    }

    private func textBody(_ text: String, bankMatches: [BankTransferMatch] = []) -> some View {
        Text(ChatFormat.formattedText(
            text,
            mentions: message.mentions,
            bankMatches: bankMatches,
            mine: mine,
            myId: engine.profile?.userId,
            size: scaled(14),
            accent: ChatPalette.accent(accentStored)
        ))
        .font(.system(size: scaled(14)))
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == ChatFormat.mentionScheme {
                // A clicked @mention opens that member's 1-1 chat.
                let uid = String(url.absoluteString.dropFirst(ChatFormat.mentionScheme.count + 1))
                if !uid.isEmpty { engine.navigationRequest = uid }
                return .handled
            }
            if url.scheme == ChatFormat.bankScheme {
                let rawIndex = String(url.absoluteString.dropFirst(ChatFormat.bankScheme.count + 1))
                if let index = Int(rawIndex), bankMatches.indices.contains(index) {
                    selectedBankMatch = bankMatches[index]
                    return .handled
                }
            }
            return .systemAction
        })
    }

    private var stickerPlaceholder: some View {
        ProgressView().controlSize(.small).frame(width: 130, height: 130)
    }

    private var mediaPlaceholder: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.quaternary)
            .frame(width: 200, height: 150)
            .overlay { ProgressView().controlSize(.small) }
    }

    // MARK: Bubble chrome

    /// Tighter corners between the bubbles of one run; the last bubble of a run (`tail`) carries the Messages tail on its sender's side.
    private func bubbleShape(tail: Bool) -> BubbleShape {
        let big: CGFloat = 18, small: CGFloat = 6, join: CGFloat = 4
        let lastBottom = lastInGroup ? (tail ? join : big) : small
        if mine {
            return BubbleShape(mine: true, tail: tail, topLeading: big, topTrailing: firstInGroup ? big : small,
                               bottomLeading: big, bottomTrailing: lastBottom)
        }
        return BubbleShape(mine: false, tail: tail, topLeading: firstInGroup ? big : small, topTrailing: big,
                           bottomLeading: lastBottom, bottomTrailing: big)
    }

    /// `tail: false` for captions and text that belong to a card below; `muted` draws an outline instead of a fill
    /// (recalled / unsupported messages, pending encryption), for both sides.
    private func bubble<C: View>(padding: CGFloat = 0, tail wantsTail: Bool = true, muted: Bool = false, @ViewBuilder _ inner: () -> C) -> some View {
        let shape = bubbleShape(tail: wantsTail && !muted && lastInGroup)
        return VStack(alignment: .leading, spacing: 6) {
            if let quote = message.quote {
                QuoteBlock(quote: quote, mine: mine && !muted)
            }
            inner()
        }
        .padding(.horizontal, padding == 0 ? 12 : padding)
        .padding(.vertical, padding == 0 ? 8 : padding)
        .foregroundStyle(muted ? Color.secondary : (mine ? Color.white : Color.primary))
        .background {
            if muted {
                shape.stroke(Color.primary.opacity(0.2), lineWidth: 1)
            } else if mine {
                shape.fill(.tint)
            } else {
                shape.fill(ChatPalette.incoming)
            }
        }
        .opacity(message.status == .sending ? 0.7 : 1)
    }
}

/// The six Zalo reactions in a popover, Tapback style.
private struct ReactionPicker: View {
    let emojis: [String]
    let mine: Set<String>
    let pick: (String) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(emojis, id: \.self) { emoji in
                ReactionPickerButton(emoji: emoji, selected: mine.contains(emoji)) { pick(emoji) }
            }
        }
        .padding(6)
    }
}

private struct ReactionPickerButton: View {
    let emoji: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(emoji)
                .font(.system(size: 23))
                .frame(width: 38, height: 38)
                .background(Circle().fill(selected ? AnyShapeStyle(TintShapeStyle().opacity(0.22)) : AnyShapeStyle(Color.clear)))
                .scaleEffect(hovering ? 1.2 : 1)
                .offset(y: hovering ? -2 : 0)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.12), value: hovering)
        .accessibilityLabel(emoji)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Pieces

private struct QuoteBlock: View {
    let quote: ChatMessage.Quote
    let mine: Bool
    @Environment(\.olazTextScale) private var textScale

    var body: some View {
        HStack(spacing: 6) {
            Rectangle().fill(mine ? AnyShapeStyle(Color.white.opacity(0.8)) : AnyShapeStyle(TintShapeStyle())).frame(width: 2.5)
            VStack(alignment: .leading, spacing: 1) {
                Text(quote.senderName).font(.system(size: 11.5 * textScale, weight: .semibold))
                Text(quote.text).font(.system(size: 12 * textScale)).lineLimit(2).opacity(0.85)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 4).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(mine ? Color.white.opacity(0.18) : Color.primary.opacity(0.06)))
    }
}

/// Tapback-style chips: one small glass capsule per reaction, drawn over the bubble's top corner by `MessageRow`.
/// A tap shows who reacted.
private struct ReactionChips: View {
    let reactions: [ChatMessage.Reaction]
    let conversationId: String
    let messageId: String
    @AppStorage(OlazPrefs.accent) private var accentStored = OlazAccent.blue.rawValue
    @State private var showsDetail = false

    var body: some View {
        GlassEffectContainer(spacing: 3) {
            HStack(spacing: 3) {
                ForEach(reactions) { r in
                    Button { showsDetail = true } label: {
                        HStack(spacing: 3) {
                            ReactionIconView(icon: r.icon, size: 14)
                            if r.count > 1 {
                                Text("\(r.count)").font(.system(size: 10.5, weight: .semibold).monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .glassEffect(r.includesMe ? Glass.regular.tint(ChatPalette.accent(accentStored).opacity(0.4)) : Glass.regular, in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(r.tooltip ?? "")
                    .accessibilityLabel("\(r.emoji) \(r.count)")
                    .accessibilityHint("Xem ai đã bày tỏ cảm xúc")
                }
            }
        }
        .popover(isPresented: $showsDetail, arrowEdge: .bottom) {
            ReactionDetailView(conversationId: conversationId, messageId: messageId, reactions: reactions)
        }
    }
}

private extension View {
    /// Chat media at `size` at most, shrinking with its aspect ratio when the chat column is narrower (a fixed frame would run
    /// past the column's edge next to the row's spacer). A grid tile (`fixed`) keeps its exact size.
    @ViewBuilder func chatMediaBox(_ size: CGSize, fixed: Bool) -> some View {
        if fixed {
            frame(width: size.width, height: size.height)
        } else {
            Color.clear
                .aspectRatio(size.width / size.height, contentMode: .fit)
                .frame(idealWidth: size.width, maxWidth: size.width)
                .overlay { self }
        }
    }
}

struct PhotoView: View {
    let url: URL?
    let width: Int
    let height: Int
    let conversationId: String
    let messageId: String
    /// Who sent it and when: the media viewer's top bar.
    let senderName: String
    let date: Date
    /// End-to-end encrypted photo: the CDN bytes are ciphertext, go through the official downloader.
    var encrypted = false
    /// Square thumbnail of this side (the inspector's media grid) instead of the chat size.
    var tile: CGFloat?
    @Environment(ZaloEngine.self) private var engine
    @Environment(ShellModel.self) private var shell

    private var radius: CGFloat { tile == nil ? 16 : 8 }

    private var size: CGSize {
        if let tile { return CGSize(width: tile, height: tile) }
        let maxW: CGFloat = 280, maxH: CGFloat = 340
        guard width > 0, height > 0 else { return CGSize(width: 240, height: 180) }
        let scale = min(maxW / CGFloat(width), maxH / CGFloat(height), 1.5)
        return CGSize(width: max(80, CGFloat(width) * scale), height: max(60, CGFloat(height) * scale))
    }

    /// The thumbnail, falling back to the official loader (local copy / other source / "expired") when the CDN link is dead.
    var body: some View {
        RemoteImage(url: url, contentMode: .fill, maxPixelSize: max(size.width, size.height) * 2) {
            Rectangle().fill(.quaternary).overlay { ProgressView().controlSize(.small) }
        }
        .resolvingWith(first: encrypted) { force in
            await engine.resolveMedia(conversationId: conversationId, messageId: messageId, kind: .photo, force: force)
        }
        .onFailure { reason, retry in MediaFailureView(failure: reason, retry: retry) }
        .chatMediaBox(size, fixed: tile != nil)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .onTapGesture { openViewer() }
        .accessibilityAddTraits(.isButton)
    }

    private func openViewer() {
        guard url != nil else { return }
        MediaViewer.shared.show(
            MediaViewerItem(media: .photo(url: url, width: width, height: height, encrypted: encrypted),
                            conversationId: conversationId, messageId: messageId, senderName: senderName, date: date),
            engine: engine, shell: shell)
    }
}

struct VideoThumb: View {
    let thumbnail: URL?
    let duration: Int
    let url: URL?
    let conversationId: String
    let messageId: String
    /// Who sent it and when: the media viewer's top bar.
    let senderName: String
    let date: Date
    /// End-to-end encrypted: the CDN holds ciphertext, so only the official download (which decrypts) can play it.
    var encrypted = false
    /// Square thumbnail of this side (the inspector's media grid) instead of the chat size.
    var tile: CGFloat?
    @Environment(ZaloEngine.self) private var engine
    @Environment(ShellModel.self) private var shell

    private enum Phase: Equatable { case idle, loading, failed }
    @State private var phase: Phase = .idle
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        RemoteImage(url: thumbnail, contentMode: .fill, maxPixelSize: 520) {
            Rectangle().fill(.quaternary)
        }
        .resolvingWith { force in
            await engine.resolveMedia(conversationId: conversationId, messageId: messageId, kind: .videoThumb, force: force)
        }
        .onFailure { reason, retry in MediaFailureView(failure: reason, subject: .videoPreview, compact: true, topAligned: true, retry: retry) }
        .chatMediaBox(CGSize(width: tile ?? 260, height: tile ?? 160), fixed: tile != nil)
        .overlay { centerBadge }
        .overlay(alignment: .bottomTrailing) {
            if duration > 0 {
                Text(ChatFormat.clock(duration)).font(.system(size: tile == nil ? 10.5 : 9.5, weight: .medium)).foregroundStyle(.white)
                    .padding(.horizontal, tile == nil ? 6 : 4).padding(.vertical, 2)
                    .background(.black.opacity(0.5), in: Capsule()).padding(tile == nil ? 8 : 4)
            }
        }
        .overlay(alignment: .top) {
            if phase == .failed, tile == nil {
                Text("Không thể phát video. Nhấn để thử lại.")
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.black.opacity(0.6), in: Capsule()).padding(8)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: tile == nil ? 16 : 8, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: tile == nil ? 16 : 8, style: .continuous))
        .onTapGesture { start() }
        .onDisappear { loadTask?.cancel(); loadTask = nil; if phase == .loading { phase = .idle } }
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var centerBadge: some View {
        Group {
            switch phase {
            case .loading: ProgressView().controlSize(.regular)
            case .failed: Image(systemName: "arrow.clockwise").font(.system(size: 18)).foregroundStyle(.white)
            case .idle: Image(systemName: "play.fill").font(.system(size: 18)).foregroundStyle(.white)
            }
        }
        .scaleEffect(tile == nil ? 1 : 0.6)
        .frame(width: tile == nil ? 46 : 28, height: tile == nil ? 46 : 28)
        .background(.regularMaterial, in: Circle())
    }

    private func start() {
        guard phase != .loading else { return }
        guard let url else { phase = .failed; return }
        let retry = phase == .failed
        phase = .loading
        loadTask = Task {
            do {
                let playable = try await playableFile(url, retry: retry)
                try Task.checkCancellation()
                // The video's shape sizes the viewer window.
                let natural = await VideoPlayback.naturalSize(of: playable)
                try Task.checkCancellation()
                phase = .idle
                MediaViewer.shared.show(
                    MediaViewerItem(media: .video(file: playable, size: natural), conversationId: conversationId,
                                    messageId: messageId, senderName: senderName, date: date),
                    engine: engine, shell: shell)
            } catch {
                // Scrolling away cancels the task; that surfaces as CancellationError or URLError.cancelled.
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    phase = .idle
                } else {
                    phase = .failed
                }
            }
        }
    }

    /// The official player plays every video from the copy `downloadWithMultiSrc` saves (`resolveMedia` kind `.video`), which
    /// decrypts an E2EE video and falls back to Zalo Cloud. Other videos come straight from the CDN first (no wait behind the
    /// photo resolver's queue) and go the official way only when that fails or does not yield a video file.
    private func playableFile(_ url: URL, retry: Bool) async throws -> URL {
        if !encrypted {
            do {
                let file = try await MediaLoader.shared.localFile(for: url)
                try Task.checkCancellation()
                let playable = try await Task.detached(priority: .userInitiated) { () throws -> URL? in
                    VideoPoster.isVideo(file) ? try Self.playableCopy(of: file) : nil
                }.value
                if let playable { return playable }
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            }
        }
        guard case .file(let file) = await engine.resolveMedia(conversationId: conversationId, messageId: messageId, kind: .video, force: retry) else {
            throw URLError(.cannotOpenFile)
        }
        return file
    }

    /// AVFoundation sniffs the container from the extension; cached downloads of extension-less
    /// URLs get an `.mp4` hard link (or copy) alongside.
    nonisolated private static func playableCopy(of file: URL) throws -> URL {
        guard file.pathExtension.isEmpty else { return file }
        let fm = FileManager.default
        let linked = file.appendingPathExtension("mp4")
        func size(_ u: URL) -> Int64? { (try? fm.attributesOfItem(atPath: u.path)[.size] as? NSNumber)?.int64Value }
        let expected = size(file)
        if fm.fileExists(atPath: linked.path) {
            if expected != nil, size(linked) == expected { return linked }
            try? fm.removeItem(at: linked)            // truncated or stale copy
        }
        do {
            try fm.linkItem(at: file, to: linked)
        } catch {
            let temp = linked.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).part")
            do {
                try fm.copyItem(at: file, to: temp)
                guard size(temp) == expected else { throw CocoaError(.fileWriteUnknown) }
                try fm.moveItem(at: temp, to: linked)
            } catch {
                try? fm.removeItem(at: temp)
                try? fm.removeItem(at: linked)
                throw error
            }
        }
        return linked
    }
}

@MainActor
private final class VoicePlayer: ObservableObject {
    enum State { case idle, loading, playing, paused }
    @Published var state: State = .idle
    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private var loadTask: Task<Void, Never>?

    func toggle(_ url: URL) {
        switch state {
        case .loading:
            return
        case .playing:
            player?.pause()
            state = .paused
        case .paused:
            player?.play()
            state = .playing
        case .idle:
            if let player { restart(player) } else { load(url) }
        }
    }

    private func load(_ url: URL) {
        state = .loading
        loadTask = Task { [weak self] in
            do {
                let file = try await MediaLoader.shared.localFile(for: url)
                guard !Task.isCancelled, let self else { return }
                let item = AVPlayerItem(url: file)
                let p = AVPlayer(playerItem: item)
                self.player = p
                self.removeObserver()
                self.endObserver = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.state = .idle }
                }
                p.play()
                self.state = .playing
            } catch {
                self?.state = .idle
            }
        }
    }

    private func restart(_ p: AVPlayer) {
        p.seek(to: .zero)
        p.play()
        state = .playing
    }

    private func removeObserver() {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
    }

    func stop() {
        loadTask?.cancel()
        player?.pause()
        removeObserver()
        if state != .idle { state = .idle }
        // Next play starts over from a fresh item.
        player = nil
    }

    isolated deinit { removeObserver() }
}

private struct VoiceView: View {
    let url: URL?
    let duration: Int
    let mine: Bool
    @Environment(\.olazTextScale) private var textScale
    @StateObject private var player = VoicePlayer()

    var body: some View {
        HStack(spacing: 8) {
            Button {
                if let url { player.toggle(url) }
            } label: {
                ZStack {
                    Circle().fill(brandStyle(onMine: mine))
                    if player.state == .loading {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: player.state == .playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(brandStyle(onMine: !mine))
                    }
                }
                .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(url == nil)
            .accessibilityLabel(player.state == .playing ? "Tạm dừng" : "Phát tin nhắn thoại")
            Image(systemName: "waveform")
                .font(.system(size: 20))
                .symbolEffect(.variableColor.iterative, isActive: player.state == .playing)
            Text(ChatFormat.clock(duration)).font(.system(size: 12.5 * textScale).monospacedDigit())
        }
        .frame(minWidth: 130, alignment: .leading)
        .onDisappear { player.stop() }
    }
}

struct FileCard: View {
    let name: String
    let size: Int64
    let url: URL?
    let mine: Bool
    @State private var downloading = false
    @State private var note: String?

    /// Files whose type could run code when opened (extension comes from the sender, so it is untrusted).
    static func mayExecute(_ file: URL, displayName: String) -> Bool {
        let blocked: Set<String> = ["command", "tool", "terminal", "fileloc", "webloc", "inetloc", "pkg", "mpkg", "app",
                                    "scpt", "scptd", "workflow", "action", "sh", "bash", "zsh", "csh", "ksh", "jar", "dylib", "bundle"]
        let packageTypes = ["com.apple.installer-package-archive", "com.apple.finder.fileloc", "com.apple.terminal.shell-script",
                            "com.apple.web-internet-location", "com.apple.application-script-binary"].compactMap { UTType($0) }
        for ext in Set([file.pathExtension.lowercased(), (displayName as NSString).pathExtension.lowercased()]) where !ext.isEmpty {
            if blocked.contains(ext) { return true }
            guard let type = UTType(filenameExtension: ext) else { continue }
            if type.conforms(to: .executable) || type.conforms(to: .applicationBundle) || type.conforms(to: .package)
                || type.conforms(to: .shellScript) || type.conforms(to: .script) || type.conforms(to: .internetLocation)
                || packageTypes.contains(where: { type.conforms(to: $0) }) {
                return true
            }
        }
        return false
    }

    private func open() {
        guard let url, !downloading else { return }
        downloading = true
        note = nil
        Task {
            defer { downloading = false }
            guard let local = try? await MediaLoader.shared.localFile(for: url) else { return }
            if Self.mayExecute(local, displayName: name) {
                NSWorkspace.shared.activateFileViewerSelecting([local])
                note = "Đã mở trong Finder vì tệp có thể chạy mã"
            } else {
                NSWorkspace.shared.open(local)
            }
        }
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 20))
                    .foregroundStyle(brandStyle(onMine: !mine))
                    .frame(width: 38, height: 38)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(brandStyle(onMine: mine)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let note { Text(note).font(.system(size: 11)).opacity(0.85).fixedSize(horizontal: false, vertical: true) }
                    else if size > 0 { Text(ChatFormat.bytes(size)).font(.system(size: 11.5)).opacity(0.75) }
                }
                .frame(maxWidth: 200, alignment: .leading)
                if downloading {
                    ProgressView().controlSize(.small)
                } else if url != nil {
                    Image(systemName: "arrow.down.circle").font(.system(size: 16)).opacity(0.8)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(url == nil)
    }

    private var symbol: String {
        switch (name as NSString).pathExtension.lowercased() {
        case "pdf": "doc.richtext.fill"
        case "zip", "rar", "7z", "gz": "doc.zipper"
        case "xls", "xlsx", "csv": "tablecells.fill"
        case "mp3", "m4a", "wav": "music.note"
        case "mp4", "mov", "mkv": "film.fill"
        default: "doc.fill"
        }
    }
}
