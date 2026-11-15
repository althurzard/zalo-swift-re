import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Native editor sheet for the logged-in user's profile: avatar, display name, gender, birthday, and bio/status.
struct ProfileEditorSheet: View {
    @Environment(ZaloEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss

    @State private var displayName = ""
    @State private var gender: ProfileGender = .male
    @State private var dob: Date = ProfileEditorSheet.defaultBirthday
    @State private var bio = ""
    @State private var pickedAvatar: GroupAvatarImage?

    @State private var initialName = ""
    @State private var initialGender: ProfileGender = .male
    @State private var initialDobKey = ""
    @State private var initialBio = ""
    @State private var hydrated = false

    @State private var refreshing = false
    @State private var saving = false
    @State private var errorMessage: String?

    private static let defaultBirthday: Date = {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: 1995, month: 1, day: 1)) ?? Date()
    }()

    private var trimmedName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var currentDobKey: String {
        ZaloEngine.Profile.formatDOB(dob)
    }

    private var profileFieldsChanged: Bool {
        trimmedName != initialName || gender != initialGender || currentDobKey != initialDobKey
    }

    private var bioChanged: Bool {
        bio != initialBio
    }

    private var hasChanges: Bool {
        pickedAvatar != nil || profileFieldsChanged || bioChanged
    }

    private var canSave: Bool {
        !saving && !trimmedName.isEmpty && hasChanges
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                avatarSection
                basicInfoSection
                bioSection
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            footer
        }
        .frame(width: 460, height: 500)
        .task {
            if let existing = engine.profile {
                apply(existing, force: !hydrated)
            }
            refreshing = true
            let fresh = await engine.refreshMyProfile()
            refreshing = false
            if let fresh, !hasChanges {
                apply(fresh, force: true)
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Hồ sơ của tôi")
                    .font(.headline)
                if refreshing {
                    Text("Đang đồng bộ thông tin từ Zalo…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var avatarSection: some View {
        Section {
            HStack(spacing: 16) {
                avatarPreview
                    .frame(width: 68, height: 68)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(.quaternary, lineWidth: 1))

                VStack(alignment: .leading, spacing: 6) {
                    Text(trimmedName.isEmpty ? "Tài khoản Zalo" : trimmedName)
                        .font(.system(size: 15, weight: .semibold))
                    if let phone = engine.profile?.phone, !phone.isEmpty {
                        Text(phone)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        Button("Đổi ảnh đại diện…") {
                            pickAvatarFromDisk()
                        }
                        .disabled(saving)
                        if pickedAvatar != nil {
                            Button("Hoàn tác") {
                                pickedAvatar = nil
                                errorMessage = nil
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .disabled(saving)
                        }
                    }
                }
                Spacer()
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var avatarPreview: some View {
        if let image = pickedAvatar?.image {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else {
            RemoteAvatar(url: engine.profile?.avatar, name: trimmedName.isEmpty ? "Zalo" : trimmedName, size: 68)
        }
    }

    private var basicInfoSection: some View {
        Section("Thông tin cá nhân") {
            TextField("Tên hiển thị", text: $displayName)
                .disabled(saving)

            Picker("Giới tính", selection: $gender) {
                ForEach(ProfileGender.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .disabled(saving)

            DatePicker("Ngày sinh", selection: $dob, in: ...Date(), displayedComponents: .date)
                .disabled(saving)
        }
    }

    private var bioSection: some View {
        Section("Lời giới thiệu") {
            TextField("Nhập lời giới thiệu bản thân…", text: $bio, axis: .vertical)
                .lineLimit(2...4)
                .disabled(saving)
        }
    }

    private var footer: some View {
        HStack {
            if saving {
                ProgressView()
                    .controlSize(.small)
                Text("Đang lưu thay đổi…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Hủy") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(saving)
            Button("Lưu") {
                Task { await save() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canSave)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func apply(_ profile: ZaloEngine.Profile, force: Bool) {
        guard force || !hydrated else { return }
        hydrated = true
        let name = profile.displayName
        let parsedGender = profile.gender.flatMap(ProfileGender.init(rawValue:)) ?? .male
        let parsedDob = profile.dobDate ?? Self.defaultBirthday
        let parsedBio = profile.status ?? ""

        displayName = name
        gender = parsedGender
        dob = parsedDob
        bio = parsedBio

        initialName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        initialGender = parsedGender
        initialDobKey = ZaloEngine.Profile.formatDOB(parsedDob)
        initialBio = parsedBio
    }

    private func pickAvatarFromDisk() {
        let panel = NSOpenPanel()
        panel.title = "Chọn ảnh đại diện"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        switch GroupAvatarImage.make(from: url) {
        case .success(let img):
            pickedAvatar = img
            errorMessage = nil
        case .failure(let err):
            errorMessage = err.text
        }
    }

    private func save() async {
        guard canSave else { return }
        saving = true
        errorMessage = nil
        defer { saving = false }

        if let avatar = pickedAvatar {
            let res = await engine.updateMyAvatar(jpegData: avatar.jpeg, width: avatar.side, height: avatar.side)
            if case .failure(let msg) = res {
                errorMessage = msg
                return
            }
            pickedAvatar = nil
        }

        if profileFieldsChanged {
            let res = await engine.updateMyProfile(name: trimmedName, gender: gender.rawValue, dob: dob)
            if case .failure(let msg) = res {
                errorMessage = msg
                return
            }
            initialName = trimmedName
            initialGender = gender
            initialDobKey = currentDobKey
        }

        if bioChanged {
            let res = await engine.updateMyStatus(bio)
            if case .failure(let msg) = res {
                errorMessage = msg
                return
            }
            initialBio = bio
        }

        dismiss()
    }
}
