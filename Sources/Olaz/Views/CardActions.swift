import SwiftUI

// Buttons of the message cards. A card is wrapped in `.cardActionHost(message)`, which provides `CardActions` (the message
// identity + a runner that calls the official handler through `ZaloEngine.performCardAction`). What must outlive a lazily
// rebuilt message row — the busy buttons, the profile / reminder sheets, the failure toast — lives in `CardActionCenter`
// and is presented once by `ChatView` (`.cardActionPresenter()`).
// Disabled buttons are those whose official action needs UI this app does not have; `help` says why.
// Actions that open a dialog officially (alias, group invite, sticker category, poll) open a native sheet (`CardSheets.swift`).
// Everything fires only on a click.

enum CardActionText {
    static let callUnsupported = "Chưa hỗ trợ gọi"
}

struct ProfileRequest: Identifiable, Equatable {
    var uid: String
    var conversationId: String
    var name: String = ""
    var avatar: URL?
    var phone: String = ""
    var isOfficialAccount = false
    /// How the profile was reached; decides the friend-request source the official client records.
    var origin: FriendRequestOrigin = .none
    /// Open straight on the add-friend form (the contact card's "KẾT BẠN").
    var startWithFriendRequest = false
    var id: String { "\(uid)|\(origin.rawValue)|\(startWithFriendRequest)" }
}

struct ReminderRequest: Identifiable, Equatable {
    var conversationId: String
    var messageId: String
    /// Open straight on "Danh sách tham gia" (the card's attendee row).
    var openList = false
    var id: String { conversationId + "|" + messageId }
}

struct AliasRequest: Identifiable, Equatable {
    var conversationId: String
    var draft: AliasDraft
    var id: String { conversationId + "|" + draft.uid }
}

struct GroupInviteRequest: Identifiable, Equatable {
    var url: URL
    var conversationId: String
    var id: String { url.absoluteString }
}

struct StickerCategoryRequest: Identifiable, Equatable {
    var conversationId: String
    var cateId: Int
    var id: String { "\(conversationId)|\(cateId)" }
}

struct PollRequest: Identifiable, Equatable {
    var conversationId: String
    var pollId: String
    var id: String { "\(conversationId)|\(pollId)" }
}

/// Per-app state of card actions that must survive the message list recycling its rows.
@MainActor @Observable
final class CardActionCenter {
    static let shared = CardActionCenter()

    struct Notice: Identifiable, Equatable {
        let id = UUID()
        let text: String
        /// Shown only while this conversation is open (nil = anywhere).
        var conversation: String?
    }

    private(set) var busy: Set<String> = []
    var profile: ProfileRequest?
    var reminder: ReminderRequest?
    var alias: AliasRequest?
    var groupInvite: GroupInviteRequest?
    var stickers: StickerCategoryRequest?
    var poll: PollRequest?
    private(set) var notice: Notice?

    /// Drops every sheet and the toast. Called when another conversation opens and on logout, so nothing from one
    /// conversation / account re-presents in the next. (Busy buttons finish on their own.)
    func reset() {
        profile = nil
        reminder = nil
        alias = nil
        groupInvite = nil
        stickers = nil
        poll = nil
        notice = nil
    }

    private func key(_ conversation: String, _ message: String, _ ref: String) -> String { conversation + "|" + message + "|" + ref }

    /// `ref` nil = any button of that message.
    func isBusy(conversation: String, message: String, ref: String?) -> Bool {
        if let ref { return busy.contains(key(conversation, message, ref)) }
        let prefix = key(conversation, message, "")
        return busy.contains { $0.hasPrefix(prefix) }
    }

    /// Runs the button once at a time; a second click while it is in flight is ignored.
    func run(engine: ZaloEngine, conversation: String, message: String, ref: String) {
        exclusive(conversation: conversation, message: message, ref: ref) { [self] in
            let outcome = await engine.performCardAction(in: conversation, message: message, ref: ref)
            switch outcome {
            case .openProfile(let uid):
                // The sheet belongs to the conversation on screen; a late answer for another one is dropped.
                if engine.openConversationId == conversation { profile = ProfileRequest(uid: uid, conversationId: conversation) }
            case .copy: show("Đã sao chép", in: conversation)
            case .unsupported(let text), .locked(let text), .failed(let text), .pending(let text): show(text, in: conversation)
            case .present(let sheet):
                // Like the profile sheet: it belongs to the conversation on screen, a late answer for another one is dropped.
                guard engine.openConversationId == conversation else { break }
                switch sheet {
                case .alias(let draft): alias = AliasRequest(conversationId: conversation, draft: draft)
                case .groupInvite(let url): groupInvite = GroupInviteRequest(url: url, conversationId: conversation)
                case .stickers(let id): stickers = StickerCategoryRequest(conversationId: conversation, cateId: id)
                case .poll(let id): poll = PollRequest(conversationId: conversation, pollId: id)
                case .tab: break   // applied by the engine
                }
            case .done, .openChat, .openURL: break
            }
        }
    }

    /// Stands in for the message in the busy keys of a reminder's RSVP: the alert and the invite card of one reminder are different
    /// messages but must not both send an answer.
    static func reminderScope(_ reminderId: String) -> String { "reminder:" + reminderId }

    /// RSVP to a reminder through the official controller. Busy state is per reminder (`reminder` = its id; "" falls back to the message).
    func respond(engine: ZaloEngine, conversation: String, message: String, reminder: String = "", accept: Bool) {
        let scope = reminder.isEmpty ? message : Self.reminderScope(reminder)
        exclusive(conversation: conversation, message: scope, ref: accept ? "rsvp:accept" : "rsvp:reject") { [self] in
            let result = await engine.respondToReminder(in: conversation, message: message, accept: accept)
            if !result.ok { show(result.text.isEmpty ? "Có lỗi xảy ra" : result.text, in: conversation) }
        }
    }

    private func exclusive(conversation: String, message: String, ref: String, _ work: @escaping @MainActor () async -> Void) {
        let key = key(conversation, message, ref)
        guard !isBusy(conversation: conversation, message: message, ref: nil) else { return }
        busy.insert(key)
        Task {
            await work()
            busy.remove(key)
        }
    }

    func show(_ text: String, in conversation: String? = nil) {
        let next = Notice(text: text, conversation: conversation)
        notice = next
        Task {
            try? await Task.sleep(for: .seconds(4))
            if notice == next { notice = nil }
        }
    }
}

/// What a card needs to run its buttons.
@MainActor
struct CardActions {
    var conversationId = ""
    var messageId = ""
    var center: CardActionCenter?
    var engine: ZaloEngine?

    func isBusy(_ ref: String) -> Bool { center?.isBusy(conversation: conversationId, message: messageId, ref: ref) ?? false }
    var anyBusy: Bool { center?.isBusy(conversation: conversationId, message: messageId, ref: nil) ?? false }

    func run(_ ref: String) {
        guard let center, let engine else { return }
        center.run(engine: engine, conversation: conversationId, message: messageId, ref: ref)
    }

    func respond(accept: Bool, reminder: String = "") {
        guard let center, let engine else { return }
        center.respond(engine: engine, conversation: conversationId, message: messageId, reminder: reminder, accept: accept)
    }

    /// RSVP busy state of a reminder (shared by all its cards); `ref` nil = any answer.
    func isRsvpBusy(_ reminder: String, ref: String? = nil) -> Bool {
        guard !reminder.isEmpty else { return ref.map(isBusy) ?? anyBusy }
        return center?.isBusy(conversation: conversationId, message: CardActionCenter.reminderScope(reminder), ref: ref) ?? false
    }

    func showProfile(_ request: ProfileRequest) { center?.profile = request }

    /// Opens a link from a card: a group invite link shows the group sheet (official GROUP_PREVIEW), anything else goes to the browser
    /// (http/https only, through `WebLink`).
    func openLink(_ url: URL?) {
        if let url = WebLink.sanitized(url), GroupInviteLink.isInvite(url), let center {
            center.groupInvite = GroupInviteRequest(url: url, conversationId: conversationId)
        } else {
            WebLink.open(url)
        }
    }
    func showReminder(openList: Bool = false) {
        center?.reminder = ReminderRequest(conversationId: conversationId, messageId: messageId, openList: openList)
    }
}

extension EnvironmentValues {
    @Entry var cardActions = CardActions()
}

private struct CardActionHost: ViewModifier {
    let conversationId: String
    let messageId: String
    @Environment(ZaloEngine.self) private var engine

    func body(content: Content) -> some View {
        content.environment(\.cardActions, CardActions(conversationId: conversationId, messageId: messageId,
                                                       center: CardActionCenter.shared, engine: engine))
    }
}

/// Presents what card actions open (profile / reminder sheets) and their failure toast, once per chat.
private struct CardActionPresenter: ViewModifier {
    @Bindable var center: CardActionCenter
    @Environment(ZaloEngine.self) private var engine

    func body(content: Content) -> some View {
        content
            .sheet(item: $center.profile) { ContactProfileSheet(request: $0).cardNoticeOverlay() }
            .sheet(item: $center.reminder) { ReminderDetailSheet(request: $0).cardNoticeOverlay() }
            .sheet(item: $center.alias) { AliasSheet(request: $0).cardNoticeOverlay() }
            .sheet(item: $center.groupInvite) { GroupInviteSheet(request: $0).cardNoticeOverlay() }
            .sheet(item: $center.stickers) { StickerCategorySheet(request: $0).cardNoticeOverlay() }
            .sheet(item: $center.poll) { PollDetailSheet(pollId: $0.pollId, conversationId: $0.conversationId, question: "").cardNoticeOverlay() }
            .cardNoticeOverlay()
            // Nothing opened from one conversation may show up in another.
            .onChange(of: engine.openConversationId) { _, _ in center.reset() }
    }
}

/// The failure / info toast. Applied to the chat and to every sheet the center presents, so it is never hidden behind one.
private struct CardNoticeOverlay: ViewModifier {
    @Environment(ZaloEngine.self) private var engine

    func body(content: Content) -> some View {
        let center = CardActionCenter.shared
        content
            .overlay(alignment: .bottom) {
                if let notice = center.notice, notice.conversation == nil || notice.conversation == engine.openConversationId {
                    Text(notice.text).font(.system(size: 12.5, weight: .medium)).lineLimit(3)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .glassEffect(.regular, in: Capsule())
                        .padding(.bottom, 84)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
            .animation(.snappy, value: center.notice)
    }
}

extension View {
    /// Gives a card the means to run its buttons (see `CardActions`).
    func cardActionHost(_ message: ChatMessage) -> some View {
        modifier(CardActionHost(conversationId: message.conversationId, messageId: message.id))
    }

    /// Shows the card-action toast above this view (used inside sheets, which cover the chat's own toast).
    func cardNoticeOverlay() -> some View { modifier(CardNoticeOverlay()) }

    /// Hosts the sheets / toast that card buttons open (attach once, to the chat).
    func cardActionPresenter() -> some View {
        modifier(CardActionPresenter(center: .shared))
    }
}

extension String {
    /// At most `limit` UTF-16 units (JS `slice` semantics, which the official limit counts), never splitting a character.
    func prefixUTF16(_ limit: Int) -> String {
        guard utf16.count > limit else { return self }
        var out = ""
        var used = 0
        for character in self {
            let size = character.utf16.count
            if used + size > limit { break }
            out.append(character)
            used += size
        }
        return out
    }
}

// MARK: - Buttons

/// The official e-card button bar: one or two labelled cells separated by a hairline.
struct CardButtonBar: View {
    let buttons: [CardButton]
    var width: CGFloat = 300
    @Environment(\.cardActions) private var actions

    var body: some View {
        if !buttons.isEmpty {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 0) {
                    ForEach(Array(buttons.enumerated()), id: \.element.id) { index, button in
                        if index > 0 { Divider().frame(height: 24) }
                        Button { actions.run(button.ref) } label: {
                            ZStack {
                                Text(button.label).opacity(actions.isBusy(button.ref) ? 0 : 1)
                                if actions.isBusy(button.ref) { ProgressView().controlSize(.small) }
                            }
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(button.enabled ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary))
                            .frame(maxWidth: .infinity).padding(.vertical, 10).lineLimit(1)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!button.enabled || actions.anyBusy)
                        .help(button.help)
                    }
                }
            }
            .frame(width: width)
        }
    }
}

/// Inline links under an info message / ZInstant text (`customMsg.actions`, official `renderAction`).
struct CardLinkRow: View {
    let buttons: [CardButton]
    @Environment(\.cardActions) private var actions

    var body: some View {
        if !buttons.isEmpty {
            HStack(spacing: 12) {
                ForEach(buttons) { button in
                    Button { actions.run(button.ref) } label: {
                        Text(button.label).font(.system(size: 12, weight: .medium))
                            .foregroundStyle(button.enabled ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary))
                    }
                    .buttonStyle(.plain)
                    .disabled(!button.enabled || actions.anyBusy)
                    .help(button.help)
                }
            }
        }
    }
}

// MARK: - Suggested stickers

/// The stickers an e-card suggests (new friend, birthday): the official list, sent on click.
struct StickerSuggestionStrip: View {
    @Environment(ZaloEngine.self) private var engine
    @Environment(\.cardActions) private var actions
    @State private var stickers: [SuggestedSticker] = []

    var body: some View {
        Group {
            if !stickers.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(stickers) { sticker in
                            Button { actions.run(sticker.ref) } label: {
                                RemoteImage(url: sticker.url, contentMode: .fit, maxPixelSize: 200, animated: true) {
                                    Image(systemName: "face.smiling").foregroundStyle(.tertiary)
                                }
                                .frame(width: 58, height: 58)
                                .opacity(actions.isBusy(sticker.ref) ? 0.4 : 1)
                            }
                            .buttonStyle(.plain)
                            .disabled(actions.anyBusy)
                            .help("Gửi sticker này")
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .frame(height: 64)
            }
        }
        .task(id: actions.messageId) {
            // The sticker service may not be resolved yet right after launch: a few tries, then give up quietly.
            for attempt in 0..<4 {
                let list = await engine.suggestedStickers(in: actions.conversationId, message: actions.messageId)
                if !list.isEmpty { stickers = list; return }
                if attempt < 3 { try? await Task.sleep(for: .seconds(1.5)) }
                if Task.isCancelled { return }
            }
        }
    }
}

// MARK: - Contact profile (card tap, "KẾT BẠN")

/// Profile of the person on a contact card (or named by a profile action) with the official actions: message, call,
/// and the add-friend form (message box prefilled with the official greeting; nothing is sent until the button is pressed).
struct ContactProfileSheet: View {
    let request: ProfileRequest
    @Environment(ZaloEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @State private var profile: ContactProfile?
    @State private var prep: FriendRequestPrep?
    @State private var preparing = false
    @State private var message = ""
    @State private var sending = false
    /// The adapter has not answered yet: the request may still go out, so it cannot be sent again from here.
    @State private var requestPending = false
    @State private var result: (ok: Bool, text: String)?
    @State private var isBlocked = false
    @State private var blockingBusy = false
    @State private var confirmBlock = false
    @State private var blockError: String?

    private var name: String {
        let own = profile?.name ?? ""
        return own.isEmpty ? (request.name.isEmpty ? "Người dùng Zalo" : request.name) : own
    }
    private var isOfficialAccount: Bool { profile?.isOfficialAccount ?? request.isOfficialAccount }

    var body: some View {
        VStack(spacing: 14) {
            RemoteAvatar(url: profile?.avatar ?? request.avatar, name: name, size: 84)
            VStack(spacing: 4) {
                Text(name).font(.system(size: 17, weight: .bold)).multilineTextAlignment(.center)
                if let zaloName = profile?.zaloName, !zaloName.isEmpty, zaloName != name {
                    Text(zaloName).font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
                if let bio = profile?.bio, !bio.isEmpty {
                    Text(bio).font(.system(size: 12.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                if !request.phone.isEmpty {
                    Text(request.phone).font(.system(size: 12.5)).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            if profile?.isSelf != true { actionRow }
            requestSection
            if profile != nil, profile?.isSelf != true, !isOfficialAccount {
                blockToggleSection
            }
            Button("Đóng") { dismiss() }.keyboardShortcut(.cancelAction).controlSize(.small)
        }
        .padding(24)
        .frame(width: 340)
        .task {
            profile = await engine.contactProfile(request.uid)
            isBlocked = await engine.isUserBlocked(request.uid)
            if request.startWithFriendRequest { await beginRequest() }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button { engine.openContactConversation(request.uid); dismiss() } label: {
                Label("Nhắn tin", systemImage: "bubble.left.fill")
            }
            .buttonStyle(.glassProminent)
            if profile?.isFriend == true {
                CallButtons(uid: request.uid)
            } else if !isOfficialAccount, prep == nil, profile != nil {
                Button { Task { await beginRequest() } } label: {
                    if preparing { ProgressView().controlSize(.small) } else { Label("Kết bạn", systemImage: "person.badge.plus") }
                }
                .buttonStyle(.glass)
                .disabled(preparing)
            }
        }
    }

    @ViewBuilder private var requestSection: some View {
        if let prep {
            switch prep.state {
            case .ready:
                VStack(alignment: .leading, spacing: 6) {
                    Text("Lời nhắn").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    TextEditor(text: $message)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .frame(height: 78)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.5)))
                        .disabled(sending)
                        .onChange(of: message) { _, new in
                            if new.utf16.count > prep.maxMessage { message = new.prefixUTF16(prep.maxMessage) }
                        }
                    Text("\(message.utf16.count)/\(prep.maxMessage)")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    Button(action: submit) {
                        if sending { ProgressView().controlSize(.small) } else { Label("Gửi lời mời kết bạn", systemImage: "person.badge.plus") }
                    }
                    .buttonStyle(.glassProminent)
                    .frame(maxWidth: .infinity)
                    .disabled(sending || requestPending || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let result, !result.ok {
                        Text(result.text).font(.system(size: 12)).foregroundStyle(.orange)
                    }
                }
            case .requested:
                note(result?.ok == true ? "Đã gửi lời mời kết bạn." : "Bạn đã gửi yêu cầu kết bạn và đang chờ người này đồng ý")
            case .requesting:
                note("Người này đã gửi lời mời kết bạn cho bạn. Hãy chấp nhận ở mục “Lời mời kết bạn”.")
            case .friend: note("Đã là bạn bè.")
            case .me: EmptyView()
            case .error: note("Không thể kiểm tra trạng thái kết bạn lúc này. Hãy thử lại sau.")
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 12.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
    }

    @ViewBuilder
    private var blockToggleSection: some View {
        VStack(spacing: 6) {
            if isBlocked {
                Button {
                    toggleBlock(false)
                } label: {
                    if blockingBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Bỏ chặn người này", systemImage: "hand.raised.slash")
                    }
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(blockingBusy)
            } else {
                Button(role: .destructive) {
                    confirmBlock = true
                } label: {
                    if blockingBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Chặn người này", systemImage: "hand.raised")
                    }
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(blockingBusy)
                .confirmationDialog("Chặn \(name)?", isPresented: $confirmBlock, titleVisibility: .visible) {
                    Button("Chặn", role: .destructive) { toggleBlock(true) }
                    Button("Hủy", role: .cancel) {}
                } message: {
                    Text("Người này sẽ không thể nhắn tin hoặc gọi điện cho bạn.")
                }
            }
            if let blockError {
                Text(blockError)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func toggleBlock(_ blocked: Bool) {
        guard !blockingBusy else { return }
        blockingBusy = true
        blockError = nil
        Task {
            let outcome = await engine.setBlocked(uid: request.uid, blocked: blocked)
            blockingBusy = false
            switch outcome {
            case .success:
                isBlocked = blocked
            case .failure(let message):
                blockError = message
            }
        }
    }

    /// Official `_onAddFriend`: status check, request source, then the add-friend form with the default message.
    private func beginRequest() async {
        guard prep == nil, !preparing else { return }
        preparing = true
        let origin: FriendRequestOrigin = request.startWithFriendRequest ? .add : request.origin
        let outcome = await engine.prepareFriendRequest(to: request.uid, from: request.conversationId, via: origin)
        preparing = false
        prep = outcome
        message = outcome.defaultMessage.prefixUTF16(outcome.maxMessage)
    }

    /// Sends the request the user confirmed and waits for the adapter's own answer; the button stays busy until it comes.
    private func submit() {
        guard !sending else { return }
        sending = true
        result = nil
        let text = message
        Task {
            let outcome = await engine.submitFriendRequest(to: request.uid, message: text)
            sending = false
            result = (outcome.ok, outcome.text)
            if outcome.ok { prep = FriendRequestPrep(state: .requested) }
            else if outcome.pending { requestPending = true }
        }
    }
}

/// Voice / video call buttons; disabled with the tooltip "Chưa hỗ trợ gọi" until the app can place calls.
struct CallButtons: View {
    let uid: String
    @Environment(ZaloEngine.self) private var engine

    var body: some View {
        HStack(spacing: 8) {
            Button { engine.startCall(to: uid, video: false) } label: { Label("Gọi", systemImage: "phone.fill") }
                .help(engine.canCall ? "Gọi thoại" : CardActionText.callUnsupported)
            Button { engine.startCall(to: uid, video: true) } label: { Label("Video", systemImage: "video.fill") }
                .help(engine.canCall ? "Gọi video" : CardActionText.callUnsupported)
        }
        .buttonStyle(.glass)
        .disabled(!engine.canCall)
    }
}
