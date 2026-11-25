import Foundation
import RolltopCore

/// "Open group <name>" rows in the Search panel (the command palette), through its
/// result-provider contract (`PaletteResultProviding`, App/Contracts/FeatureServices.swift).
/// Only groups that are turned on, only once something is typed. The palette gives the
/// panel the keyboard, so the group opens in keyboard mode.
final class CustomItemsGroupPaletteProvider: PaletteResultProviding {
    private let store: CustomItemsStore
    private let open: (String) -> Void

    init(store: CustomItemsStore, open: @escaping (String) -> Void) {
        self.store = store
        self.open = open
    }

    var id: String { "custom-items.groups" }
    var title: String { String(localized: "Groups", table: "CustomItems") }

    func results(for query: String) -> [PaletteProvidedResult] {
        guard !query.isEmpty else { return [] }
        // The palette keeps rows it cannot match after its own, so only matching rows go back.
        return CustomItemsGroupRows.rows(store.model.groups.filter { store.isActive($0.id) }).compactMap { row in
            let title = String(localized: "Open group \(row.name)", table: "CustomItems")
            guard CustomItemsGroupRows.matches(query, title: title, name: row.name) else { return nil }
            let open = open
            return PaletteProvidedResult(id: row.id, title: title, icon: .symbol(row.symbol), keywords: [row.name]) { open(row.id) }
        }
    }
}

/// The rows' data. Pure.
nonisolated enum CustomItemsGroupRows {
    struct Row: Equatable {
        var id: String
        var name: String
        var symbol: String
    }

    /// Every word of the query appears in the row's title or the group's name (ignoring
    /// case and diacritics), so "open fix" and "fixtures" find "Open group Fixtures".
    static func matches(_ query: String, title: String, name: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return false }
        let haystack = title + " " + name
        return words.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    static func rows(_ groups: [CustomItemGroup]) -> [Row] {
        groups.map { group in
            let name = group.name.trimmingCharacters(in: .whitespaces)
            return Row(id: group.id, name: name.isEmpty ? String(localized: "Group", table: "CustomItems") : name,
                       symbol: group.icon.kind == .symbol && !group.icon.value.isEmpty ? group.icon.value : "square.grid.2x2")
        }
    }
}
