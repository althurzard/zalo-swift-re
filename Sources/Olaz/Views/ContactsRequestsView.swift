import SwiftUI

// Friend requests (Lời mời kết bạn) and add-friend (Thêm bạn): a list / form in the content column and a card in the
// detail column. Every action goes through the official client's friend-request service (ZaloEngine+Contacts.swift).

// MARK: - Friend requests

/// Content column: received requests, then the ones the user sent.
struct RequestsList: View {
    @Environment(ZaloEngine.self) private var engine
    @Environment(ShellModel.self) private var shell

    private var received: [ContactsState.FriendRequest] { engine.contacts.received }
    /// A person never appears in both sections (selection ids must be unique across the list).
    private var sent: [ContactsState.FriendRequest] {
        let receivedIds = Set(received.map(\.id))
        return engine.contacts.sent.filter { !receivedIds.contains($0.id) }
    }

    var body: some View {
        @Bindable var shell = shell
        Group {
            if received.isEmpty && sent.isEmpty {
                if engine.contacts.loadingRequests {
                    ContactsLoading(text: "Đang tải lời mời…")
                } else {
                    ContentUnavailableView("Không có lời mời mới", systemImage: "person.crop.circle.badge.checkmark",
                                           description: Text("Lời mời kết bạn sẽ hiện ở đây."))
                }
            } else {
                List(selection: $shell.contactSelection) {
                    if !received.isEmpty {
                        Section("Đã nhận") {
                            ForEach(received) { RequestRow(request: $0).tag($0.id) }
                        }
                    }
                    if !sent.isEmpty {
                        Section("Đã gửi") {
                            ForEach(sent) { RequestRow(request: $0).tag($0.id) }
                        }
                    }
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
            }
        }
        .columnTitle("Lời mời kết bạn", subtitle: "\(engine.contacts.pendingRequestCount) lời mời đang chờ")
        .toolbar {
            ToolbarItem {
                if engine.contacts.loadingRequests {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Tải lại", systemImage: "arrow.clockwise") { engine.refreshContacts() }
                }
            }
        }
    }
}

private struct RequestRow: View {
    let request: ContactsState.FriendRequest

    var body: some View {
        HStack(spacing: 10) {
            RemoteAvatar(url: request.avatar, name: request.name, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(request.name).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 4)
                    if let date = request.date {
                        Text(ContactsFormat.ago(date)).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                if !request.message.isEmpty {
                    Text(request.message).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private enum RequestAction { case accept, decline, cancel }

/// Detail column: the selected request as a card with the intro message and the answer buttons.
struct RequestsDetail: View {
    @Environment(ZaloEngine.self) private var engine
    @Environment(ShellModel.self) private var shell
    /// Requests with an action in flight (cleared when the official client reports the result).
    @State private var busy: Set<String> = []

    private var selected: (request: ContactsState.FriendRequest, received: Bool)? {
        guard let id = shell.contactSelection else { return nil }
        if let request = engine.contacts.received.first(where: { $0.id == id }) { return (request, true) }
        if let request = engine.contacts.sent.first(where: { $0.id == id }) { return (request, false) }
        return nil
    }

    var body: some View {
        Group {
            if let selected {
                RequestCard(request: selected.request, received: selected.received, busy: busy.contains(selected.request.id)) { action in
                    let id = selected.request.id
                    busy.insert(id)
                    switch action {
                    case .accept: engine.acceptFriendRequest(id)
                    case .decline: engine.declineFriendRequest(id)
                    case .cancel: engine.cancelFriendRequest(id)
                    }
                }
                .id(selected.request.id)
            } else if engine.contacts.received.isEmpty && engine.contacts.sent.isEmpty {
                ContentUnavailableView("Không có lời mời mới", systemImage: "person.crop.circle.badge.checkmark",
                                       description: Text("Lời mời kết bạn sẽ hiện ở đây."))
            } else {
                ContentUnavailableView("Chọn một lời mời", systemImage: "person.crop.circle.badge.questionmark",
                                       description: Text("Chọn lời mời ở danh sách bên cạnh để xem và trả lời."))
            }
        }
        .onChange(of: engine.contacts.notice) { _, _ in busy.removeAll() }
        .onChange(of: engine.contacts.received) { _, new in
            busy.formIntersection(Set(new.map(\.id)).union(engine.contacts.sent.map(\.id)))
        }
    }
}

private struct RequestCard: View {
    let request: ContactsState.FriendRequest
    let received: Bool
    let busy: Bool
    let perform: (RequestAction) -> Void

    var body: some View {
        Form {
            Section {
                ContactCardHeader(avatar: request.avatar, name: request.name, status: statusLine) {
                    HStack(spacing: 10) {
                        if received {
                            Button("Từ chối") { perform(.decline) }.buttonStyle(.glass)
                            Button { perform(.accept) } label: { Label("Đồng ý", systemImage: "checkmark") }
                                .buttonStyle(.glassProminent)
                        } else {
                            Button("Thu hồi lời mời") { perform(.cancel) }.buttonStyle(.glass)
                        }
                        if busy { ProgressView().controlSize(.small) }
                    }
                    .controlSize(.large)
                    .disabled(busy)
                }
            }
            .listRowBackground(Color.clear)
            if !request.message.isEmpty {
                Section("Lời nhắn") {
                    Text(request.message)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.quaternary.opacity(0.6)))
                        .listRowBackground(Color.clear)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(request.name)
    }

    private var statusLine: String {
        let when = request.date.map { ContactsFormat.ago($0) }
        if received { return when.map { "Gửi lời mời \($0)" } ?? "Muốn kết bạn với bạn" }
        return when.map { "Bạn đã gửi lời mời \($0)" } ?? "Đang chờ người này chấp nhận"
    }
}

// MARK: - Add friend

/// Content column: the find-by-phone form. The result card is shown in the detail column (`AddFriendDetail`).
struct AddFriendForm: View {
    @Environment(ZaloEngine.self) private var engine
    @State private var phone = ""
    @FocusState private var phoneFocused: Bool

    private var search: ContactsState.Search { engine.contacts.search }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("🇻🇳 +84").font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .glassEffect(.regular, in: Capsule())
                    HStack(spacing: 6) {
                        Image(systemName: "phone.fill").foregroundStyle(.secondary)
                        TextField("Số điện thoại", text: $phone)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13.5))
                            .focused($phoneFocused)
                            .onSubmit(find)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .glassEffect(.regular, in: Capsule())
                }
                Button(action: find) {
                    if search.status == .searching { ProgressView().controlSize(.small) } else { Text("Tìm kiếm") }
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .disabled(phone.trimmingCharacters(in: .whitespaces).isEmpty || search.status == .searching)
                Text("Nhập số điện thoại Việt Nam, hoặc số quốc tế bắt đầu bằng +")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            .padding(14)
        }
        .columnTitle("Thêm bạn")
        .onAppear { phoneFocused = true }
        .onDisappear { engine.resetFriendSearch() }
    }

    private func find() { engine.findFriend(byPhone: phone) }
}

/// Detail column of "Thêm bạn": hint, progress, error or the found person.
struct AddFriendDetail: View {
    @Environment(ZaloEngine.self) private var engine

    private var search: ContactsState.Search { engine.contacts.search }

    var body: some View {
        switch search.status {
        case .idle:
            ContentUnavailableView("Thêm bạn", systemImage: "person.crop.circle.badge.plus",
                                   description: Text("Tìm bạn bằng số điện thoại để gửi lời mời kết bạn."))
        case .searching:
            ProgressView("Đang tìm…")
        case .error:
            ContentUnavailableView("Không tìm thấy", systemImage: "exclamationmark.triangle",
                                   description: Text(search.error ?? "Không tìm thấy người dùng."))
        case .found:
            if let user = search.user {
                FoundUserCard(user: user).id(user.id)
            }
        }
    }
}

/// The person found by phone, with the friend-request form (nothing is sent until the button is pressed).
private struct FoundUserCard: View {
    @Environment(ZaloEngine.self) private var engine
    let user: ContactsState.FoundUser
    @State private var message: String
    @State private var sending = false

    init(user: ContactsState.FoundUser) {
        self.user = user
        _message = State(initialValue: user.defaultMessage)
    }

    var body: some View {
        Form {
            Section {
                ContactCardHeader(avatar: user.avatar, name: user.name, secondaryName: user.zaloName,
                                  status: user.bio.isEmpty ? nil : user.bio) {
                    if user.isFriend {
                        Button { engine.openContactConversation(user.id) } label: {
                            Label("Nhắn tin", systemImage: "bubble.left.fill")
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                    }
                }
            }
            .listRowBackground(Color.clear)
            if let note {
                Section { Text(note).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
            } else {
                Section("Lời nhắn") {
                    TextEditor(text: $message)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .frame(height: 78)
                        .onChange(of: message) { _, new in
                            // UTF-16 units, like the official limit (an emoji counts 2).
                            if new.utf16.count > user.maxMessage { message = new.limitedUTF16(user.maxMessage) }
                        }
                    Text("\(message.utf16.count)/\(user.maxMessage)")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                Section {
                    Button {
                        sending = true
                        engine.sendFriendRequest(to: user.id, message: message.prefixUTF16(user.maxMessage))
                    } label: {
                        if sending { ProgressView().controlSize(.small) } else { Label("Gửi lời mời kết bạn", systemImage: "person.badge.plus") }
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .disabled(sending || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .frame(maxWidth: .infinity)
                }
                .listRowBackground(Color.clear)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(user.name)
        .onChange(of: engine.contacts.notice) { _, _ in sending = false }
    }

    /// Why no request can be sent, nil when the form applies.
    private var note: String? {
        if user.isSelf { return "Đây là tài khoản của bạn." }
        if user.isFriend { return "Đã là bạn bè." }
        if user.requesting { return "Người này đã gửi lời mời kết bạn cho bạn. Hãy chấp nhận ở mục “Lời mời kết bạn”." }
        if user.requested { return "Bạn đã gửi lời mời kết bạn. Đang chờ người này chấp nhận." }
        return nil
    }
}
