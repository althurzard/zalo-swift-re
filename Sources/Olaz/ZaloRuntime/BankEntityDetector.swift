import Foundation

/// Detects `(accountNumber, bank)` pairs in plain-text chat messages using a Trie bank-alias
/// matcher, separator/money/spam filtering, and phone/ID context disambiguation modeled on the
/// official Zalo `parseBank` worker.
enum BankEntityDetector {
    private static let minAccountDigits = 5
    private static let maxAccountDigits = 16
    private static let maxTokenDistance = 15
    private static let minSubSectionSpaces = 3

    private final class CacheBox: @unchecked Sendable {
        let matches: [BankTransferMatch]
        init(_ matches: [BankTransferMatch]) { self.matches = matches }
    }

    nonisolated(unsafe) private static let cache: NSCache<NSString, CacheBox> = {
        let c = NSCache<NSString, CacheBox>()
        c.countLimit = 1000
        return c
    }()

    private static let urlDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )

    private static let spamLabelChars: Set<Character> = Set(":;/-?@#%^&*!~+=\\[]{}<>|`$'\"")
    private static let spamNumberChars: Set<Character> = Set("(/)?@#%^&*!~+=\\[]{}<>|`$'\"")
    private static let validSeparators: Set<Character> = Set(" ,.-\u{00A0}\u{2007}\u{202F}")
    private static let moneyPrefixPhrases: Set<String> = [
        "so tien", "khoan tien", "khoang tien", "luong tien", "gia tien",
    ]
    private static let moneySuffixWords: Set<String> = [
        "vnd", "vnđ", "d", "dong", "ti", "ty", "trieu", "tr", "k", "nghin", "ngan",
    ]

    // MARK: - Word Trie

    private enum LabelKind: Sendable {
        case bank(BankEntry)
        case context(BankDirectory.ContextKind)
    }

    private final class TrieNode: @unchecked Sendable {
        var children: [String: TrieNode] = [:]
        var label: LabelKind?
    }

    private static let trieRoot: TrieNode = {
        let root = TrieNode()
        func insert(_ phrase: String, _ kind: LabelKind) {
            let words = phrase.lowercased()
                .split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
                .map(String.init)
            guard !words.isEmpty else { return }
            var node = root
            for word in words {
                if let next = node.children[word] {
                    node = next
                } else {
                    let next = TrieNode()
                    node.children[word] = next
                    node = next
                }
            }
            // Bank labels take precedence over generic context labels on identical phrases.
            if node.label == nil {
                node.label = kind
            } else if case .bank = kind {
                node.label = kind
            }
        }

        for bank in BankDirectory.allBanks {
            for alias in bank.aliases {
                insert(alias, .bank(bank))
            }
        }
        for phrase in BankDirectory.phoneContextPhrases { insert(phrase, .context(.phone)) }
        for phrase in BankDirectory.identityCardPhrases { insert(phrase, .context(.identityCard)) }
        for phrase in BankDirectory.forbiddenNumberPhrases { insert(phrase, .context(.forbiddenNumber)) }
        for phrase in BankDirectory.paymentSupportPhrases { insert(phrase, .context(.paymentSupport)) }
        return root
    }()

    // MARK: - Tokenization & Matching

    private struct Token {
        let word: String
        let isAllDigits: Bool
        let startIndex: String.Index
        let endIndex: String.Index
        let section: Int
        let subSection: Int
    }

    private struct MatchedLabel {
        let kind: LabelKind
        let startToken: Int
        let endToken: Int // inclusive
        let origRange: Range<String.Index>
        let section: Int
        let subSection: Int
    }

    private struct AccountCandidate {
        let digits: String
        let segments: [String]
        let startToken: Int
        let endToken: Int // inclusive
        let origRange: Range<String.Index>
        let section: Int
        let subSection: Int
    }

    /// Detects bank account + bank name pairs in `text`, preserving original string ranges.
    static func detect(in text: String) -> [BankTransferMatch] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8 else { return [] }

        let cacheKey = text as NSString
        if let hit = cache.object(forKey: cacheKey) {
            return hit.matches
        }

        let urlRanges = detectedURLRanges(in: text)
        let tokens = tokenize(text, excluding: urlRanges)
        guard tokens.count >= 2 else {
            cache.setObject(CacheBox([]), forKey: cacheKey)
            return []
        }

        var usedToken = Array(repeating: false, count: tokens.count)
        let labels = matchLabels(in: text, tokens: tokens, usedToken: &usedToken)
        let hasBankLabel = labels.contains {
            if case .bank = $0.kind { return true }
            return false
        }
        guard hasBankLabel else {
            cache.setObject(CacheBox([]), forKey: cacheKey)
            return []
        }

        let candidates = extractAccountCandidates(in: text, tokens: tokens, usedToken: usedToken)
        guard !candidates.isEmpty else {
            cache.setObject(CacheBox([]), forKey: cacheKey)
            return []
        }

        let matches = pairCandidates(candidates, with: labels)
        cache.setObject(CacheBox(matches), forKey: cacheKey)
        return matches
    }

    private static func detectedURLRanges(in text: String) -> [Range<String.Index>] {
        guard let detector = urlDetector else { return [] }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text)
        }
    }

    private static func foldToASCIIAlphaNum(_ ch: Character) -> String? {
        if ch == "đ" || ch == "Đ" || ch == "ð" || ch == "Ð" { return "d" }
        let folded = String(ch).folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()
        let filtered = String(folded.unicodeScalars.filter {
            ($0.value >= 0x61 && $0.value <= 0x7A) || ($0.value >= 0x30 && $0.value <= 0x39)
        })
        return filtered.isEmpty ? nil : filtered
    }

    private static func tokenize(_ text: String, excluding urlRanges: [Range<String.Index>]) -> [Token] {
        var tokens: [Token] = []
        var currentWord = ""
        var tokenStart: String.Index?
        var tokenEnd: String.Index?
        var section = 0
        var subSection = 0
        var spaceCount = 0
        var sectionHasTokens = false

        func flushToken() {
            guard !currentWord.isEmpty, let start = tokenStart, let end = tokenEnd else {
                currentWord = ""
                tokenStart = nil
                tokenEnd = nil
                return
            }
            let overlapsURL = urlRanges.contains { $0.overlaps(start..<end) }
            if !overlapsURL {
                let allDigits = currentWord.unicodeScalars.allSatisfy { $0.value >= 0x30 && $0.value <= 0x39 }
                tokens.append(Token(
                    word: currentWord,
                    isAllDigits: allDigits,
                    startIndex: start,
                    endIndex: end,
                    section: section,
                    subSection: subSection
                ))
                sectionHasTokens = true
            }
            currentWord = ""
            tokenStart = nil
            tokenEnd = nil
        }

        for idx in text.indices {
            let ch = text[idx]
            let nextIdx = text.index(after: idx)
            if ch == "\n" || ch == "\r" {
                flushToken()
                section += 1
                subSection = 0
                spaceCount = 0
                sectionHasTokens = false
                continue
            }
            if let ascii = foldToASCIIAlphaNum(ch) {
                if currentWord.isEmpty {
                    if spaceCount >= minSubSectionSpaces && sectionHasTokens {
                        subSection += 1
                    }
                    spaceCount = 0
                    tokenStart = idx
                }
                currentWord += ascii
                tokenEnd = nextIdx
            } else {
                flushToken()
                if ch == " " || ch == "\t" {
                    spaceCount += 1
                }
            }
        }
        flushToken()
        return tokens
    }

    private static func matchLabels(
        in text: String,
        tokens: [Token],
        usedToken: inout [Bool]
    ) -> [MatchedLabel] {
        var matched: [MatchedLabel] = []
        var i = 0
        while i < tokens.count {
            if usedToken[i] {
                i += 1
                continue
            }
            var node = trieRoot
            var bestKind: LabelKind?
            var bestEnd = i
            let section = tokens[i].section
            let subSection = tokens[i].subSection

            var j = i
            while j < tokens.count, tokens[j].section == section, tokens[j].subSection == subSection {
                guard let next = node.children[tokens[j].word] else { break }
                node = next
                if let label = node.label {
                    bestKind = label
                    bestEnd = j
                }
                j += 1
            }

            if let kind = bestKind {
                let range = tokens[i].startIndex..<tokens[bestEnd].endIndex
                if !isSurroundedBySpam(range, in: text, chars: spamLabelChars) {
                    matched.append(MatchedLabel(
                        kind: kind,
                        startToken: i,
                        endToken: bestEnd,
                        origRange: range,
                        section: section,
                        subSection: subSection
                    ))
                }
                for k in i...bestEnd { usedToken[k] = true }
                i = bestEnd + 1
            } else {
                i += 1
            }
        }
        return matched
    }

    private static func extractAccountCandidates(
        in text: String,
        tokens: [Token],
        usedToken: [Bool]
    ) -> [AccountCandidate] {
        var candidates: [AccountCandidate] = []
        var segments: [String] = []
        var startTok = -1
        var endTok = -1

        func flushCandidate() {
            defer {
                segments.removeAll(keepingCapacity: true)
                startTok = -1
                endTok = -1
            }
            guard !segments.isEmpty, startTok >= 0, endTok >= startTok else { return }
            let digits = segments.joined()
            guard digits.count >= minAccountDigits && digits.count <= maxAccountDigits else { return }

            let range = tokens[startTok].startIndex..<tokens[endTok].endIndex
            let rawSpan = String(text[range])
            if rawSpan.contains(where: { $0 == "," || $0 == "." || $0 == "-" }) {
                if segments.count == 2 || segments.contains(where: { $0.count < 3 }) {
                    return
                }
            }
            if isSurroundedBySpam(range, in: text, chars: spamNumberChars) { return }
            if isPossibleMoneyNumber(
                rawSpan: rawSpan,
                digits: digits,
                startTok: startTok,
                endTok: endTok,
                tokens: tokens
            ) {
                return
            }

            candidates.append(AccountCandidate(
                digits: digits,
                segments: segments,
                startToken: startTok,
                endToken: endTok,
                origRange: range,
                section: tokens[startTok].section,
                subSection: tokens[startTok].subSection
            ))
        }

        for idx in tokens.indices {
            let tok = tokens[idx]
            if usedToken[idx] || !tok.isAllDigits {
                flushCandidate()
                continue
            }
            if segments.isEmpty {
                segments.append(tok.word)
                startTok = idx
                endTok = idx
                continue
            }
            let prev = tokens[endTok]
            if prev.section == tok.section,
               prev.subSection == tok.subSection,
               isValidBetweenNumberSegments(text[prev.endIndex..<tok.startIndex]) {
                segments.append(tok.word)
                endTok = idx
            } else {
                flushCandidate()
                segments.append(tok.word)
                startTok = idx
                endTok = idx
            }
        }
        flushCandidate()
        return candidates
    }

    private static func isValidBetweenNumberSegments(_ gap: Substring) -> Bool {
        guard !gap.isEmpty else { return false }
        if gap.count == 1, let first = gap.first {
            return validSeparators.contains(first)
        }
        var seenHyphen = false
        for ch in gap {
            if ch == "-" {
                if seenHyphen { return false }
                seenHyphen = true
            } else if ch != " " {
                return false
            }
        }
        return true
    }

    private static func isSurroundedBySpam(
        _ range: Range<String.Index>,
        in text: String,
        chars: Set<Character>
    ) -> Bool {
        guard range.lowerBound > text.startIndex, range.upperBound < text.endIndex else { return false }
        let before = text[text.index(before: range.lowerBound)]
        let after = text[range.upperBound]
        return chars.contains(before) && chars.contains(after)
    }

    private static func isPossibleMoneyNumber(
        rawSpan: String,
        digits: String,
        startTok: Int,
        endTok: Int,
        tokens: [Token]
    ) -> Bool {
        if rawSpan.range(of: #"^[1-9]\d{0,2}(?:[.,]\d{3})+$"#, options: .regularExpression) != nil {
            return true
        }
        if digits.range(of: #"^[1-9]{1,3}0{3,8}$"#, options: .regularExpression) != nil {
            return true
        }
        guard digits.range(of: #"^[1-9]\d{4,10}$"#, options: .regularExpression) != nil else {
            return false
        }
        let nextIdx = endTok + 1
        if nextIdx < tokens.count,
           tokens[nextIdx].section == tokens[endTok].section,
           moneySuffixWords.contains(tokens[nextIdx].word) {
            return true
        }
        if startTok >= 2,
           tokens[startTok - 1].section == tokens[startTok].section,
           tokens[startTok - 2].section == tokens[startTok].section {
            let prefix = "\(tokens[startTok - 2].word) \(tokens[startTok - 1].word)"
            if moneyPrefixPhrases.contains(prefix) { return true }
        }
        return false
    }

    private static func isPhoneNumberFormat(_ digits: String) -> Bool {
        let normalized = digits.hasPrefix("84") ? "0" + digits.dropFirst(2) : digits
        return normalized.range(
            of: #"^(?:(?:03|05|07|08|09)\d{8}|0\d{2}\d{7,8}|0\d{3}\d{7}|1800\d{4,6}|1900\d{4,6})$"#,
            options: .regularExpression
        ) != nil
    }

    // MARK: - Pairing

    private static func pairCandidates(
        _ candidates: [AccountCandidate],
        with labels: [MatchedLabel]
    ) -> [BankTransferMatch] {
        var matches: [BankTransferMatch] = []
        var seenIds: Set<String> = []

        for candidate in candidates {
            // Try matching within the same sub-section first; fall back to same line/section.
            let subMatched = bestMatch(
                for: candidate,
                from: labels.filter { $0.section == candidate.section && $0.subSection == candidate.subSection }
            )
            let resolved = subMatched ?? bestMatch(
                for: candidate,
                from: labels.filter { $0.section == candidate.section }
            )
            if let resolved, seenIds.insert(resolved.id).inserted {
                matches.append(resolved)
            }
        }
        return matches
    }

    private static func tokenDistance(_ candidate: AccountCandidate, _ label: MatchedLabel) -> Int {
        if label.endToken < candidate.startToken {
            return candidate.startToken - label.endToken
        }
        if label.startToken > candidate.endToken {
            return label.startToken - candidate.endToken
        }
        return 0
    }

    private static func bestMatch(
        for candidate: AccountCandidate,
        from scopedLabels: [MatchedLabel]
    ) -> BankTransferMatch? {
        let nearby = scopedLabels.filter { tokenDistance(candidate, $0) <= maxTokenDistance }
        guard !nearby.isEmpty else { return nil }

        var nearestBank: (label: MatchedLabel, bank: BankEntry, dist: Int)?
        var nearestPhoneDist: Int?
        var nearestForbiddenDist: Int?
        var nearestPaymentSupportDist: Int?

        for label in nearby {
            let dist = tokenDistance(candidate, label)
            switch label.kind {
            case .bank(let bank):
                if nearestBank == nil || dist < nearestBank!.dist {
                    nearestBank = (label, bank, dist)
                }
            case .context(.phone):
                if nearestPhoneDist == nil || dist < nearestPhoneDist! {
                    nearestPhoneDist = dist
                }
            case .context(.identityCard), .context(.forbiddenNumber):
                if nearestForbiddenDist == nil || dist < nearestForbiddenDist! {
                    nearestForbiddenDist = dist
                }
            case .context(.paymentSupport):
                if nearestPaymentSupportDist == nil || dist < nearestPaymentSupportDist! {
                    nearestPaymentSupportDist = dist
                }
            }
        }

        guard let bankMatch = nearestBank else { return nil }

        // Reject CCCD / CMND / OTP / order-id when that context label is as close or closer than the bank label.
        if let forbiddenDist = nearestForbiddenDist, forbiddenDist <= bankMatch.dist {
            return nil
        }

        // Phone-shaped numbers (e.g. 0886xxxxxx) are allowed when paired with a bank name,
        // unless phone context ("sdt", "zalo", "momo", ...) is present without explicit "stk" support closer to the number.
        if isPhoneNumberFormat(candidate.digits), let phoneDist = nearestPhoneDist {
            let hasCloserPaymentSupport = (nearestPaymentSupportDist ?? Int.max) < phoneDist
            if !hasCloserPaymentSupport {
                return nil
            }
        }

        return BankTransferMatch(
            bank: bankMatch.bank,
            accountNumber: candidate.digits,
            accountRange: candidate.origRange,
            bankRange: bankMatch.label.origRange,
            confidence: nearestPaymentSupportDist != nil ? .high : .medium
        )
    }
}
