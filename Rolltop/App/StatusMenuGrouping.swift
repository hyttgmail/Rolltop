import Foundation

/// How Rolltop's status menu groups the commands features put there (`showInStatusMenu`):
/// one group per feature in registration order, separated; features that add a single
/// command without an icon share one group, so the menu stays short instead of a
/// separator around every lone item (Search, Shelf). Pure.
nonisolated enum StatusMenuGrouping {
    struct Entry: Equatable {
        var feature: String
        var id: String
        var showsIcon: Bool
    }

    static func groups(_ entries: [Entry]) -> [[Entry]] {
        var byFeature: [[Entry]] = []
        for entry in entries {
            if let index = byFeature.firstIndex(where: { $0.first?.feature == entry.feature }) {
                byFeature[index].append(entry)
            } else {
                byFeature.append([entry])
            }
        }
        var result: [[Entry]] = []
        var lone: [Entry] = []
        for group in byFeature {
            if group.count == 1, !group[0].showsIcon {
                lone.append(group[0])
            } else {
                if !lone.isEmpty { result.append(lone); lone = [] }
                result.append(group)
            }
        }
        if !lone.isEmpty { result.append(lone) }
        return result
    }
}
