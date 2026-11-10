import SwiftUI

/// Window content: a splash while the client boots, the first-run setup (sign-in → phone sync → welcome) or the
/// main window. `setupPending` is what separates a fresh QR sign-in, which owes the user the sync and welcome steps,
/// from a restored session, which goes straight to the main window.
struct RootView: View {
    @Environment(ZaloEngine.self) private var engine
    @Environment(ShellModel.self) private var shell
    @AppStorage(OlazPrefs.didFinishSetup) private var didFinishSetup = false
    @AppStorage(OlazPrefs.setupPending) private var setupPending = false

    private enum Route: Equatable {
        case splash(String)
        case preparing(ZaloEngine.RuntimeSetup)
        case setup
        case main
    }

    private var route: Route {
        switch engine.phase {
        case .starting: .splash("Đang khởi động \(AppBrand.name)…")
        case .preparing(let setup): .preparing(setup)
        case .login: .setup
        case .signingIn: setupPending ? .setup : .splash("Đang đăng nhập và đồng bộ dữ liệu…")
        case .ready: setupPending ? .setup : .main
        }
    }

    var body: some View {
        ZStack {
            switch route {
            case .splash(let message):
                SplashView(message: message).transition(.opacity).fullBleedWindow()
            case .preparing(let setup):
                RuntimeSetupView(setup: setup).transition(.opacity).fullBleedWindow()
            case .setup:
                SetupFlowView(onFinish: finishSetup).transition(.opacity).fullBleedWindow()
            case .main:
                MainShellView()
                    .tourCoordinator()
                    // Composer actions may still ask (official confirm, screenshot "Chia sẻ") after their chat is left.
                    .composerPrompts()
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.4), value: route)
        .modifier(AssistantRevealer())
        // Incoming calls also ring during the first-run setup, so the banner / alerts sit around every route.
        .callOverlay()
        .onChange(of: engine.phase, initial: true) { _, phase in
            switch phase {
            case .login:
                // Whenever the QR screen is shown a fresh sign-in is under way (also after logging out).
                setupPending = true
                // ... and nothing of the previous account's window (open chat, unlocked hidden chats, search) may carry over.
                shell.reset()
                engine.conversationUI.relock()
            case .ready:
                // A restored session of someone who never saw the setup (older versions) is not sent through it.
                if !setupPending, !didFinishSetup { didFinishSetup = true }
            default:
                break
            }
        }
    }

    private func finishSetup(startTour: Bool) {
        didFinishSetup = true
        shell.endTour()
        setupPending = false
        guard startTour else { return }
        // Give the main window a moment to appear so the first coach mark has an anchor to attach to.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            if case .ready = engine.phase, !setupPending { shell.startTour() }
        }
    }
}

extension ZaloEngine.Phase {
    var isLogin: Bool {
        if case .login = self { return true }
        return false
    }
}

struct SplashView: View {
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            if let icon = OlazAppIcon.c.image {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 84, height: 84)
                    .accessibilityHidden(true)
            }
            Text(AppBrand.name)
                .font(.system(size: 22, weight: .bold))
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BrandBackground())
    }
}

/// First launch: Olaz fetches the official Zalo code it runs (see `ZaloRuntime`) before the QR sign-in.
struct RuntimeSetupView: View {
    @Environment(ZaloEngine.self) private var engine
    let setup: ZaloEngine.RuntimeSetup

    var body: some View {
        VStack(spacing: 16) {
            if let icon = OlazAppIcon.c.image {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 84, height: 84)
                    .accessibilityHidden(true)
            }
            Text("Chuẩn bị \(AppBrand.name)")
                .font(.system(size: 22, weight: .bold))
            Text("Lần đầu mở, \(AppBrand.name) tải phần lõi chính thức của Zalo PC từ máy chủ của VNG (khoảng 340 MB) và kiểm tra chữ ký số của VNG. Bạn không cần cài Zalo PC.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Group {
                if let failure = setup.failure {
                    VStack(spacing: 12) {
                        Label(failure, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Thử lại") { engine.retryRuntimeSetup() }
                            .buttonStyle(.glassProminent)
                            .keyboardShortcut(.defaultAction)
                    }
                } else {
                    progress
                }
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: 420)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BrandBackground())
    }

    @ViewBuilder private var progress: some View {
        VStack(spacing: 8) {
            if case .downloading(let received, let total?) = setup.step {
                ProgressView(value: Double(received), total: Double(total))
                Text("Đang tải Zalo PC… \(Self.size(received)) / \(Self.size(total))")
            } else {
                ProgressView().controlSize(.small)
                Text(status)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }

    private var status: String {
        switch setup.step {
        case .looking: "Đang chuẩn bị…"
        case .downloading(let received, _): "Đang tải Zalo PC… \(Self.size(received))"
        case .verifying: "Đang kiểm tra chữ ký của VNG…"
        case .installing: "Đang cài đặt…"
        }
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Soft accent-tinted backdrop that Liquid Glass surfaces refract.
struct BrandBackground: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            Circle().fill(.tint.opacity(0.18)).blur(radius: 100).frame(width: 620, height: 620).offset(x: -300, y: -200)
            Circle().fill(.tint.opacity(0.10)).blur(radius: 120).frame(width: 520, height: 520).offset(x: 320, y: 240)
            Circle().fill(.tint.opacity(0.08)).blur(radius: 110).frame(width: 440, height: 440).offset(x: 140, y: -280)
        }
        .ignoresSafeArea()
    }
}

private extension View {
    /// Setup and splash screens draw their own backdrop edge to edge: no window title, no toolbar backing.
    func fullBleedWindow() -> some View {
        toolbar(removing: .title)
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }
}

/// Opens the "Duyệt nháp" window when the assistant asks for it (draft notification, sidebar row).
private struct AssistantRevealer: ViewModifier {
    @Environment(ZaloEngine.self) private var engine
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onChange(of: engine.assistant.revealRequest) { _, request in
            guard request != nil else { return }
            openWindow(id: "assistant-drafts")
            engine.assistant.revealRequest = nil
        }
    }
}
