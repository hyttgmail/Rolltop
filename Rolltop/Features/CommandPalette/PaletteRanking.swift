import Foundation

/// What the ranker knows about one row. Pure data, built once per panel refresh.
nonisolated struct PaletteCandidate: Sendable {
    /// Row type; the raw value is the tie-break priority (items first).
    enum Kind: Int, Sendable, Comparable, CaseIterable {
        case item = 0
        case profile
        case command
        case setting
        case provided

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Stable row key; usage history is stored under it.
    var key: String
    var kind: Kind
    var title: String
    /// Matched after the title, never with subsequences: bundle ids, pinyin, profile names, keywords.
    var alternates: [String]
    /// Order among the rows listed before anything is typed (hidden items); nil: not listed.
    var emptyQueryOrder: Int?

    let titleText: PaletteSearchText
    let alternateTexts: [PaletteSearchText]

    init(key: String, kind: Kind, title: String, alternates: [String] = [], emptyQueryOrder: Int? = nil) {
        self.key = key
        self.kind = kind
        self.title = title
        self.alternates = alternates
        self.emptyQueryOrder = emptyQueryOrder
        titleText = PaletteSearchText(title)
        var alternateTexts = alternates.filter { !$0.isEmpty }.map(PaletteSearchText.init)
        if let pinyin = PalettePinyin.latin(title) { alternateTexts.append(PaletteSearchText(pinyin)) }
        for alternate in alternates {
            if let pinyin = PalettePinyin.latin(alternate) { alternateTexts.append(PaletteSearchText(pinyin)) }
        }
        self.alternateTexts = alternateTexts
    }
}

/// One ranked row: index into the candidates and how it matched.
nonisolated struct PaletteRanked: Sendable, Equatable {
    let index: Int
    let tier: PaletteMatchTier
    let matchedTitle: Bool
}

/// Orders candidates for a query. Pure and deterministic.
///
/// Order: match tier (exact > prefix > word prefix > acronym > subsequence > provider-only),
/// then a title match before an alternate-text match, then row type (items, profiles,
/// commands, settings, other features' rows), then usage (frequency with recency decay),
/// then the shorter title, then alphabetical.
nonisolated enum PaletteRanker {
    static func rank(_ candidates: [PaletteCandidate], query: PaletteQuery, usage: PaletteUsage, now: Date) -> [PaletteRanked] {
        guard !query.isEmpty else { return [] }
        var ranked: [(PaletteRanked, Double)] = []
        for (index, candidate) in candidates.enumerated() {
            let titleTier = PaletteMatcher.match(query, in: candidate.titleText)
            let alternateTier = candidate.alternateTexts
                .compactMap { PaletteMatcher.match(query, in: $0, allowsSubsequence: false) }.max()
            let tier: PaletteMatchTier
            let matchedTitle: Bool
            switch (titleTier, alternateTier) {
            case let (title?, alternate?):
                tier = max(title, alternate)
                matchedTitle = title >= alternate
            case let (title?, nil):
                tier = title
                matchedTitle = true
            case let (nil, alternate?):
                tier = alternate
                matchedTitle = false
            case (nil, nil):
                // Providers already decided their rows match (they may search content).
                guard candidate.kind == .provided else { continue }
                tier = .provided
                matchedTitle = false
            }
            ranked.append((PaletteRanked(index: index, tier: tier, matchedTitle: matchedTitle), usage.score(for: candidate.key, at: now)))
        }
        ranked.sort { lhs, rhs in
            let (a, aUsage) = lhs
            let (b, bUsage) = rhs
            if a.tier != b.tier { return a.tier > b.tier }
            if a.matchedTitle != b.matchedTitle { return a.matchedTitle }
            let ca = candidates[a.index], cb = candidates[b.index]
            if ca.kind != cb.kind { return ca.kind < cb.kind }
            if aUsage != bUsage { return aUsage > bUsage }
            if ca.title.count != cb.title.count { return ca.title.count < cb.title.count }
            if ca.title != cb.title { return ca.title.localizedStandardCompare(cb.title) == .orderedAscending }
            return a.index < b.index
        }
        return ranked.map(\.0)
    }

    /// Rows before anything is typed: hidden items (that is what people come for), then
    /// recently used rows, then other features' rows for the empty query. When all of that
    /// is empty, every item.
    static func emptyQuery(_ candidates: [PaletteCandidate], usage: PaletteUsage, now: Date, recentLimit: Int = 8) -> [Int] {
        var result = candidates.indices
            .filter { candidates[$0].emptyQueryOrder != nil }
            .sorted { (candidates[$0].emptyQueryOrder!, $0) < (candidates[$1].emptyQueryOrder!, $1) }
        var listed = Set(result)
        let indexByKey = Dictionary(candidates.enumerated().map { ($1.key, $0) }, uniquingKeysWith: { first, _ in first })
        var recents = 0
        for key in usage.recentKeys(at: now) where recents < recentLimit {
            guard let index = indexByKey[key], !listed.contains(index), candidates[index].kind != .provided else { continue }
            result.append(index)
            listed.insert(index)
            recents += 1
        }
        for index in candidates.indices where candidates[index].kind == .provided && !listed.contains(index) {
            result.append(index)
            listed.insert(index)
        }
        if result.isEmpty {
            result = candidates.indices.filter { candidates[$0].kind == .item }
        }
        return result
    }
}
