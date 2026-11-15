import CryptoKit
import Foundation
import NaturalLanguage
import Observation
import Translation

// MARK: - Language catalog

/// Supported target language entry for on-device message translation.
struct TranslationLanguage: Identifiable, Hashable, Sendable {
    let code: String
    let displayName: String
    let badgeCode: String

    var id: String { code }
    var localeLanguage: Locale.Language { Locale.Language(identifier: code) }

    /// Curated target languages displayed in quick translation menus and Settings.
    static let curated: [TranslationLanguage] = [
        TranslationLanguage(code: "vi", displayName: "Tiếng Việt", badgeCode: "VI"),
        TranslationLanguage(code: "en", displayName: "Tiếng Anh", badgeCode: "EN"),
        TranslationLanguage(code: "zh-Hans", displayName: "Tiếng Trung (Giản thể)", badgeCode: "ZH"),
        TranslationLanguage(code: "zh-Hant", displayName: "Tiếng Trung (Phồn thể)", badgeCode: "ZH-TW"),
        TranslationLanguage(code: "ko", displayName: "Tiếng Hàn", badgeCode: "KO"),
        TranslationLanguage(code: "ja", displayName: "Tiếng Nhật", badgeCode: "JA"),
        TranslationLanguage(code: "th", displayName: "Tiếng Thái", badgeCode: "TH"),
        TranslationLanguage(code: "fr", displayName: "Tiếng Pháp", badgeCode: "FR"),
        TranslationLanguage(code: "de", displayName: "Tiếng Đức", badgeCode: "DE"),
        TranslationLanguage(code: "es", displayName: "Tiếng Tây Ban Nha", badgeCode: "ES"),
    ]

    private static let byCode: [String: TranslationLanguage] = Dictionary(
        uniqueKeysWithValues: curated.map { ($0.code, $0) }
    )

    static func find(_ code: String) -> TranslationLanguage? {
        byCode[normalizeCode(code)]
    }

    static func normalizeCode(_ raw: String) -> String {
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
        guard !cleaned.isEmpty else { return "vi" }

        let lower = cleaned.lowercased()
        switch lower {
        case "zh", "zh-hans", "zh-cn", "zh-sg":
            return "zh-Hans"
        case "zh-hant", "zh-tw", "zh-hk", "zh-mo":
            return "zh-Hant"
        default:
            break
        }

        if let exact = curated.first(where: { $0.code.lowercased() == lower }) {
            return exact.code
        }

        let base = lower.split(separator: "-").first.map(String.init) ?? lower
        if let baseMatch = curated.first(where: { $0.code.lowercased() == base }) {
            return baseMatch.code
        }

        let minimal = Locale.Language(identifier: cleaned).minimalIdentifier
        return minimal.isEmpty ? cleaned : minimal
    }

    static func normalizeLanguage(_ language: Locale.Language) -> String {
        if language.languageCode?.identifier == "zh" {
            let script = language.script?.identifier
            let region = language.region?.identifier
            if script == "Hant" || region == "TW" || region == "HK" || region == "MO" {
                return "zh-Hant"
            }
            return "zh-Hans"
        }
        return normalizeCode(language.minimalIdentifier)
    }

    static func badge(for code: String) -> String {
        let normalized = normalizeCode(code)
        if let entry = byCode[normalized] { return entry.badgeCode }
        return normalized.uppercased()
    }

    static func displayName(for code: String) -> String {
        let normalized = normalizeCode(code)
        if let entry = byCode[normalized] { return entry.displayName }
        return Locale(identifier: "vi_VN")
            .localizedString(forIdentifier: normalized)?
            .localizedCapitalized ?? normalized.uppercased()
    }
}

// MARK: - Translation state & span masking

/// Per-message inline translation lifecycle state.
enum MessageTranslationState: Equatable, Sendable {
    case idle
    case translating
    case translated(text: String, sourceCode: String, targetCode: String)
    case collapsed
    case failed(String)

    var showsCard: Bool {
        switch self {
        case .translating, .translated, .failed: true
        case .idle, .collapsed: false
        }
    }

    var isActiveOrVisible: Bool {
        switch self {
        case .translating, .translated: true
        case .idle, .collapsed, .failed: false
        }
    }
}

struct ProtectedSpan: Equatable, Sendable {
    let placeholder: String
    let original: String
}

struct MaskedTranslationText: Equatable, Sendable {
    let maskedText: String
    let detectionText: String
    let spans: [ProtectedSpan]

    var hasTranslatableContent: Bool {
        detectionText.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }
}

struct TranslationCacheKey: Hashable, Sendable {
    let conversationId: String
    let messageId: String
    let targetCode: String
}

// MARK: - Backend abstraction

enum TranslationExecutionResult: Equatable, Sendable {
    case translated(text: String, sourceCode: String, targetCode: String)
    case needsHostSession(sourceCode: String?, targetCode: String)
    case failed(String)
}

protocol MessageTranslating: Sendable {
    func translate(
        maskedText: String,
        detectionText: String,
        sourceCode: String?,
        targetCode: String
    ) async -> TranslationExecutionResult
}

/// On-device Apple `Translation` backend: translates directly when the language pack is `.installed`,
/// or delegates to SwiftUI's `.translationTask` host when `.supported` needs a system download prompt.
struct AppleTranslationBackend: MessageTranslating {
    func translate(
        maskedText: String,
        detectionText: String,
        sourceCode: String?,
        targetCode: String
    ) async -> TranslationExecutionResult {
        let targetLang = Locale.Language(identifier: targetCode)

        if let sourceCode {
            let sourceLang = Locale.Language(identifier: sourceCode)
            let status = await Self.availabilityStatus(from: sourceLang, to: targetLang)
            switch status {
            case .installed:
                do {
                    let response = try await Self.translateInstalled(
                        maskedText,
                        source: sourceLang,
                        target: targetLang
                    )
                    return .translated(
                        text: response.targetText,
                        sourceCode: TranslationLanguage.normalizeLanguage(response.sourceLanguage),
                        targetCode: targetCode
                    )
                } catch TranslationError.notInstalled {
                    return .needsHostSession(sourceCode: sourceCode, targetCode: targetCode)
                } catch {
                    return .failed(Self.userFacingError(error))
                }

            case .supported:
                return .needsHostSession(sourceCode: sourceCode, targetCode: targetCode)

            case .unsupported:
                // Short texts can misclassify in NLLanguageRecognizer; let Translation's own detector inspect the text.
                let textStatus = await Self.availabilityStatus(for: detectionText, to: targetLang)
                switch textStatus {
                case .installed, .supported:
                    return .needsHostSession(sourceCode: nil, targetCode: targetCode)
                case .unsupported:
                    return .failed("Chưa hỗ trợ dịch cặp ngôn ngữ này sang \(TranslationLanguage.displayName(for: targetCode)).")
                @unknown default:
                    return .failed("Chưa hỗ trợ dịch cặp ngôn ngữ này.")
                }

            @unknown default:
                return .failed("Không thể kiểm tra gói ngôn ngữ.")
            }
        }

        let textStatus = await Self.availabilityStatus(for: detectionText, to: targetLang)
        switch textStatus {
        case .installed, .supported:
            return .needsHostSession(sourceCode: nil, targetCode: targetCode)
        case .unsupported:
            return .failed("Không xác định được ngôn ngữ phù hợp để dịch.")
        @unknown default:
            return .failed("Không thể kiểm tra gói ngôn ngữ.")
        }
    }

    nonisolated static func availabilityStatus(
        from source: Locale.Language,
        to target: Locale.Language
    ) async -> LanguageAvailability.Status {
        let availability = LanguageAvailability()
        return await availability.status(from: source, to: target)
    }

    nonisolated static func availabilityStatus(
        for text: String,
        to target: Locale.Language
    ) async -> LanguageAvailability.Status {
        let availability = LanguageAvailability()
        return (try? await availability.status(for: text, to: target)) ?? .unsupported
    }

    nonisolated static func translateInstalled(
        _ text: String,
        source: Locale.Language,
        target: Locale.Language
    ) async throws -> TranslationSession.Response {
        let session = TranslationSession(installedSource: source, target: target)
        return try await session.translate(text)
    }

    static func userFacingError(_ error: Error) -> String {
        if let translationError = error as? TranslationError {
            switch translationError {
            case .unsupportedSourceLanguage, .unsupportedTargetLanguage, .unsupportedLanguagePairing:
                return "Chưa hỗ trợ cặp ngôn ngữ này."
            case .unableToIdentifyLanguage:
                return "Không nhận diện được ngôn ngữ của tin nhắn."
            case .nothingToTranslate:
                return "Không có nội dung văn bản để dịch."
            case .notInstalled:
                return "Gói ngôn ngữ chưa được tải về máy."
            case .alreadyCancelled:
                return "Đã hủy dịch tin nhắn."
            default:
                return "Không thể dịch tin nhắn lúc này."
            }
        }
        return "Không thể dịch tin nhắn lúc này."
    }
}

// MARK: - Message eligibility

extension ChatMessage {
    /// Text eligible for on-device translation: body of `.text` / `.link`, or non-fallback caption of `.photo` / `.video`.
    /// Works identically for E2EE messages once decrypted in memory; excludes `.recalled`, placeholders, and non-text media.
    var translatableText: String? {
        let raw: String?
        switch kind {
        case .text:
            raw = text
        case .link(let title, let url, _, _, _):
            if !text.isEmpty, !text.hasPrefix("[Link]"), text != url?.absoluteString {
                raw = text
            } else if !title.isEmpty, title != url?.absoluteString, !title.hasPrefix("[") {
                raw = title
            } else {
                raw = nil
            }
        case .photo, .video:
            raw = caption
        default:
            raw = nil
        }
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Store

/// In-memory translation store keyed by `(convId, msgId, targetCode)`.
/// Never persists translations or logs message bodies. Cleared on account switch or logout.
@MainActor
@Observable
final class MessageTranslationStore {
    static let shared = MessageTranslationStore()
    static let targetLanguageDefaultsKey = "olaz.translation.targetLang"
    static let defaultTargetCode = "vi"

    private struct MessagePair: Hashable {
        let conversationId: String
        let messageId: String
    }

    private struct CachedTranslation {
        let text: String
        let sourceCode: String
        let targetCode: String
        let fingerprint: String
    }

    struct PendingHostRequest: Sendable {
        let id: UUID
        let key: TranslationCacheKey
        let masked: MaskedTranslationText
        let sourceCode: String?
        let targetCode: String
        let fingerprint: String
        let generation: UInt64
    }

    var defaultTargetLanguage: String {
        didSet {
            let normalized = TranslationLanguage.normalizeCode(defaultTargetLanguage)
            if normalized != defaultTargetLanguage {
                defaultTargetLanguage = normalized
                return
            }
            defaults.set(defaultTargetLanguage, forKey: Self.targetLanguageDefaultsKey)
        }
    }

    /// Bound to `.translationTask(...)` in `.olazTranslationHost()` for language packs that are `.supported` (not yet downloaded).
    @ObservationIgnored private(set) var pendingHostRequest: PendingHostRequest?
    var hostConfiguration: TranslationSession.Configuration?

    private var cache: [TranslationCacheKey: CachedTranslation] = [:]
    private var activeTargets: [MessagePair: String] = [:]
    private var collapsedKeys: Set<TranslationCacheKey> = []
    private var failures: [TranslationCacheKey: String] = [:]
    private var inFlight: [TranslationCacheKey: Task<Void, Never>] = [:]
    @ObservationIgnored private var hostMountCount = 0
    @ObservationIgnored private var activeAccountId: String?
    @ObservationIgnored private var sessionGeneration: UInt64 = 0

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let backend: any MessageTranslating

    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    private static let bareMentionRegex = try? NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_.])@[\p{L}\p{N}_-]+"#)

    init(
        defaults: UserDefaults = .standard,
        backend: any MessageTranslating = AppleTranslationBackend()
    ) {
        self.defaults = defaults
        self.backend = backend
        let stored = defaults.string(forKey: Self.targetLanguageDefaultsKey) ?? Self.defaultTargetCode
        let normalized = TranslationLanguage.normalizeCode(stored)
        self.defaultTargetLanguage = TranslationLanguage.find(normalized)?.code ?? Self.defaultTargetCode
    }

    // MARK: Public queries & actions

    /// Copy of translated text is only permitted when "Chặn chia sẻ" (`isProtected`) is off.
    static func allowsCopy(for message: ChatMessage) -> Bool {
        !message.menu.isProtected
    }

    func state(for message: ChatMessage, targetCode: String? = nil) -> MessageTranslationState {
        state(conversationId: message.conversationId, messageId: message.id, targetCode: targetCode)
    }

    func state(conversationId: String, messageId: String, targetCode: String? = nil) -> MessageTranslationState {
        let pair = MessagePair(conversationId: conversationId, messageId: messageId)
        let resolvedTarget = TranslationLanguage.normalizeCode(targetCode ?? activeTargets[pair] ?? defaultTargetLanguage)
        let key = TranslationCacheKey(conversationId: conversationId, messageId: messageId, targetCode: resolvedTarget)

        if inFlight[key] != nil || pendingHostRequest?.key == key {
            return .translating
        }
        if let error = failures[key] {
            return .failed(error)
        }
        if collapsedKeys.contains(key) {
            return .collapsed
        }
        if let hit = cache[key] {
            return .translated(text: hit.text, sourceCode: hit.sourceCode, targetCode: hit.targetCode)
        }
        return .idle
    }

    func translate(message: ChatMessage, targetCode: String? = nil) {
        guard let text = message.translatableText else { return }
        translate(
            conversationId: message.conversationId,
            messageId: message.id,
            text: text,
            mentions: message.mentions,
            targetCode: targetCode
        )
    }

    func translate(
        conversationId: String,
        messageId: String,
        text: String,
        mentions: [Mention] = [],
        targetCode: String? = nil
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let masked = maskProtectedSpans(in: trimmed, mentions: mentions)
        let requestedTarget = TranslationLanguage.normalizeCode(targetCode ?? defaultTargetLanguage)
        let detected = masked.hasTranslatableContent ? detectLanguage(of: masked.detectionText) : nil

        let effectiveTarget: String
        if targetCode == nil, let detected, detected == requestedTarget {
            // Pivoting avoids a redundant same-language failure when clicking Translate on native-language text.
            effectiveTarget = requestedTarget == "vi" ? "en" : "vi"
        } else {
            effectiveTarget = requestedTarget
        }

        let pair = MessagePair(conversationId: conversationId, messageId: messageId)
        let key = TranslationCacheKey(conversationId: conversationId, messageId: messageId, targetCode: effectiveTarget)
        activeTargets[pair] = effectiveTarget
        collapsedKeys.remove(key)
        failures.removeValue(forKey: key)

        if !masked.hasTranslatableContent {
            failures[key] = "Không có nội dung văn bản để dịch."
            return
        }

        if let targetCode, let detected, detected == TranslationLanguage.normalizeCode(targetCode) {
            failures[key] = "Tin nhắn đã ở ngôn ngữ \(TranslationLanguage.displayName(for: effectiveTarget))."
            return
        }

        let fingerprint = Self.fingerprint(of: trimmed)
        if let hit = cache[key], hit.fingerprint == fingerprint {
            return
        }
        cache.removeValue(forKey: key)

        inFlight[key]?.cancel()
        if pendingHostRequest?.key == key {
            clearPendingHostRequest()
        }

        let generation = sessionGeneration
        let backend = self.backend
        let task = Task { [weak self] in
            let outcome = await backend.translate(
                maskedText: masked.maskedText,
                detectionText: masked.detectionText,
                sourceCode: detected,
                targetCode: effectiveTarget
            )
            guard let self, !Task.isCancelled, generation == self.sessionGeneration else { return }
            self.finishBackendOutcome(
                outcome,
                key: key,
                masked: masked,
                detectedSource: detected,
                fingerprint: fingerprint,
                generation: generation
            )
        }
        inFlight[key] = task
    }

    func retry(message: ChatMessage) {
        let pair = MessagePair(conversationId: message.conversationId, messageId: message.id)
        let active = activeTargets[pair]
        if let active {
            let key = TranslationCacheKey(conversationId: message.conversationId, messageId: message.id, targetCode: active)
            failures.removeValue(forKey: key)
        }
        translate(message: message, targetCode: active)
    }

    func collapse(conversationId: String, messageId: String, targetCode: String? = nil) {
        let pair = MessagePair(conversationId: conversationId, messageId: messageId)
        let resolvedTarget = TranslationLanguage.normalizeCode(targetCode ?? activeTargets[pair] ?? defaultTargetLanguage)
        let key = TranslationCacheKey(conversationId: conversationId, messageId: messageId, targetCode: resolvedTarget)

        inFlight.removeValue(forKey: key)?.cancel()
        if pendingHostRequest?.key == key {
            clearPendingHostRequest()
        }
        failures.removeValue(forKey: key)
        if cache[key] != nil {
            collapsedKeys.insert(key)
        }
    }

    /// Clears all in-memory translations, errors, and pending host requests (called on account switch or logout).
    func clearAll() {
        sessionGeneration &+= 1
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        cache.removeAll()
        activeTargets.removeAll()
        collapsedKeys.removeAll()
        failures.removeAll()
        clearPendingHostRequest()
        activeAccountId = nil
    }

    /// Purges cached translations for a single conversation (e.g. when a hidden PIN-locked chat closes or relocks).
    func clearConversation(_ conversationId: String) {
        for (key, task) in inFlight where key.conversationId == conversationId {
            task.cancel()
            inFlight.removeValue(forKey: key)
        }
        cache = cache.filter { $0.key.conversationId != conversationId }
        activeTargets = activeTargets.filter { $0.key.conversationId != conversationId }
        collapsedKeys = collapsedKeys.filter { $0.conversationId != conversationId }
        failures = failures.filter { $0.key.conversationId != conversationId }
        if pendingHostRequest?.key.conversationId == conversationId {
            clearPendingHostRequest()
        }
    }

    /// Ensures translations never leak across Zalo accounts or survive sign-out.
    func syncActiveAccount(_ userId: String?) {
        let normalized = (userId?.isEmpty == false) ? userId : nil
        guard let normalized else {
            if activeAccountId != nil || hasAnyState {
                clearAll()
            }
            activeAccountId = nil
            return
        }
        if let current = activeAccountId, current != normalized {
            clearAll()
        }
        activeAccountId = normalized
    }

    // MARK: Language detection & span masking

    /// Detects the dominant BCP-47 language code of `text` using Apple's on-device `NLLanguageRecognizer`.
    func detectLanguage(of text: String) -> String? {
        let masked = maskProtectedSpans(in: text)
        let candidate = masked.detectionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty,
              candidate.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else {
            return nil
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(candidate)
        guard let dominant = recognizer.dominantLanguage, dominant != .undetermined else {
            return nil
        }
        return TranslationLanguage.normalizeCode(dominant.rawValue)
    }

    /// Replaces `@mentions` (explicit UTF-16 ranges and bare handles) and URLs/links with opaque numeric placeholders
    /// so translation models preserve them untouched.
    func maskProtectedSpans(in text: String, mentions: [Mention] = []) -> MaskedTranslationText {
        guard !text.isEmpty else {
            return MaskedTranslationText(maskedText: text, detectionText: text, spans: [])
        }

        var rawRanges: [Range<String.Index>] = []
        let ns = text as NSString
        let fullNSRange = NSRange(location: 0, length: ns.length)

        func appendIfNonOverlapping(_ range: Range<String.Index>) {
            guard !range.isEmpty else { return }
            let overlaps = rawRanges.contains { existing in
                range.lowerBound < existing.upperBound && existing.lowerBound < range.upperBound
            }
            if !overlaps {
                rawRanges.append(range)
            }
        }

        // 1. Explicit official Zalo @mention UTF-16 offsets (supports multi-word names like "@Nguyễn Văn A").
        for mention in mentions {
            guard mention.pos >= 0,
                  mention.len > 1,
                  mention.pos + mention.len <= ns.length,
                  ns.character(at: mention.pos) == 0x40,
                  let range = Range(NSRange(location: mention.pos, length: mention.len), in: text) else {
                continue
            }
            appendIfNonOverlapping(range)
        }

        // 2. Links / URLs / email addresses via NSDataDetector.
        if let detector = Self.linkDetector {
            for match in detector.matches(in: text, range: fullNSRange) {
                guard match.url != nil, let range = Range(match.range, in: text) else { continue }
                appendIfNonOverlapping(range)
            }
        }

        // 3. Bare @handles not backed by explicit Mention metadata (excluding email domains already captured above).
        if let regex = Self.bareMentionRegex {
            for match in regex.matches(in: text, range: fullNSRange) {
                guard let range = Range(match.range, in: text) else { continue }
                appendIfNonOverlapping(range)
            }
        }

        guard !rawRanges.isEmpty else {
            return MaskedTranslationText(maskedText: text, detectionText: text, spans: [])
        }

        rawRanges.sort { $0.lowerBound < $1.lowerBound }
        let salt = Self.placeholderSalt(avoiding: text)

        var masked = ""
        var detection = ""
        var spans: [ProtectedSpan] = []
        spans.reserveCapacity(rawRanges.count)

        var cursor = text.startIndex
        for (index, range) in rawRanges.enumerated() {
            let prefix = text[cursor..<range.lowerBound]
            masked.append(contentsOf: prefix)
            detection.append(contentsOf: prefix)
            detection.append(" ")

            let placeholder = "[[\(salt)\(index)]]"
            let original = String(text[range])
            masked.append(placeholder)
            spans.append(ProtectedSpan(placeholder: placeholder, original: original))
            cursor = range.upperBound
        }

        let suffix = text[cursor...]
        masked.append(contentsOf: suffix)
        detection.append(contentsOf: suffix)

        let collapsedDetection = detection
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")

        return MaskedTranslationText(maskedText: masked, detectionText: collapsedDetection, spans: spans)
    }

    /// Restores masked URL and `@mention` spans back into the translated string.
    func restoreProtectedSpans(in translated: String, spans: [ProtectedSpan]) -> String {
        guard !spans.isEmpty else { return translated }
        var output = translated
        for span in spans {
            if output.contains(span.placeholder) {
                output = output.replacingOccurrences(of: span.placeholder, with: span.original)
                continue
            }
            // Tolerate models adding inner whitespace inside brackets (e.g. "[[ 0 ]]").
            let inner = span.placeholder.dropFirst(2).dropLast(2)
            let pattern = #"\[\[\s*"# + NSRegularExpression.escapedPattern(for: String(inner)) + #"\s*\]\]"#
            while let range = output.range(of: pattern, options: .regularExpression) {
                output.replaceSubrange(range, with: span.original)
            }
        }
        return output
    }

    // MARK: SwiftUI `.translationTask` host coordination

    func registerHost() {
        hostMountCount += 1
    }

    func unregisterHost() {
        hostMountCount = max(0, hostMountCount - 1)
        if hostMountCount == 0 {
            clearPendingHostRequest()
        }
    }

    func activeHostRequest() -> PendingHostRequest? {
        pendingHostRequest
    }

    func clearIdleHostConfiguration() {
        if pendingHostRequest == nil {
            hostConfiguration = nil
        }
    }

    func completeHostRequest(
        _ request: PendingHostRequest,
        response: TranslationSession.Response
    ) {
        guard request.generation == sessionGeneration, pendingHostRequest?.id == request.id else { return }
        let restored = restoreProtectedSpans(in: response.targetText, spans: request.masked.spans)
        let resolvedSource = TranslationLanguage.normalizeLanguage(response.sourceLanguage)
        cache[request.key] = CachedTranslation(
            text: restored,
            sourceCode: resolvedSource,
            targetCode: request.targetCode,
            fingerprint: request.fingerprint
        )
        failures.removeValue(forKey: request.key)
        clearPendingHostRequest()
    }

    func cancelHostRequest(_ requestId: UUID) {
        if pendingHostRequest?.id == requestId {
            clearPendingHostRequest()
        }
    }

    func failHostRequest(_ request: PendingHostRequest, message: String) {
        guard request.generation == sessionGeneration, pendingHostRequest?.id == request.id else { return }
        failures[request.key] = message
        clearPendingHostRequest()
    }

    // MARK: Internal helpers

    private var hasAnyState: Bool {
        !cache.isEmpty || !activeTargets.isEmpty || !collapsedKeys.isEmpty || !failures.isEmpty || !inFlight.isEmpty || pendingHostRequest != nil
    }

    private func finishBackendOutcome(
        _ outcome: TranslationExecutionResult,
        key: TranslationCacheKey,
        masked: MaskedTranslationText,
        detectedSource: String?,
        fingerprint: String,
        generation: UInt64
    ) {
        inFlight.removeValue(forKey: key)
        guard generation == sessionGeneration else { return }

        switch outcome {
        case .translated(let rawText, let srcCode, let tgtCode):
            let restored = restoreProtectedSpans(in: rawText, spans: masked.spans)
            cache[key] = CachedTranslation(
                text: restored,
                sourceCode: srcCode,
                targetCode: tgtCode,
                fingerprint: fingerprint
            )
            failures.removeValue(forKey: key)

        case .needsHostSession(let srcCode, let tgtCode):
            guard hostMountCount > 0 else {
                failures[key] = "Mở cuộc trò chuyện để tải gói ngôn ngữ cần thiết."
                return
            }
            let effectiveSource = srcCode ?? detectedSource
            let request = PendingHostRequest(
                id: UUID(),
                key: key,
                masked: masked,
                sourceCode: effectiveSource,
                targetCode: tgtCode,
                fingerprint: fingerprint,
                generation: generation
            )
            pendingHostRequest = request
            var config = TranslationSession.Configuration(
                source: effectiveSource.map { Locale.Language(identifier: $0) },
                target: Locale.Language(identifier: tgtCode)
            )
            if hostConfiguration == config {
                config.invalidate()
            }
            hostConfiguration = config

        case .failed(let message):
            failures[key] = message
        }
    }

    private func clearPendingHostRequest() {
        pendingHostRequest = nil
        hostConfiguration = nil
    }

    private static func placeholderSalt(avoiding text: String) -> String {
        guard text.contains("[[") else { return "" }
        var counter = 1
        while text.contains("[[\(counter):") {
            counter += 1
        }
        return "\(counter):"
    }

    private static func fingerprint(of text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
