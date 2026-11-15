import SwiftUI

/// Official Zalo privacy sections (skipping 2FA OTP in Phase 1) and entry point to the blocked-users sheet.
struct PrivacySettingsSections: View {
    @Environment(ZaloEngine.self) private var engine
    @State private var showingBlocklist = false

    var body: some View {
        Group {
            if engine.privacyLoading && engine.privacySettings == nil {
                Section("Quyền riêng tư") {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Đang tải thiết lập quyền riêng tư…").foregroundStyle(.secondary)
                    }
                }
            } else {
                personalSection
                messagingAndCallsSection
                friendSourcesSection
                blocklistSection
                if let error = engine.privacyError {
                    Section {
                        HStack {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Spacer()
                            Button("Thử lại") {
                                Task { await engine.loadPrivacySettings(force: true) }
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
        .task(id: engine.profile?.userId) {
            if engine.profile != nil {
                if engine.privacySettings == nil {
                    await engine.loadPrivacySettings()
                }
                if !engine.blockedUsersLoaded {
                    _ = await engine.loadBlockedUsers()
                }
            }
        }
        .sheet(isPresented: $showingBlocklist) {
            BlockedUsersSheet()
                .environment(engine)
        }
    }

    private var personalSection: some View {
        Section("Cá nhân") {
            Picker("Hiển thị ngày sinh", selection: enumBinding(.viewBirthday, keyPath: \.viewBirthday)) {
                ForEach(BirthdayVisibility.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            Toggle("Hiển thị trạng thái truy cập", isOn: boolBinding(.showOnlineStatus, keyPath: \.showOnlineStatus))
            Toggle("Hiện trạng thái “Đã xem”", isOn: boolBinding(.displaySeenStatus, keyPath: \.displaySeenStatus))
        }
        .disabled(engine.profile == nil)
    }

    private var messagingAndCallsSection: some View {
        Section("Tin nhắn và cuộc gọi") {
            Picker("Cho phép nhắn tin", selection: enumBinding(.receiveMessage, keyPath: \.receiveMessage)) {
                ForEach(MessageStrangerOption.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            Picker("Cho phép gọi điện", selection: enumBinding(.acceptStrangerCall, keyPath: \.acceptStrangerCall)) {
                ForEach(CallStrangerOption.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
        }
        .disabled(engine.profile == nil)
    }

    private var friendSourcesSection: some View {
        Section("Nguồn tìm kiếm và kết bạn") {
            Toggle(
                "Cho phép người lạ tìm thấy và kết bạn qua số điện thoại",
                isOn: boolBinding(.addFriendViaPhone, keyPath: \.addFriendViaPhone)
            )
            Toggle("Mã QR của tôi", isOn: boolBinding(.addFriendViaQR, keyPath: \.addFriendViaQR))
            Toggle("Nhóm chung", isOn: boolBinding(.addFriendViaGroup, keyPath: \.addFriendViaGroup))
            Toggle("Danh thiếp Zalo", isOn: boolBinding(.addFriendViaContact, keyPath: \.addFriendViaContact))
            Toggle(
                "Gợi ý “Có thể bạn quen”",
                isOn: boolBinding(.displayOnRecommendFriend, keyPath: \.displayOnRecommendFriend)
            )
        }
        .disabled(engine.profile == nil)
    }

    private var blocklistSection: some View {
        Section("Chặn tin nhắn và cuộc gọi") {
            LabeledContent("Danh sách đã chặn") {
                HStack(spacing: 10) {
                    if engine.blockedUsersLoaded {
                        Text("\(engine.blockedUsers.count)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Button("Xem danh sách…") {
                        showingBlocklist = true
                    }
                    .disabled(engine.profile == nil)
                }
            }
        }
    }

    private func boolBinding(_ key: PrivacySettingKey, keyPath: KeyPath<PrivacySettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { (engine.privacySettings ?? PrivacySettings())[keyPath: keyPath] },
            set: { newValue in
                Task { await engine.updatePrivacySetting(key, enabled: newValue) }
            }
        )
    }

    private func enumBinding<Option: RawRepresentable>(
        _ key: PrivacySettingKey,
        keyPath: KeyPath<PrivacySettings, Option>
    ) -> Binding<Option> where Option.RawValue == Int {
        Binding(
            get: { (engine.privacySettings ?? PrivacySettings())[keyPath: keyPath] },
            set: { newValue in
                Task { await engine.updatePrivacySetting(key, value: newValue.rawValue) }
            }
        )
    }
}

/// Modal list of blocked contacts with per-row unblock action (`dSSf.fetchBlockedFriendList` + `UiPd.blockFriend`).
struct BlockedUsersSheet: View {
    @Environment(ZaloEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss

    @State private var loading = false
    @State private var busyIds: Set<String> = []
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Danh sách đã chặn")
                    .font(.headline)
                Spacer()
                if loading {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            Group {
                if loading && engine.blockedUsers.isEmpty {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Đang tải danh sách đã chặn…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if engine.blockedUsers.isEmpty {
                    ContentUnavailableView(
                        "Chưa chặn ai",
                        systemImage: "hand.raised.slash",
                        description: Text("Những người bạn chặn tin nhắn hoặc cuộc gọi sẽ hiển thị tại đây.")
                    )
                } else {
                    List(engine.blockedUsers) { user in
                        row(user)
                    }
                    .listStyle(.inset)
                }
            }

            if let errorMessage {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(errorMessage).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }

            Divider()

            HStack {
                Spacer()
                Button("Đóng") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 420, height: 420)
        .task {
            loading = true
            _ = await engine.loadBlockedUsers()
            loading = false
        }
    }

    private func row(_ user: BlockedUser) -> some View {
        HStack(spacing: 12) {
            RemoteAvatar(url: user.avatar, name: user.resolvedName, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(user.resolvedName)
                    .font(.system(size: 13.5, weight: .medium))
                    .lineLimit(1)
                if !user.zaloName.isEmpty && user.zaloName != user.resolvedName {
                    Text(user.zaloName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button("Bỏ chặn") {
                unblock(user)
            }
            .controlSize(.small)
            .disabled(busyIds.contains(user.userId))
        }
        .padding(.vertical, 4)
    }

    private func unblock(_ user: BlockedUser) {
        guard !busyIds.contains(user.userId) else { return }
        busyIds.insert(user.userId)
        errorMessage = nil
        Task {
            let outcome = await engine.setBlocked(uid: user.userId, blocked: false)
            busyIds.remove(user.userId)
            if case .failure(let msg) = outcome {
                errorMessage = msg
            }
        }
    }
}
