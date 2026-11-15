import SwiftUI

/// Account row pinned to the bottom of the sidebar: avatar, name and the phone-sync state. It opens the account menu.
struct SidebarAccountFooter: View {
    @Environment(ZaloEngine.self) private var engine
    @State private var hovering = false
    @State private var showingProfileEditor = false

    /// A phone → PC sync is running (the phone has been pinged, or history is arriving).
    private var syncing: Bool {
        switch engine.transfer?.phase {
        case .waitingForPhone, .transferring: true
        default: false
        }
    }

    private var statusText: String {
        guard syncing else { return "Đã kết nối" }
        if let progress = engine.transfer?.progress { return "Đang đồng bộ… \(Int((progress * 100).rounded()))%" }
        return "Đang đồng bộ…"
    }

    private var name: String { engine.profile?.displayName ?? "Tài khoản của tôi" }

    var body: some View {
        Menu {
            Button(name) {}.disabled(true)
            Button("Hồ sơ của tôi…", systemImage: "person.crop.circle") { showingProfileEditor = true }
                .disabled(engine.profile == nil)
            Button("Đồng bộ tin nhắn từ điện thoại…", systemImage: "arrow.triangle.2.circlepath") { engine.startTransfer() }
                .disabled(!engine.canStartTransfer || engine.transfer != nil)
            SettingsLink { Label("Cài đặt…", systemImage: "gearshape") }
            Divider()
            Button("Đăng xuất", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { engine.logOut() }
        } label: {
            HStack(spacing: 9) {
                RemoteAvatar(url: engine.profile?.avatar, name: name, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 5) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 6))
                            .foregroundStyle(syncing ? AnyShapeStyle(.tint) : AnyShapeStyle(.green))
                            .symbolEffect(.pulse, isActive: syncing)
                        Text(statusText).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .help("Tài khoản và đồng bộ")
        .accessibilityLabel("Tài khoản \(name), \(statusText)")
        .sheet(isPresented: $showingProfileEditor) {
            ProfileEditorSheet()
                .environment(engine)
        }
    }
}
