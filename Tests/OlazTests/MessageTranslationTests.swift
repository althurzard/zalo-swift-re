import AppKit
import Foundation
import SwiftUI
import Testing
import Translation
@testable import Olaz

@Suite @MainActor
struct MessageTranslationTests {
    // MARK: - Helpers

    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "app.olaz.tests.translation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (defaults, suite)
    }

    private func makeMessage(
        id: String = "m1",
        conversationId: String = "c1",
        kind: ChatMessage.Kind = .text,
        text: String = "Hello world",
        mentions: [Mention] = [],
        isE2EE: Bool = false,
        isProtected: Bool = false
    ) -> ChatMessage {
        var menu = MessageMenu()
        menu.isProtected = isProtected
        return ChatMessage(
            id: id,
            conversationId: conversationId,
            senderId: "u2",
            senderName: "Tester",
            senderAvatar: nil,
            isMine: false,
            kind: kind,
            text: text,
            date: Date(timeIntervalSince1970: 1_700_000_000),
            status: .sent,
            quote: nil,
            reactions: [],
            isE2EE: isE2EE,
            mentions: mentions,
            menu: menu
        )
    }

    private func settle(timeout: Duration = .seconds(2), _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(15))
        }
    }

    // MARK: - NLLanguageRecognizer detection

    @Test func detectsCuratedLanguagesAndIgnoresNonLinguisticNoise() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MessageTranslationStore(defaults: defaults, backend: MockTranslator())

        #expect(store.detectLanguage(of: "Hello, how are you doing today?") == "en")
        #expect(store.detectLanguage(of: "Xin chào các bạn hôm nay trời rất đẹp") == "vi")
        #expect(store.detectLanguage(of: "你好，很高兴认识你，请问明天几点开会？") == "zh-Hans")
        #expect(store.detectLanguage(of: "繁體中文測試內容，請問明天幾點開會？") == "zh-Hant")
        #expect(store.detectLanguage(of: "안녕하세요 만나서 정말 반갑습니다") == "ko")
        #expect(store.detectLanguage(of: "こんにちは、お元気ですか？") == "ja")
        #expect(store.detectLanguage(of: "สวัสดีครับ วันนี้สบายดีไหมครับ") == "th")
        #expect(store.detectLanguage(of: "Bonjour tout le monde, comment allez-vous ?") == "fr")
        #expect(store.detectLanguage(of: "Guten Tag, wie geht es Ihnen heute?") == "de")
        #expect(store.detectLanguage(of: "Hola buenos días, ¿cómo están todos?") == "es")

        // URLs and @mentions must not confuse language detection.
        #expect(store.detectLanguage(of: "https://example.com/path @NguyenVanA Bonjour tout le monde") == "fr")

        // Empty, emoji-only, number-only, or URL-only strings yield nil.
        #expect(store.detectLanguage(of: "") == nil)
        #expect(store.detectLanguage(of: "👍🔥🎉") == nil)
        #expect(store.detectLanguage(of: "123456789") == nil)
        #expect(store.detectLanguage(of: "https://example.com/123 @alice") == nil)
    }

    // MARK: - Mention / URL masking roundtrip

    @Test func masksAndRestoresMentionsAndURLsIncludingUTF16OffsetsAndDollarSigns() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MessageTranslationStore(defaults: defaults, backend: MockTranslator())

        // Leading emoji (2 UTF-16 code units) shifts UTF-16 offset of the multi-word @mention.
        let text = "👋 @Nguyễn Văn A please open https://example.com/pay?amt=$50&x=1 and contact bob@example.com or @team_lead!"
        let mentionText = "@Nguyễn Văn A"
        let utf16Pos = ("👋 " as NSString).length
        let utf16Len = (mentionText as NSString).length
        let mentions = [Mention(uid: "u1", pos: utf16Pos, len: utf16Len)]

        let masked = store.maskProtectedSpans(in: text, mentions: mentions)
        #expect(masked.spans.count == 4)
        #expect(masked.spans.map(\.original) == [
            "@Nguyễn Văn A",
            "https://example.com/pay?amt=$50&x=1",
            "bob@example.com",
            "@team_lead",
        ])
        #expect(masked.maskedText == "👋 [[0]] please open [[1]] and contact [[2]] or [[3]]!")
        #expect(!masked.detectionText.contains("https://"))
        #expect(!masked.detectionText.contains("Nguyễn"))

        // Exact restoration roundtrip (including $50 in URL without regex template corruption).
        let restored = store.restoreProtectedSpans(in: masked.maskedText, spans: masked.spans)
        #expect(restored == text)

        // Tolerates models adding spaces around placeholder indices.
        let spacedModelOutput = "👋 [[ 0 ]] hãy mở [[ 1 ]] và liên hệ [[ 2 ]] hoặc [[ 3 ]]!"
        let restoredSpaced = store.restoreProtectedSpans(in: spacedModelOutput, spans: masked.spans)
        #expect(restoredSpaced == "👋 @Nguyễn Văn A hãy mở https://example.com/pay?amt=$50&x=1 và liên hệ bob@example.com hoặc @team_lead!")
    }

    @Test func maskingAvoidsCollisionWithLiteralBracketsInMessage() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MessageTranslationStore(defaults: defaults, backend: MockTranslator())

        let text = "Literal [[0]] stays literal while https://zalo.me is masked"
        let masked = store.maskProtectedSpans(in: text)
        #expect(masked.spans.count == 1)
        #expect(masked.spans[0].placeholder != "[[0]]")
        #expect(masked.maskedText.contains("Literal [[0]] stays literal"))

        let restored = store.restoreProtectedSpans(in: masked.maskedText, spans: masked.spans)
        #expect(restored == text)
    }

    // MARK: - Store lifecycle & cache behavior

    @Test func storeTransitionsIdleTranslatedCollapsedAndBackFromCache() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let mock = MockTranslator(delay: .milliseconds(25)) { text, src, tgt in
            .translated(text: "VI:\(text)", sourceCode: src ?? "en", targetCode: tgt)
        }
        let store = MessageTranslationStore(defaults: defaults, backend: mock)
        let msg = makeMessage(id: "m1", conversationId: "c1", text: "Good morning @Lan")

        #expect(store.state(for: msg) == .idle)

        store.translate(message: msg)
        #expect(store.state(for: msg) == .translating)

        await settle { store.state(for: msg) != .translating }
        #expect(store.state(for: msg) == .translated(text: "VI:Good morning @Lan", sourceCode: "en", targetCode: "vi"))
        #expect(mock.callCount == 1)

        // Collapsing hides the card while preserving cached output.
        store.collapse(conversationId: "c1", messageId: "m1")
        #expect(store.state(for: msg) == .collapsed)

        // Re-translating restores instantaneously from cache without invoking backend again.
        store.translate(message: msg)
        #expect(store.state(for: msg) == .translated(text: "VI:Good morning @Lan", sourceCode: "en", targetCode: "vi"))
        #expect(mock.callCount == 1)

        // Switching target language creates a separate cache entry keyed by targetCode.
        store.translate(message: msg, targetCode: "ja")
        await settle {
            if case .translated(_, _, let tgt) = store.state(for: msg) { return tgt == "ja" }
            return false
        }
        #expect(store.state(for: msg) == .translated(text: "VI:Good morning @Lan", sourceCode: "en", targetCode: "ja"))
        #expect(store.state(conversationId: "c1", messageId: "m1", targetCode: "vi") == .translated(text: "VI:Good morning @Lan", sourceCode: "en", targetCode: "vi"))
        #expect(mock.callCount == 2)
    }

    @Test func clearAllAndAccountSwitchingPurgeTranslationsAndCancelInFlight() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let mock = MockTranslator(delay: .milliseconds(80)) { text, src, tgt in
            .translated(text: "[\(tgt)] \(text)", sourceCode: src ?? "en", targetCode: tgt)
        }
        let store = MessageTranslationStore(defaults: defaults, backend: mock)
        store.syncActiveAccount("account-1")

        let m1 = makeMessage(id: "m1", conversationId: "c1", text: "Hello everyone in this chat")
        let m2 = makeMessage(id: "m2", conversationId: "c2", text: "See you tomorrow morning")

        store.translate(message: m1)
        await settle { store.state(for: m1) != .translating }
        #expect(store.state(for: m1).showsCard)

        // Start an in-flight translation and immediately clearAll() before it resolves.
        store.translate(message: m2)
        #expect(store.state(for: m2) == .translating)
        store.clearAll()
        #expect(store.state(for: m1) == .idle)
        #expect(store.state(for: m2) == .idle)

        // Wait past the mock delay to confirm late completion does not repopulate cache.
        try? await Task.sleep(for: .milliseconds(110))
        #expect(store.state(for: m2) == .idle)

        // Switching account clears previous account's translations.
        store.syncActiveAccount("account-1")
        store.translate(message: m1)
        await settle { store.state(for: m1) != .translating }
        #expect(store.state(for: m1).showsCard)

        store.syncActiveAccount("account-2")
        #expect(store.state(for: m1) == .idle)

        // Logging out (nil userId) also clears translations.
        store.translate(message: m1)
        await settle { store.state(for: m1) != .translating }
        #expect(store.state(for: m1).showsCard)
        store.syncActiveAccount(nil)
        #expect(store.state(for: m1) == .idle)
    }

    @Test func clearConversationRemovesOnlyTargetedConversation() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let mock = MockTranslator { text, src, tgt in
            .translated(text: "T:\(text)", sourceCode: src ?? "en", targetCode: tgt)
        }
        let store = MessageTranslationStore(defaults: defaults, backend: mock)
        let hidden = makeMessage(id: "m1", conversationId: "hidden-conv", text: "Secret message text")
        let regular = makeMessage(id: "m2", conversationId: "normal-conv", text: "Public message text")

        store.translate(message: hidden)
        store.translate(message: regular)
        await settle {
            if case .translated = store.state(for: hidden), case .translated = store.state(for: regular) { return true }
            return false
        }

        store.clearConversation("hidden-conv")
        #expect(store.state(for: hidden) == .idle)
        #expect(store.state(for: regular) == .translated(text: "T:Public message text", sourceCode: "en", targetCode: "vi"))
    }

    @Test func hidingConversationPurgesTranslationsImmediatelyAndOnConvActionsUpdates() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let mock = MockTranslator { text, src, tgt in
            .translated(text: "T:\(text)", sourceCode: src ?? "en", targetCode: tgt)
        }
        let store = MessageTranslationStore(defaults: defaults, backend: mock)
        let engine = ZaloEngine()

        let localHideMsg = makeMessage(id: "m1", conversationId: "conv-local-hide", text: "Private local conversation")
        let remoteHideMsg = makeMessage(id: "m2", conversationId: "conv-remote-hide", text: "Private remote conversation")
        let flagHideMsg = makeMessage(id: "m3", conversationId: "conv-flag-hide", text: "Private flag conversation")
        let regularMsg = makeMessage(id: "m4", conversationId: "conv-regular", text: "Public regular conversation")

        for msg in [localHideMsg, remoteHideMsg, flagHideMsg, regularMsg] {
            store.translate(message: msg)
        }
        await settle {
            [localHideMsg, remoteHideMsg, flagHideMsg, regularMsg].allSatisfy {
                if case .translated = store.state(for: $0) { return true }
                return false
            }
        }

        // 1. Local hide result removes UI selection & purges translations BEFORE convActions publishes hiddenIds.
        engine.conversationUI.unlock("conv-local-hide")
        #expect(!engine.conversationActions.isHidden("conv-local-hide"))
        engine.applyHiddenConversation("conv-local-hide", translationStore: store)
        #expect(engine.conversationUI.removal?.ids.contains("conv-local-hide") == true)
        #expect(!engine.conversationUI.isUnlocked("conv-local-hide"))
        #expect(store.state(for: localHideMsg) == .idle)
        #expect(store.state(for: remoteHideMsg).showsCard)
        #expect(store.state(for: regularMsg).showsCard)

        // 2. Cross-device or delayed hidden.ids update purges newly hidden conversation without touching visible ones.
        engine.handleConversationActions(
            state: [
                "convActions": [
                    "hidden": [
                        "enabled": true,
                        "hasPin": true,
                        "ids": ["conv-local-hide", "conv-remote-hide"]
                    ]
                ]
            ],
            translationStore: store
        )
        #expect(store.state(for: remoteHideMsg) == .idle)
        #expect(store.state(for: flagHideMsg).showsCard)
        #expect(store.state(for: regularMsg).showsCard)

        // 3. Flag bit .hidden (even without hidden.ids entry) also purges newly hidden conversations.
        engine.handleConversationActions(
            state: [
                "convActions": [
                    "flags": [
                        "conv-flag-hide": ConversationActionFlags.hidden.rawValue
                    ],
                    "left": [:],
                    "markUnread": false
                ]
            ],
            translationStore: store
        )
        #expect(store.state(for: flagHideMsg) == .idle)
        #expect(store.state(for: regularMsg) == .translated(text: "T:Public regular conversation", sourceCode: "en", targetCode: "vi"))

        // 4. Re-translating an unlocked already-hidden conversation is not wiped by routine convActions updates
        // that do not newly transition the ID into hidden, whereas unhide -> re-hide purges again.
        store.translate(message: remoteHideMsg)
        await settle {
            if case .translated = store.state(for: remoteHideMsg) { return true }
            return false
        }
        engine.handleConversationActions(
            state: [
                "convActions": [
                    "hidden": [
                        "enabled": true,
                        "hasPin": true,
                        "ids": ["conv-local-hide", "conv-remote-hide"]
                    ]
                ]
            ],
            translationStore: store
        )
        #expect(store.state(for: remoteHideMsg).showsCard)

        engine.handleConversationActions(
            state: [
                "convActions": [
                    "hidden": [
                        "enabled": true,
                        "hasPin": true,
                        "ids": ["conv-local-hide"]
                    ]
                ]
            ],
            translationStore: store
        )
        #expect(store.state(for: remoteHideMsg).showsCard)

        engine.handleConversationActions(
            state: [
                "convActions": [
                    "hidden": [
                        "enabled": true,
                        "hasPin": true,
                        "ids": ["conv-local-hide", "conv-remote-hide"]
                    ]
                ]
            ],
            translationStore: store
        )
        #expect(store.state(for: remoteHideMsg) == .idle)

        // 5. Default 1-arg handleConversationActions(state:) routes through MessageTranslationStore.shared.
        let sharedConvId = "conv-shared-hidden-\(UUID().uuidString)"
        let sharedMsg = makeMessage(id: "m-shared", conversationId: sharedConvId, text: "Confidential shared store text")
        defer { MessageTranslationStore.shared.clearConversation(sharedConvId) }
        MessageTranslationStore.shared.translate(message: sharedMsg)
        #expect(MessageTranslationStore.shared.state(for: sharedMsg) != .idle)

        engine.handleConversationActions(
            state: [
                "convActions": [
                    "hidden": [
                        "enabled": true,
                        "hasPin": true,
                        "ids": ["conv-local-hide", "conv-remote-hide", sharedConvId]
                    ]
                ]
            ]
        )
        #expect(MessageTranslationStore.shared.state(for: sharedMsg) == .idle)
    }

    // MARK: - Eligibility & default target preference

    @Test func translatableTextCoversTextLinkPhotoVideoIncludingE2EE() {
        let e2eeText = makeMessage(kind: .text, text: "Encrypted hello", isE2EE: true)
        #expect(e2eeText.translatableText == "Encrypted hello")

        let linkWithComment = makeMessage(
            kind: .link(title: "Title", url: URL(string: "https://example.com"), thumbnail: nil),
            text: "Check this article"
        )
        #expect(linkWithComment.translatableText == "Check this article")

        let bareLinkNoTitle = makeMessage(
            kind: .link(title: "", url: URL(string: "https://example.com"), thumbnail: nil),
            text: "[Link] https://example.com"
        )
        #expect(bareLinkNoTitle.translatableText == nil)

        let photoCaption = makeMessage(kind: .photo(url: nil, width: 10, height: 10), text: "Sunset photo", isE2EE: true)
        #expect(photoCaption.translatableText == "Sunset photo")

        let photoFallback = makeMessage(kind: .photo(url: nil, width: 10, height: 10), text: "[Hình ảnh]")
        #expect(photoFallback.translatableText == nil)

        let videoCaption = makeMessage(kind: .video(thumbnail: nil, duration: 5, url: nil), text: "Meeting recording")
        #expect(videoCaption.translatableText == "Meeting recording")

        let videoFallback = makeMessage(kind: .video(thumbnail: nil, duration: 5, url: nil), text: "[Video]")
        #expect(videoFallback.translatableText == nil)

        #expect(makeMessage(kind: .recalled, text: "Tin nhắn đã được thu hồi").translatableText == nil)
        #expect(makeMessage(kind: .sticker(url: nil), text: "[Sticker]").translatableText == nil)
        #expect(makeMessage(kind: .file(name: "a.pdf", size: 10, url: nil), text: "[Tệp]").translatableText == nil)
    }

    @Test func defaultTargetLanguagePersistsToDefaults() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = MessageTranslationStore(defaults: defaults, backend: MockTranslator())
        #expect(store.defaultTargetLanguage == "vi")

        store.defaultTargetLanguage = "ja"
        #expect(defaults.string(forKey: MessageTranslationStore.targetLanguageDefaultsKey) == "ja")

        let reloaded = MessageTranslationStore(defaults: defaults, backend: MockTranslator())
        #expect(reloaded.defaultTargetLanguage == "ja")
    }

    // MARK: - Protected-copy gating

    @Test func protectedCopyGatingHidesCopyActionWhenIsProtectedIsTrue() {
        let protectedMsg = makeMessage(text: "Confidential message", isProtected: true)
        let normalMsg = makeMessage(text: "Shareable message", isProtected: false)

        #expect(MessageTranslationStore.allowsCopy(for: protectedMsg) == false)
        #expect(MessageTranslationStore.allowsCopy(for: normalMsg) == true)

        let translatedState = MessageTranslationState.translated(
            text: "Tin nhắn mật",
            sourceCode: "en",
            targetCode: "vi"
        )

        let protectedCard = MessageTranslationCard(
            message: protectedMsg,
            state: translatedState,
            mine: false,
            allowCopy: MessageTranslationStore.allowsCopy(for: protectedMsg),
            onSelectLanguage: { _ in },
            onCopy: { _ in },
            onHide: {},
            onRetry: {}
        )
        #expect(protectedCard.showsCopyAction == false)

        let allowedCard = MessageTranslationCard(
            message: normalMsg,
            state: translatedState,
            mine: false,
            allowCopy: MessageTranslationStore.allowsCopy(for: normalMsg),
            onSelectLanguage: { _ in },
            onCopy: { _ in },
            onHide: {},
            onRetry: {}
        )
        #expect(allowedCard.showsCopyAction == true)

        let protectedHost = NSHostingView(rootView: protectedCard)
        protectedHost.layoutSubtreeIfNeeded()
        let allowedHost = NSHostingView(rootView: allowedCard)
        allowedHost.layoutSubtreeIfNeeded()
        #expect(protectedHost.fittingSize.width > 0)
        #expect(protectedHost.fittingSize.height > 0)
        #expect(allowedHost.fittingSize.width > protectedHost.fittingSize.width)

        let translatingCard = MessageTranslationCard(
            message: normalMsg,
            state: .translating,
            mine: false,
            allowCopy: true,
            onSelectLanguage: { _ in },
            onCopy: { _ in },
            onHide: {},
            onRetry: {}
        )
        #expect(translatingCard.showsCopyAction == false)
    }

    // MARK: - Live Apple Translation integration (when pack is installed on host)

    @Test func appleTranslationPreservesMentionsAndURLsWhenInstalled() async {
        let status = await AppleTranslationBackend.availabilityStatus(
            from: Locale.Language(identifier: "en"),
            to: Locale.Language(identifier: "vi")
        )
        guard status == .installed else { return }

        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MessageTranslationStore(defaults: defaults, backend: AppleTranslationBackend())

        let text = "Hello @Lan, please check https://example.com tomorrow."
        let msg = makeMessage(
            id: "live-1",
            conversationId: "c-live",
            text: text,
            mentions: [Mention(uid: "u1", pos: 6, len: 4)]
        )
        store.translate(message: msg, targetCode: "vi")
        await settle(timeout: .seconds(20)) { store.state(for: msg) != .translating }

        guard case .translated(let translated, let src, let tgt) = store.state(for: msg) else {
            Issue.record("Expected translated state for installed en->vi pack, got \(store.state(for: msg))")
            return
        }
        #expect(src == "en")
        #expect(tgt == "vi")
        #expect(translated.contains("@Lan"))
        #expect(translated.contains("https://example.com"))
    }
}

// MARK: - Test double

private final class MockTranslator: MessageTranslating, @unchecked Sendable {
    typealias Handler = @Sendable (String, String?, String) -> TranslationExecutionResult

    private let lock = NSLock()
    private var _callCount = 0
    private let delay: Duration?
    private let handler: Handler

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _callCount
    }

    init(
        delay: Duration? = nil,
        handler: @escaping Handler = { text, src, tgt in
            .translated(text: text, sourceCode: src ?? "en", targetCode: tgt)
        }
    ) {
        self.delay = delay
        self.handler = handler
    }

    private func recordCall() {
        lock.lock()
        _callCount += 1
        lock.unlock()
    }

    func translate(
        maskedText: String,
        detectionText: String,
        sourceCode: String?,
        targetCode: String
    ) async -> TranslationExecutionResult {
        recordCall()
        if let delay {
            try? await Task.sleep(for: delay)
        }
        return handler(maskedText, sourceCode, targetCode)
    }
}
