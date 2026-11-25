import Carbon.HIToolbox
import Foundation
import RolltopCore

// Bindings between commands and key combinations. Pure: resolution, conflicts, validation
// and Carbon modifier conversion are free of AppKit and Carbon calls so they can be tested.

/// A user's choice for one action. `combo == nil` clears the action (a command's default
/// shortcut then no longer applies); for actions without a default it keeps the row listed.
nonisolated struct HotkeyOverride: Codable, Sendable, Equatable {
    var action: HotkeyAction
    var combo: KeyCombo?
}

nonisolated enum HotkeySettings {
    static let overrides = SettingsKey<[HotkeyOverride]>("rolltop.hotkeys.bindings", default: [])
}

/// One action's effective shortcut.
nonisolated struct ResolvedBinding: Sendable, Equatable {
    var action: HotkeyAction
    var combo: KeyCombo
    /// The command's `defaultShortcut`, not changed by the user.
    var isDefault: Bool
}

nonisolated enum HotkeyResolver {
    /// Defaults unless overridden; an override with `nil` removes the action.
    static func resolve(defaults: [HotkeyAction: KeyCombo], overrides: [HotkeyOverride]) -> [HotkeyAction: ResolvedBinding] {
        var result: [HotkeyAction: ResolvedBinding] = [:]
        for (action, combo) in defaults {
            result[action] = ResolvedBinding(action: action, combo: combo, isDefault: true)
        }
        for override in overrides {
            if let combo = override.combo {
                result[override.action] = ResolvedBinding(action: override.action, combo: combo, isDefault: false)
            } else {
                result[override.action] = nil
            }
        }
        return result
    }

    /// Which binding gets each combination: one the user set beats a default, then the
    /// first in `HotkeyAction` order. Returns the winners and, for every loser, its winner.
    static func plan(_ bindings: [HotkeyAction: ResolvedBinding]) -> (active: [HotkeyAction: KeyCombo], conflicts: [HotkeyAction: HotkeyAction]) {
        var active: [HotkeyAction: KeyCombo] = [:]
        var conflicts: [HotkeyAction: HotkeyAction] = [:]
        let byCombo = Dictionary(grouping: bindings.values, by: \.combo)
        for (combo, group) in byCombo {
            let ordered = group.sorted { lhs, rhs in
                if lhs.isDefault != rhs.isDefault { return !lhs.isDefault }
                return lhs.action < rhs.action
            }
            guard let winner = ordered.first else { continue }
            active[winner.action] = combo
            for loser in ordered.dropFirst() { conflicts[loser.action] = winner.action }
        }
        return (active, conflicts)
    }

    /// The action that already uses `combo`, other than `action`.
    static func owner(of combo: KeyCombo, excluding action: HotkeyAction,
                      in bindings: [HotkeyAction: ResolvedBinding]) -> HotkeyAction? {
        bindings.values.filter { $0.combo == combo && $0.action != action }.map(\.action).sorted(by: <).first
    }

    /// New overrides after the user set `combo` (nil: cleared) for `action`.
    /// - With a default: choosing the default again removes the override, so a later change
    ///   of the default applies; clearing stores an explicit "none".
    /// - Without a default: clearing removes the override, unless `keepEmptyRow` (per-item
    ///   rows stay listed until the user removes them).
    static func setting(_ combo: KeyCombo?, for action: HotkeyAction, defaultCombo: KeyCombo?,
                        keepEmptyRow: Bool = false, in overrides: [HotkeyOverride]) -> [HotkeyOverride] {
        var result = overrides.filter { $0.action != action }
        if let defaultCombo {
            if combo != defaultCombo { result.append(HotkeyOverride(action: action, combo: combo)) }
        } else if combo != nil || keepEmptyRow {
            result.append(HotkeyOverride(action: action, combo: combo))
        }
        return result
    }
}

/// What the recorder does with a key press.
nonisolated enum RecorderDecision: Sendable, Equatable {
    case cancel
    case clear
    case reject(RecorderRejection)
    case accept(KeyCombo)
}

nonisolated enum RecorderRejection: Sendable, Equatable {
    /// Needs ⌘, ⌥ or ⌃ (function keys excepted).
    case needsModifier
    /// A modifier key alone.
    case modifierOnly
}

nonisolated enum KeyComboRules {
    static let functionKeys: Set<UInt16> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ].reduce(into: Set<UInt16>()) { $0.insert(UInt16($1)) }

    static let modifierKeys: Set<UInt16> = [
        kVK_Command, kVK_RightCommand, kVK_Shift, kVK_RightShift, kVK_Option, kVK_RightOption,
        kVK_Control, kVK_RightControl, kVK_CapsLock, kVK_Function,
    ].reduce(into: Set<UInt16>()) { $0.insert(UInt16($1)) }

    static func isFunctionKey(_ keyCode: UInt16) -> Bool { functionKeys.contains(keyCode) }

    /// Shift alone does not count: Shift+A is just typing a capital A.
    static func validate(_ combo: KeyCombo) -> RecorderRejection? {
        if modifierKeys.contains(combo.keyCode) { return .modifierOnly }
        if isFunctionKey(combo.keyCode) { return nil }
        return combo.modifiers.isDisjoint(with: [.command, .option, .control]) ? .needsModifier : nil
    }

    /// Escape cancels and Delete clears, both without modifiers; anything else must be valid.
    static func decide(keyCode: UInt16, modifiers: KeyModifiers) -> RecorderDecision {
        if modifiers.isEmpty, keyCode == UInt16(kVK_Escape) { return .cancel }
        if modifiers.isEmpty, keyCode == UInt16(kVK_Delete) || keyCode == UInt16(kVK_ForwardDelete) { return .clear }
        let combo = KeyCombo(keyCode: keyCode, modifiers: modifiers)
        if let rejection = validate(combo) { return .reject(rejection) }
        return .accept(combo)
    }

    // MARK: Carbon modifiers

    static func carbonModifiers(_ modifiers: KeyModifiers) -> UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    /// Ignores every bit other than the four modifiers (keypad, fn, caps lock…).
    static func modifiers(fromCarbon carbon: UInt32) -> KeyModifiers {
        var result: KeyModifiers = []
        if carbon & UInt32(cmdKey) != 0 { result.insert(.command) }
        if carbon & UInt32(optionKey) != 0 { result.insert(.option) }
        if carbon & UInt32(controlKey) != 0 { result.insert(.control) }
        if carbon & UInt32(shiftKey) != 0 { result.insert(.shift) }
        return result
    }

    /// Enabled macOS shortcuts from `CopySymbolicHotKeys` entries.
    static func systemCombos(fromSymbolicHotKeys entries: [[String: Any]]) -> Set<KeyCombo> {
        var result: Set<KeyCombo> = []
        for entry in entries {
            guard (entry[kHISymbolicHotKeyEnabled as String] as? Bool) == true,
                  let code = (entry[kHISymbolicHotKeyCode as String] as? NSNumber)?.intValue,
                  let modifiers = (entry[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value,
                  code >= 0, code < 0xFFFF else { continue }
            result.insert(KeyCombo(keyCode: UInt16(code), modifiers: Self.modifiers(fromCarbon: modifiers)))
        }
        return result
    }
}
