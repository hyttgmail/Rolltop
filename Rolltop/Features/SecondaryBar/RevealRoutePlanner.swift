import Foundation
import RolltopCore

/// Pure routing decisions for the reveal commands (`RevealRouting`).
nonisolated enum RevealRoutePlanner {
    enum Request: Sendable {
        case toggle
        case show
        case collapse
    }

    enum Step: Equatable, Sendable {
        case presentPanel
        case dismissPanel
        case engineToggle
        case engineShow
        case engineCollapse
    }

    /// Whether a reveal on one display uses the Rolltop Bar (true) or shows hidden items
    /// inline (false).
    /// - Parameters:
    ///   - enabled: "Show hidden items in the Rolltop Bar".
    ///   - onlyWithNotch: "Use the Rolltop Bar only on displays with a notch".
    ///   - whenFull: "Use the Rolltop Bar when the menu bar is full".
    ///   - hasNotch: the reveal's display has a notch (`safeAreaInsets.top > 0`).
    ///   - overflows: that display's bar shows macOS's overflow chevron, or an inline reveal
    ///     there overflowed before (`remembered`).
    static func usesRolltopBar(enabled: Bool, onlyWithNotch: Bool, whenFull: Bool, hasNotch: Bool, overflows: Bool) -> Bool {
        if whenFull && overflows { return true }
        guard enabled else { return false }
        return hasNotch || !onlyWithNotch
    }

    // MARK: When the menu bar is full

    /// A display where an inline reveal overflowed stays remembered (the key it was learned
    /// under: layout, present owners, screens) while the switch is on and the key is
    /// unchanged; otherwise it is forgotten (nil) and the next reveal there is inline again.
    static func remembered<Key: Equatable>(_ stored: Key?, whenFull: Bool, current: Key) -> Key? {
        guard whenFull, let stored, stored == current else { return nil }
        return stored
    }

    /// Watch an inline reveal for macOS's overflow chevron: only hidden items revealed inline
    /// (never "Show All Items"), with the switch on.
    static func watchesForOverflow(whenFull: Bool, request: Request, usedRolltopBar: Bool, level: PresentationLevel) -> Bool {
        whenFull && !usedRolltopBar && request != .collapse && level == .hiddenRevealed
    }

    /// While watching: switch the inline reveal to the Rolltop Bar once the chevron appeared on
    /// the reveal's display, as long as that reveal is still up.
    static func switchesAfterOverflow(whenFull: Bool, level: PresentationLevel, chevron: Bool) -> Bool {
        whenFull && level == .hiddenRevealed && chevron
    }

    /// - Parameters:
    ///   - useRolltopBar: this reveal uses the Rolltop Bar (`usesRolltopBar`).
    ///   - panelVisible: the Rolltop Bar is on screen.
    ///   - level: the engine's presentation level.
    ///   - justDismissedByClick: the panel was closed by a click outside a moment ago. The
    ///     same click (on Rolltop's item or the empty menu bar) also runs toggle-hidden, which
    ///     must not reopen it.
    static func plan(_ request: Request, useRolltopBar: Bool, panelVisible: Bool, level: PresentationLevel,
                     justDismissedByClick: Bool) -> [Step] {
        guard useRolltopBar else {
            // Inline, as before routing existed; a panel left over from a setting change closes.
            let dismiss: [Step] = panelVisible ? [.dismissPanel] : []
            switch request {
            case .toggle: return dismiss + [.engineToggle]
            case .show: return dismiss + [.engineShow]
            case .collapse: return dismiss + [.engineCollapse]
            }
        }
        switch request {
        case .toggle:
            if panelVisible { return [.dismissPanel] }
            if justDismissedByClick { return [] }
            // Items revealed inline (toggle-all, or before the setting changed): toggle off.
            if level > .collapsed { return [.engineCollapse] }
            return [.presentPanel]
        case .show:
            return level > .collapsed ? [.engineCollapse, .presentPanel] : [.presentPanel]
        case .collapse:
            return (panelVisible ? [.dismissPanel] : []) + [.engineCollapse]
        }
    }

    /// Owners listed for a section: assignable, not Rolltop's own, present in the bar (items
    /// reported, slots drawn, or carried over while hidden) and not in `excluding` (owners an
    /// automation forces visible are in the menu bar already). Catalog order (left to right).
    static func owners(in section: Section, entries: [CatalogEntry], excluding: Set<OwnerID> = []) -> [OwnerID] {
        entries.compactMap { entry in
            guard let owner = entry.owner, !entry.isOwn, entry.section == section, !excluding.contains(owner) else { return nil }
            let present = entry.itemCount > 0 || !entry.slots.isEmpty || entry.isCarriedOver || entry.isUnreadable
            return present ? owner : nil
        }
    }
}
