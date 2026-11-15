import SwiftUI

// "Danh bạ": friends and groups, fed by the official client's services through `engine.contacts`
// (ZaloEngine+Contacts.swift). The shell shows a list in the content column and a card in the detail column;
// ContactsColumns.swift dispatches by destination. Requests and add-friend live in ContactsRequestsView.swift.

// MARK: - Shared pieces

/// Glass search field shown at the top of the contacts lists (in a `.safeAreaBar`).
struct ContactsSearchField: View {
    @Binding var text: String
    var prompt: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Xoá nội dung tìm kiếm")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .glassEffect(.regular, in: Capsule())
    }
}

@MainActor
enum ContactsFormat {
    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "vi")
        f.unitsStyle = .full
        return f
    }()

    /// "5 phút trước" style text.
    static func ago(_ date: Date) -> String {
        if Date().timeIntervalSince(date) < 60 { return "vừa xong" }
        return relative.localizedString(for: date, relativeTo: Date())
    }
}

/// Floating result text of the latest contacts action (accept / decline / cancel / send).
private struct ContactsToast: ViewModifier {
    @Environment(ZaloEngine.self) private var engine
    @State private var toast: ContactsState.Notice?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let toast {
                    HStack(spacing: 8) {
                        Image(systemName: toast.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(toast.ok ? Color.green : Color.orange)
                        Text(toast.text).font(.system(size: 12.5, weight: .medium)).lineLimit(2)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .glassEffect(.regular, in: Capsule())
                    .padding(.bottom, 22)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityElement(children: .combine)
                }
            }
            .onChange(of: engine.contacts.notice) { _, notice in
                guard let notice else { return }
                withAnimation(.snappy) { toast = notice }
                Task {
                    try? await Task.sleep(for: .seconds(3.5))
                    if toast == notice { withAnimation(.snappy) { toast = nil } }
                }
            }
    }
}

extension View {
    func contactsToast() -> some View { modifier(ContactsToast()) }
}

/// Contacts.app-style card header: big avatar, name, optional second name and status line, then the action row.
struct ContactCardHeader<Actions: View>: View {
    let avatar: URL?
    let name: String
    var secondaryName: String?
    var status: String?
    var online = false
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 5) {
            RemoteAvatar(url: avatar, name: name, size: 104)
                .overlay(alignment: .bottomTrailing) {
                    if online {
                        Circle().fill(.green).frame(width: 20, height: 20)
                            .overlay(Circle().stroke(.background, lineWidth: 3))
                            .offset(x: -2, y: -2)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.bottom, 6)
            Text(name)
                .font(.system(size: 22, weight: .bold))
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            if let secondaryName, !secondaryName.isEmpty, secondaryName != name {
                Text(secondaryName).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if let status, !status.isEmpty {
                Text(status).font(.system(size: 12.5)).foregroundStyle(online ? Color.green : Color.secondary)
            }
            actions().padding(.top, 14)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}

/// Round glass button with its caption underneath (message / voice / video of a contact card).
struct ContactActionButton: View {
    let title: String
    let symbol: String
    var prominent = false
    var help: String?
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        VStack(spacing: 6) {
            button
                .buttonBorderShape(.circle)
                .controlSize(.extraLarge)
                .help(help ?? title)
                .accessibilityLabel(title)
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isEnabled ? Color.secondary : Color.secondary.opacity(0.5))
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private var button: some View {
        let label = Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).frame(width: 24, height: 24)
        if prominent {
            Button(action: action) { label }.buttonStyle(.glassProminent)
        } else {
            Button(action: action) { label }.buttonStyle(.glass)
        }
    }
}

/// Voice / video call buttons of a person who may have no conversation yet. Same availability rules (and tooltips)
/// as the chat header; a call is only placed by a click.
struct ContactCallActions: View {
    @Environment(ZaloEngine.self) private var engine
    let id: String
    let name: String
    let avatar: URL?

    private var target: ZaloEngine.ConversationSummary {
        .init(id: id, isGroup: false, name: name, avatar: avatar, pinned: false, members: 0, unread: 0, preview: nil)
    }

    var body: some View {
        let audio = engine.callAvailability(for: target, video: false)
        let video = engine.callAvailability(for: target, video: true)
        if audio != .hidden { button("Gọi thoại", symbol: "phone.fill", availability: audio, isVideo: false) }
        if video != .hidden { button("Gọi video", symbol: "video.fill", availability: video, isVideo: true) }
    }

    private func button(_ title: String, symbol: String, availability: CallAvailability, isVideo: Bool) -> some View {
        var tooltip = "\(title) với \(name)"
        if case .disabled(let reason) = availability { tooltip = reason }
        return ContactActionButton(title: title, symbol: symbol, help: tooltip) {
            engine.startCall(to: id, video: isVideo)
        }
        .disabled(availability != .available)
    }
}

// MARK: - Friends

/// Content column: alphabetical friends with a glass search field.
struct FriendsList: View {
    @Environment(ZaloEngine.self) private var engine
    @Environment(ShellModel.self) private var shell
    @State private var query = ""
    /// Folding and sorting thousands of friends is not redone on every render: only when the friends or the query change.
    @State private var cache = FriendSections()

    var body: some View {
        @Bindable var shell = shell
        let sections = cache.sections(friends: engine.visibleFriends, query: query)
        Group {
            if !engine.contacts.friendsLoaded || !engine.conversationActions.hiddenKnown {
                ContactsLoading(text: "Đang tải danh sách bạn bè…")
            } else if engine.visibleFriends.isEmpty {
                ContentUnavailableView {
                    Label("Chưa có bạn bè", systemImage: "person.2")
                } description: {
                    Text("Tìm bạn bằng số điện thoại để gửi lời mời kết bạn.")
                } actions: {
                    Button("Thêm bạn") { shell.destination = .addFriend }.buttonStyle(.glass)
                }
                // Fills the column so the search bar stays at the top instead of hugging a centered empty state.
                .fillColumn()
            } else if sections.isEmpty {
                ContentUnavailableView.search(text: query).fillColumn()
            } else {
                List(selection: $shell.contactSelection) {
                    ForEach(sections, id: \.letter) { section in
                        Section(section.letter) {
                            ForEach(section.friends) { friend in
                                FriendRow(friend: friend).tag(friend.id)
                            }
                        }
                    }
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    if let id = ids.first, let friend = engine.visibleFriends.first(where: { $0.id == id }) {
                        FriendMenu(friend: friend)
                    }
                } primaryAction: { ids in
                    if let id = ids.first { engine.openContactConversation(id) }
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
            }
        }
        .safeAreaBar(edge: .top) {
            ContactsSearchField(text: $query, prompt: "Tìm bạn")
                .padding(.horizontal, 12).padding(.bottom, 6)
        }
        .columnTitle("Bạn bè", subtitle: "\(engine.visibleFriends.count) bạn bè")
    }
}

/// The alphabetical sections of `FriendsList`, kept for the friends and query they were built from.
@MainActor
private final class FriendSections {
    typealias Section = (letter: String, friends: [ContactsState.Friend])

    private var friends: [ContactsState.Friend]?
    private var query = ""
    private var built: [Section] = []
    /// Folded Zalo names by friend id, with the name they were folded from (folding creates a `Locale` per call).
    private var foldedZaloNames: [String: (name: String, folded: String)] = [:]

    func sections(friends: [ContactsState.Friend], query: String) -> [Section] {
        if let cached = self.friends, cached == friends, self.query == query { return built }
        self.friends = friends
        self.query = query
        let q = ZaloEngine.contactFold(query).trimmingCharacters(in: .whitespaces)
        let matches = q.isEmpty ? friends : friends.filter { $0.sortKey.contains(q) || foldedZaloName($0).contains(q) }
        let grouped = Dictionary(grouping: matches, by: \.section)
        built = grouped.keys.sorted { a, b in
            if a == "#" { return false }
            if b == "#" { return true }
            return a < b
        }.map { letter in
            (letter, grouped[letter, default: []].sorted { $0.sortKey.localizedStandardCompare($1.sortKey) == .orderedAscending })
        }
        return built
    }

    private func foldedZaloName(_ friend: ContactsState.Friend) -> String {
        if let cached = foldedZaloNames[friend.id], cached.name == friend.zaloName { return cached.folded }
        let folded = ZaloEngine.contactFold(friend.zaloName)
        foldedZaloNames[friend.id] = (friend.zaloName, folded)
        return folded
    }
}

private struct FriendRow: View {
    let friend: ContactsState.Friend

    var body: some View {
        HStack(spacing: 10) {
            RemoteAvatar(url: friend.avatar, name: friend.name, size: 36)
                .overlay(alignment: .bottomTrailing) {
                    if friend.online {
                        Circle().fill(.green).frame(width: 11, height: 11)
                            .overlay(Circle().stroke(.background, lineWidth: 2))
                            .offset(x: 1, y: 1)
                    }
                }
            Text(friend.name).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(friend.online ? "\(friend.name), đang hoạt động" : friend.name)
    }
}

/// Row actions of a friend: open the chat, call.
private struct FriendMenu: View {
    @Environment(ZaloEngine.self) private var engine
    let friend: ContactsState.Friend

    var body: some View {
        let target = ZaloEngine.ConversationSummary(id: friend.id, isGroup: false, name: friend.name, avatar: friend.avatar,
                                                    pinned: false, members: 0, unread: 0, preview: nil)
        Button("Nhắn tin", systemImage: "bubble.left") { engine.openContactConversation(friend.id) }
        if engine.callAvailability(for: target, video: false) != .hidden {
            Button("Gọi thoại", systemImage: "phone") { engine.startCall(to: friend.id, video: false) }
                .disabled(engine.callAvailability(for: target, video: false) != .available)
        }
        if engine.callAvailability(for: target, video: true) != .hidden {
            Button("Gọi video", systemImage: "video") { engine.startCall(to: friend.id, video: true) }
                .disabled(engine.callAvailability(for: target, video: true) != .available)
        }
    }
}

/// Detail column: the selected friend as a Contacts.app-style card.
struct FriendCard: View {
    @Environment(ZaloEngine.self) private var engine
    let friend: ContactsState.Friend
    @State private var profile: ContactProfile?

    private var status: String? {
        if friend.online { return "Đang hoạt động" }
        return friend.lastActive.map { "Truy cập \(ContactsFormat.ago($0))" }
    }

    var body: some View {
        Form {
            Section {
                ContactCardHeader(avatar: friend.avatar, name: friend.name,
                                  secondaryName: friend.zaloName.isEmpty ? profile?.zaloName : friend.zaloName,
                                  status: status, online: friend.online) {
                    GlassEffectContainer(spacing: 20) {
                        HStack(spacing: 20) {
                            ContactActionButton(title: "Nhắn tin", symbol: "bubble.left.fill", prominent: true) {
                                engine.openContactConversation(friend.id)
                            }
                            ContactCallActions(id: friend.id, name: friend.name, avatar: friend.avatar)
                        }
                    }
                }
            }
            .listRowBackground(Color.clear)
            if let bio = profile?.bio, !bio.isEmpty {
                Section("Giới thiệu") { Text(bio).textSelection(.enabled) }
            }
            if profile?.isOfficialAccount == true {
                Section { LabeledContent("Loại tài khoản", value: "Tài khoản chính thức") }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(friend.name)
        .task(id: friend.id) {
            profile = nil
            let loaded = await engine.contactProfile(friend.id)
            // Selecting another friend meanwhile cancels this task; never show someone else's profile.
            guard !Task.isCancelled, loaded?.uid == friend.id else { return }
            profile = loaded
        }
    }
}

// MARK: - Groups

/// Content column: the groups the user is in.
struct GroupsList: View {
    @Environment(ZaloEngine.self) private var engine
    @Environment(ShellModel.self) private var shell
    @State private var query = ""

    private var groups: [ContactsState.Group] {
        let q = ZaloEngine.contactFold(query).trimmingCharacters(in: .whitespaces)
        let list = q.isEmpty ? engine.visibleGroups : engine.visibleGroups.filter { $0.sortKey.contains(q) }
        return list.sorted { $0.sortKey.localizedStandardCompare($1.sortKey) == .orderedAscending }
    }

    var body: some View {
        @Bindable var shell = shell
        let groups = groups
        Group {
            if !engine.contacts.groupsLoaded || !engine.conversationActions.hiddenKnown {
                ContactsLoading(text: "Đang tải danh sách nhóm…")
            } else if engine.visibleGroups.isEmpty {
                // Official empty group list: STR_TEXT_CREATE_GROUPS_LIST + "Tạo nhóm".
                ContentUnavailableView {
                    Label("Chưa tham gia nhóm nào", systemImage: "person.2")
                } description: {
                    Text("Tạo nhóm để cùng nhau trò chuyện và trao đổi với bạn bè đồng nghiệp")
                } actions: {
                    Button("Tạo nhóm") { shell.composeGroup() }.buttonStyle(.glass)
                }
                .fillColumn()
            } else if groups.isEmpty {
                ContentUnavailableView.search(text: query).fillColumn()
            } else {
                List(groups, selection: $shell.contactSelection) { group in
                    GroupRow(group: group).tag(group.id)
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    if let id = ids.first {
                        Button("Mở trò chuyện", systemImage: "bubble.left") { engine.openContactConversation(id) }
                    }
                } primaryAction: { ids in
                    if let id = ids.first { engine.openContactConversation(id) }
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
            }
        }
        .safeAreaBar(edge: .top) {
            ContactsSearchField(text: $query, prompt: "Tìm nhóm")
                .padding(.horizontal, 12).padding(.bottom, 6)
        }
        .columnTitle("Nhóm và cộng đồng", subtitle: "\(engine.visibleGroups.count) nhóm")
    }
}

private struct GroupRow: View {
    let group: ContactsState.Group

    var body: some View {
        HStack(spacing: 10) {
            RemoteAvatar(url: group.avatar, name: group.name, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.name).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                Text("\(group.members) thành viên").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Detail column: the selected group, with the button that opens its conversation.
struct GroupCard: View {
    @Environment(ZaloEngine.self) private var engine
    let group: ContactsState.Group

    var body: some View {
        Form {
            Section {
                ContactCardHeader(avatar: group.avatar, name: group.name,
                                  status: group.members > 0 ? "\(group.members) thành viên" : nil) {
                    Button { engine.openContactConversation(group.id) } label: {
                        Label("Mở trò chuyện", systemImage: "bubble.left.fill")
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                }
            }
            .listRowBackground(Color.clear)
        }
        .formStyle(.grouped)
        .navigationTitle(group.name)
    }
}

/// Centered spinner with a caption while a contacts list is being read.
struct ContactsLoading: View {
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(text).font(.system(size: 12.5)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
