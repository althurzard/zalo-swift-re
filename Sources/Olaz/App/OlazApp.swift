import AppKit
import SwiftUI

struct OlazApp: App {
    @State private var engine = ZaloEngine()
    @State private var shell = ShellModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .olazAppearance(engine: engine, shell: shell)
                // While the inspector shows, the window may not get narrower than what keeps the chat usable beside it.
                .frame(minWidth: shell.holdsInspectorRoom ? InspectorRoom.windowMinWidthWithInspector : InspectorRoom.windowMinWidth, minHeight: 620)
                .task { engine.start() }
        }
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        .commands {
            OlazCommands(engine: engine, shell: shell)
            CommandMenu("Tài khoản") {
                Button("Lấy mã QR mới") { engine.refreshQR() }
                    .keyboardShortcut("R", modifiers: [.command, .shift])
                    .disabled(!engine.phase.isLogin)
                Button("Đăng xuất") { engine.logOut() }
                    .keyboardShortcut("L", modifiers: [.command, .shift])
                    .disabled(engine.profile == nil)
            }
            AssistantCommands(pending: engine.assistant.pendingCount)
            CommandMenu("Nhà phát triển") {
                Toggle("Hiện renderer Zalo chính thức", isOn: $engine.isDebugRendererVisible)
            }
        }

        Window("Duyệt nháp trả lời", id: "assistant-drafts") {
            AssistantDraftsView()
                .olazAppearance(engine: engine, shell: shell)
        }
        .defaultSize(width: 520, height: 640)

        Settings {
            SettingsView()
                .olazAppearance(engine: engine, shell: shell)
        }
    }
}

// MARK: - Appearance

/// Applies what Settings ▸ Giao diện picks (mode, accent, message text size, Dock icon) plus the shared environment, so the
/// main window and the Settings window always look the same and react live.
private struct OlazAppearance: ViewModifier {
    let engine: ZaloEngine
    let shell: ShellModel
    @AppStorage("olaz.appearance") private var appearance = Appearance.system
    @AppStorage(OlazPrefs.accent) private var accent = OlazAccent.blue
    @AppStorage(OlazPrefs.textSize) private var textSize = OlazTextSize.standard
    @AppStorage(OlazPrefs.appIcon) private var appIcon = OlazAppIcon.c

    func body(content: Content) -> some View {
        content
            .environment(engine)
            .environment(shell)
            .environment(\.locale, Locale(identifier: "vi_VN"))
            .environment(\.olazTextScale, textSize.scale)
            .tint(accent.color)
            .preferredColorScheme(appearance.colorScheme)
            // `initial` restores the chosen Dock icon on launch; the Settings window repeats it harmlessly.
            .onChange(of: appIcon, initial: true) { _, icon in icon.applyToDock() }
    }
}

extension View {
    /// Root styling and environment shared by every window of the app (see `OlazAppearance`).
    func olazAppearance(engine: ZaloEngine, shell: ShellModel) -> some View {
        modifier(OlazAppearance(engine: engine, shell: shell))
    }
}

extension OlazAppIcon {
    /// Shows this icon in the Dock. The primary icon (`c`) is the bundle's own, restored by clearing the override; outside a
    /// bundle (`swift run`) there is none to restore, so the image is set instead. The override lasts until the app quits.
    @MainActor func applyToDock() {
        let isBundled = Bundle.main.bundleURL.pathExtension == "app"
        NSApp.applicationIconImage = self == .c && isBundled ? nil : image
    }
}

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "Theo hệ thống"
        case .light: "Sáng"
        case .dark: "Tối"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// "Trợ lý AI" menu: opens the draft review window.
private struct AssistantCommands: Commands {
    let pending: Int
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Trợ lý AI") {
            Button(pending > 0 ? "Duyệt nháp (\(pending))" : "Duyệt nháp") { openWindow(id: "assistant-drafts") }
                .keyboardShortcut("D", modifiers: [.command, .shift])
        }
    }
}
