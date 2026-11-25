import Foundation

/// A pane as the sidebar sees it: plain values, so the filtering and grouping rules are
/// testable without views.
nonisolated struct SidebarItem: Equatable, Sendable {
    let id: String
    let title: String
    let sortOrder: Int
    /// The pane's search keywords (`SettingsPane.keywords`), localized.
    var keywords: [String] = []
}

/// Sidebar rules: groups follow the sort ranges in docs/CONTRACTS.md, search matches
/// titles and keywords.
nonisolated enum SettingsSidebar {
    /// 0–99 general, 100–199 menu bar items, 200–299 behaviour, 300–399 appearance,
    /// 400–499 automation, 500–899 anything else, 900+ about/advanced.
    static func group(forSortOrder order: Int) -> Int {
        switch order {
        case ..<100: 0
        case 100..<200: 1
        case 200..<300: 2
        case 300..<400: 3
        case 400..<500: 4
        case 500..<900: 5
        default: 9
        }
    }

    /// Items where every word of `query` is found in the title or in one of the keywords
    /// (case- and diacritic-insensitive), in their original order. An empty query matches
    /// everything.
    static func filter(_ items: [SidebarItem], query: String) -> [SidebarItem] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return items }
        return items.filter { item in
            words.allSatisfy { word in
                item.title.localizedStandardContains(word) || item.keywords.contains { $0.localizedStandardContains(word) }
            }
        }
    }

    /// Consecutive runs of items in the same group (input is sorted by sort order).
    static func groups(_ items: [SidebarItem]) -> [[SidebarItem]] {
        var result: [[SidebarItem]] = []
        for item in items {
            if let last = result.last?.last, group(forSortOrder: last.sortOrder) == group(forSortOrder: item.sortOrder) {
                result[result.count - 1].append(item)
            } else {
                result.append([item])
            }
        }
        return result
    }

    /// The pane to show: the requested one when it exists, else the last one viewed, else
    /// the first.
    static func selection(requested: String?, saved: String?, available: [String]) -> String? {
        if let requested, available.contains(requested) { return requested }
        if let saved, available.contains(saved) { return saved }
        return available.first
    }
}
