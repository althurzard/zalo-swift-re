import SwiftUI
import Translation

// MARK: - Inline translation card

/// Compact inline translation card rendered beneath a translatable message bubble.
struct MessageTranslationCard: View {
    let message: ChatMessage
    let state: MessageTranslationState
    let mine: Bool
    let allowCopy: Bool
    var onSelectLanguage: (String) -> Void
    var onCopy: (String) -> Void
    var onHide: () -> Void
    var onRetry: () -> Void

    @Environment(\.olazTextScale) private var textScale
    @State private var copied = false
    @State private var copiedResetTask: Task<Void, Never>?

    var showsCopyAction: Bool {
        guard allowCopy, case .translated = state else { return false }
        return true
    }

    var body: some View {
        Group {
            switch state {
            case .idle, .collapsed:
                EmptyView()

            case .translating:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Đang dịch…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    hideButton
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .cardChrome(radius: 12)

            case .translated(let text, let sourceCode, let targetCode):
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        languageMenu(sourceCode: sourceCode, targetCode: targetCode)
                        Spacer(minLength: 8)
                        if allowCopy {
                            copyButton(for: text)
                        }
                        hideButton
                    }
                    translatedBody(text)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .frame(maxWidth: 440, alignment: .leading)
                .cardChrome(radius: 14)

            case .failed(let errorMessage):
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                    Button("Thử lại") { onRetry() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(TintShapeStyle())
                    hideButton
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: 440, alignment: .leading)
                .cardChrome(radius: 12)
            }
        }
        .onDisappear { copiedResetTask?.cancel() }
    }

    private func languageMenu(sourceCode: String, targetCode: String) -> some View {
        Menu {
            ForEach(TranslationLanguage.curated) { language in
                Button {
                    onSelectLanguage(language.code)
                } label: {
                    if language.code == targetCode {
                        Label(language.displayName, systemImage: "checkmark")
                    } else {
                        Text(language.displayName)
                    }
                }
                .disabled(language.code == sourceCode)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "translate")
                    .font(.system(size: 10, weight: .semibold))
                Text("\(TranslationLanguage.badge(for: sourceCode)) → \(TranslationLanguage.badge(for: targetCode))")
                    .font(.system(size: 10.5, weight: .semibold))
                    .monospacedDigit()
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
            }
            .foregroundStyle(TintShapeStyle())
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(TintShapeStyle().opacity(0.13)))
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Đổi ngôn ngữ dịch")
        .accessibilityLabel("Ngôn ngữ dịch: \(TranslationLanguage.displayName(for: sourceCode)) sang \(TranslationLanguage.displayName(for: targetCode))")
    }

    private func copyButton(for text: String) -> some View {
        Button {
            onCopy(text)
            showCopiedFeedback()
        } label: {
            Label(
                copied ? "Đã chép" : "Chép",
                systemImage: copied ? "checkmark" : "doc.on.doc"
            )
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(copied ? AnyShapeStyle(Color.green) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Sao chép bản dịch")
        .accessibilityLabel("Chép bản dịch")
    }

    private var hideButton: some View {
        Button("Ẩn") {
            onHide()
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .help("Ẩn bản dịch")
        .accessibilityLabel("Ẩn bản dịch")
    }

    @ViewBuilder
    private func translatedBody(_ text: String) -> some View {
        let base = Text(ChatFormat.linkified(text, mine: false))
            .font(.system(size: 13.5 * textScale))
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading)

        if allowCopy {
            base.textSelection(.enabled)
        } else {
            base.textSelection(.disabled)
        }
    }

    private func showCopiedFeedback() {
        copied = true
        copiedResetTask?.cancel()
        copiedResetTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}

// MARK: - SwiftUI translationTask host

@MainActor
private struct OlazTranslationHostModifier: ViewModifier {
    @State private var store = MessageTranslationStore.shared

    func body(content: Content) -> some View {
        let store = self.store
        content
            .onAppear { store.registerHost() }
            .onDisappear { store.unregisterHost() }
            .translationTask(store.hostConfiguration) { @Sendable session in
                guard let request = await store.activeHostRequest() else {
                    await store.clearIdleHostConfiguration()
                    return
                }
                do {
                    let response = try await session.translate(request.masked.maskedText)
                    await store.completeHostRequest(request, response: response)
                } catch is CancellationError {
                    await store.cancelHostRequest(request.id)
                } catch {
                    await store.failHostRequest(request, message: AppleTranslationBackend.userFacingError(error))
                }
            }
    }
}

extension View {
    /// Hosts Apple Translation's `.translationTask` so language packs in `.supported` state can prompt for download.
    @MainActor
    func olazTranslationHost() -> some View {
        modifier(OlazTranslationHostModifier())
    }
}

// MARK: - Settings section

/// "Dịch tin nhắn" settings section, ready to embed inside the Settings `Form`.
struct TranslationSettingsSection: View {
    @AppStorage(MessageTranslationStore.targetLanguageDefaultsKey)
    private var targetLanguage = MessageTranslationStore.defaultTargetCode

    var body: some View {
        Section {
            Picker("Ngôn ngữ đích mặc định", selection: $targetLanguage) {
                ForEach(TranslationLanguage.curated) { language in
                    Text(language.displayName).tag(language.code)
                }
            }
            .onChange(of: targetLanguage) { _, newValue in
                MessageTranslationStore.shared.defaultTargetLanguage = newValue
            }
        } header: {
            Text("Dịch tin nhắn")
        } footer: {
            Text("Tin nhắn được dịch ngoại tuyến ngay trên máy bằng Apple Translation. Nội dung tin nhắn và bản dịch không được gửi ra ngoài và không lưu trên đĩa.")
        }
    }
}
