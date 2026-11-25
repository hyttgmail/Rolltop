import Foundation

/// How well a query matches a text, best first. Pure; see `PaletteRanker`.
nonisolated enum PaletteMatchTier: Int, Comparable, Sendable, CustomStringConvertible {
    /// A provider's row the palette could not match itself (the provider decided it matches).
    case provided = 0
    /// The query's letters appear in order, the first one at a word start ("sbi" → "Rolltop Bar Items").
    case subsequence = 1
    /// The query is a prefix of the words' initials ("smb" → "Search Menu Bar Items").
    case acronym = 2
    /// A word, or a run of words, starts with the query ("bar" → "Rolltop Bar").
    case wordPrefix = 3
    /// The text starts with the query.
    case prefix = 4
    /// The text is the query (ignoring case, diacritics and punctuation).
    case exact = 5

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var description: String {
        switch self {
        case .provided: "provided"
        case .subsequence: "subsequence"
        case .acronym: "acronym"
        case .wordPrefix: "word-prefix"
        case .prefix: "prefix"
        case .exact: "exact"
        }
    }
}

/// A text prepared once for matching: folded (case, diacritics, width), split into words
/// (spaces, punctuation, camelCase and letter/digit changes), with initials and a compact
/// form without punctuation ("Wi‑Fi" → "wifi").
nonisolated struct PaletteSearchText: Sendable, Equatable {
    let folded: String
    let compact: String
    let words: [String]
    let initials: String
    /// Offsets into `folded` where a word starts.
    let wordStarts: [String.Index]

    init(_ text: String) {
        let folded = PaletteSearchText.fold(text)
        self.folded = folded
        compact = String(folded.unicodeScalars.filter(PaletteSearchText.isWordScalar).map(Character.init))
        let words = PaletteSearchText.split(text)
        self.words = words
        initials = String(words.compactMap(\.first))
        wordStarts = PaletteSearchText.wordStarts(in: folded)
    }

    /// Lowercased, without diacritics, full-width forms folded.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
    }

    static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isAlphabetic || scalar.properties.numericType != nil
    }

    /// Folded words. Splits at non-word characters, before an uppercase letter that follows
    /// a lowercase one ("RolltopFixture"), and between letters and digits.
    static func split(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        var previous: Character?
        for character in text {
            let isWord = character.unicodeScalars.allSatisfy(isWordScalar)
            if !isWord {
                if !current.isEmpty { words.append(current) }
                current = ""
                previous = nil
                continue
            }
            if let previous, !current.isEmpty {
                let camel = previous.isLowercase && character.isUppercase
                let digitChange = previous.isNumber != character.isNumber
                let ideograph = character.unicodeScalars.contains { $0.properties.isIdeographic }
                    || previous.unicodeScalars.contains { $0.properties.isIdeographic }
                if camel || digitChange || ideograph {
                    words.append(current)
                    current = ""
                }
            }
            current.append(character)
            previous = character
        }
        if !current.isEmpty { words.append(current) }
        return words.map(fold)
    }

    private static func wordStarts(in folded: String) -> [String.Index] {
        var starts: [String.Index] = []
        var previousIsWord = false
        var index = folded.startIndex
        while index < folded.endIndex {
            let isWord = folded[index].unicodeScalars.allSatisfy(isWordScalar)
            if isWord, !previousIsWord { starts.append(index) }
            previousIsWord = isWord
            index = folded.index(after: index)
        }
        return starts
    }
}

/// A query prepared once per keystroke.
nonisolated struct PaletteQuery: Sendable, Equatable {
    let folded: String
    let compact: String
    let words: [String]

    init(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        folded = PaletteSearchText.fold(trimmed)
        compact = String(folded.unicodeScalars.filter(PaletteSearchText.isWordScalar).map(Character.init))
        words = folded.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    var isEmpty: Bool { folded.isEmpty }
}

nonisolated enum PaletteMatcher {
    /// The best tier at which `query` matches `text`, nil when it does not.
    /// `allowsSubsequence`: off for secondary texts (bundle ids, keywords) to keep noise down.
    static func match(_ query: PaletteQuery, in text: PaletteSearchText, allowsSubsequence: Bool = true) -> PaletteMatchTier? {
        guard !query.isEmpty, !text.folded.isEmpty else { return nil }
        let q = query.folded
        let qc = query.compact
        if text.folded == q || (!qc.isEmpty && text.compact == qc) { return .exact }
        if text.folded.hasPrefix(q) || (!qc.isEmpty && text.compact.hasPrefix(qc)) { return .prefix }
        if isWordPrefix(query, in: text) { return .wordPrefix }
        if qc.count >= 2, text.initials.hasPrefix(qc) { return .acronym }
        if allowsSubsequence, isSubsequence(qc, in: text) { return .subsequence }
        return nil
    }

    /// A word start from which the text continues with the query, or every query word a
    /// prefix of a later text word, in order ("menu items" → "Search Menu Bar Items").
    static func isWordPrefix(_ query: PaletteQuery, in text: PaletteSearchText) -> Bool {
        for start in text.wordStarts where text.folded[start...].hasPrefix(query.folded) { return true }
        if !query.compact.isEmpty, text.words.contains(where: { $0.hasPrefix(query.compact) }) { return true }
        guard query.words.count > 1 else { return false }
        var remaining = text.words[...]
        for word in query.words {
            guard let index = remaining.firstIndex(where: { $0.hasPrefix(word) }) else { return false }
            remaining = remaining[(index + 1)...]
        }
        return true
    }

    /// The query's characters in order in the compact text, the first one at the start of a word.
    static func isSubsequence(_ query: String, in text: PaletteSearchText) -> Bool {
        guard query.count >= 2, let first = query.first else { return false }
        guard text.words.contains(where: { $0.first == first }) else { return false }
        var remaining = query[...]
        // Start the scan at the first word that starts with the query's first character.
        guard let startWord = text.words.firstIndex(where: { $0.first == first }) else { return false }
        let tail = text.words[startWord...].joined()
        for character in tail {
            if character == remaining.first { remaining = remaining.dropFirst() }
            if remaining.isEmpty { return true }
        }
        return false
    }
}

// MARK: - Pinyin

/// Latin forms of Chinese names so "wx" or "weixin" finds 微信. `CFStringTransform` is
/// cheap enough per string; results are cached for the process.
nonisolated enum PalettePinyin {
    private static let cache = PalettePinyinCache()

    /// "wei xin" for "微信", nil when the text has no Han characters.
    static func latin(_ text: String) -> String? {
        guard text.unicodeScalars.contains(where: { $0.properties.isIdeographic }) else { return nil }
        if let cached = cache.value(for: text) { return cached }
        let mutable = NSMutableString(string: text) as CFMutableString
        guard CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false) else { return nil }
        CFStringTransform(mutable, nil, kCFStringTransformStripCombiningMarks, false)
        let result = (mutable as String).lowercased()
        cache.set(result, for: text)
        return result
    }
}

private final nonisolated class PalettePinyinCache: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    func value(for key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    func set(_ value: String, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        if storage.count > 2000 { storage.removeAll() }
        storage[key] = value
    }
}
