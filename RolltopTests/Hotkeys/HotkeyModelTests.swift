import Carbon.HIToolbox
import Foundation
import RolltopCore
import Testing
@testable import Rolltop

private let cmdH = KeyCombo(keyCode: UInt16(kVK_ANSI_H), modifiers: [.command, .option, .control])
private let cmdJ = KeyCombo(keyCode: UInt16(kVK_ANSI_J), modifiers: [.command, .option])
private let toggle = HotkeyAction(.toggleHidden)
private let collapse = HotkeyAction(.collapse)
private let wifiClick = HotkeyAction(.activateItem, arguments: ["owner": "system:wifi", "button": "left"])

@Suite struct HotkeyResolverTests {
    @Test func defaultsApplyUntilChangedOrCleared() {
        let defaults = [toggle: cmdH]
        #expect(HotkeyResolver.resolve(defaults: defaults, overrides: [])[toggle] == ResolvedBinding(action: toggle, combo: cmdH, isDefault: true))
        let changed = HotkeyResolver.resolve(defaults: defaults, overrides: [HotkeyOverride(action: toggle, combo: cmdJ)])
        #expect(changed[toggle] == ResolvedBinding(action: toggle, combo: cmdJ, isDefault: false))
        let cleared = HotkeyResolver.resolve(defaults: defaults, overrides: [HotkeyOverride(action: toggle, combo: nil)])
        #expect(cleared[toggle] == nil)
    }

    @Test func userChoiceBeatsADefaultOnTheSameCombination() {
        let bindings = HotkeyResolver.resolve(defaults: [toggle: cmdH], overrides: [HotkeyOverride(action: wifiClick, combo: cmdH)])
        let plan = HotkeyResolver.plan(bindings)
        #expect(plan.active == [wifiClick: cmdH])
        #expect(plan.conflicts == [toggle: wifiClick])
    }

    @Test func equalRanksResolveInActionOrder() {
        let bindings = HotkeyResolver.resolve(defaults: [:], overrides: [HotkeyOverride(action: toggle, combo: cmdH),
                                                                          HotkeyOverride(action: collapse, combo: cmdH)])
        let plan = HotkeyResolver.plan(bindings)
        // "visibility.collapse" sorts before "visibility.toggle-hidden".
        #expect(plan.active == [collapse: cmdH])
        #expect(plan.conflicts == [toggle: collapse])
        #expect(HotkeyResolver.owner(of: cmdH, excluding: toggle, in: bindings) == collapse)
        #expect(HotkeyResolver.owner(of: cmdJ, excluding: toggle, in: bindings) == nil)
    }

    @Test func settingTheDefaultAgainRemovesTheOverride() {
        var overrides = HotkeyResolver.setting(cmdJ, for: toggle, defaultCombo: cmdH, in: [])
        #expect(overrides == [HotkeyOverride(action: toggle, combo: cmdJ)])
        overrides = HotkeyResolver.setting(cmdH, for: toggle, defaultCombo: cmdH, in: overrides)
        #expect(overrides.isEmpty)
        overrides = HotkeyResolver.setting(nil, for: toggle, defaultCombo: cmdH, in: overrides)
        #expect(overrides == [HotkeyOverride(action: toggle, combo: nil)])
    }

    @Test func clearingWithoutADefault() {
        let set = HotkeyResolver.setting(cmdJ, for: collapse, defaultCombo: nil, in: [])
        #expect(HotkeyResolver.setting(nil, for: collapse, defaultCombo: nil, in: set).isEmpty)
        // Per-item rows stay listed without a shortcut.
        #expect(HotkeyResolver.setting(nil, for: wifiClick, defaultCombo: nil, keepEmptyRow: true, in: [])
            == [HotkeyOverride(action: wifiClick, combo: nil)])
    }

    @Test func overridesRoundTripThroughSettings() throws {
        let suite = "com.alphapengwang.rolltop.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        let stored = [HotkeyOverride(action: wifiClick, combo: cmdH), HotkeyOverride(action: toggle, combo: nil)]
        settings[HotkeySettings.overrides] = stored
        #expect(SettingsStore(defaults: defaults)[HotkeySettings.overrides] == stored)
    }
}

@Suite struct KeyComboRulesTests {
    @Test func needsARealModifierExceptForFunctionKeys() {
        #expect(KeyComboRules.validate(KeyCombo(keyCode: UInt16(kVK_ANSI_A), modifiers: [])) == .needsModifier)
        #expect(KeyComboRules.validate(KeyCombo(keyCode: UInt16(kVK_ANSI_A), modifiers: [.shift])) == .needsModifier)
        #expect(KeyComboRules.validate(KeyCombo(keyCode: UInt16(kVK_ANSI_A), modifiers: [.option])) == nil)
        #expect(KeyComboRules.validate(KeyCombo(keyCode: UInt16(kVK_ANSI_A), modifiers: [.control, .shift])) == nil)
        #expect(KeyComboRules.validate(KeyCombo(keyCode: UInt16(kVK_F5), modifiers: [])) == nil)
        #expect(KeyComboRules.validate(KeyCombo(keyCode: UInt16(kVK_Command), modifiers: [.command])) == .modifierOnly)
    }

    @Test func escapeCancelsDeleteClears() {
        #expect(KeyComboRules.decide(keyCode: UInt16(kVK_Escape), modifiers: []) == .cancel)
        #expect(KeyComboRules.decide(keyCode: UInt16(kVK_Delete), modifiers: []) == .clear)
        #expect(KeyComboRules.decide(keyCode: UInt16(kVK_ForwardDelete), modifiers: []) == .clear)
        // With a modifier they are ordinary shortcuts.
        let commandEscape = KeyCombo(keyCode: UInt16(kVK_Escape), modifiers: [.command])
        #expect(KeyComboRules.decide(keyCode: UInt16(kVK_Escape), modifiers: [.command]) == .accept(commandEscape))
        #expect(KeyComboRules.decide(keyCode: UInt16(kVK_ANSI_K), modifiers: []) == .reject(.needsModifier))
        #expect(KeyComboRules.decide(keyCode: UInt16(kVK_ANSI_H), modifiers: [.command, .option, .control]) == .accept(cmdH))
    }

    @Test func carbonModifiersRoundTrip() {
        let all: KeyModifiers = [.command, .option, .control, .shift]
        #expect(KeyComboRules.carbonModifiers(all) == UInt32(cmdKey | optionKey | controlKey | shiftKey))
        #expect(KeyComboRules.modifiers(fromCarbon: KeyComboRules.carbonModifiers(all)) == all)
        // Keypad / fn bits are ignored.
        #expect(KeyComboRules.modifiers(fromCarbon: UInt32(cmdKey) | 0x80_0000) == [.command])
    }

    @Test func enabledSystemShortcutsOnly() {
        // Shapes as returned by CopySymbolicHotKeys on macOS 27.2 (2304 = ⌘⌥).
        let entries: [[String: Any]] = [
            [kHISymbolicHotKeyCode as String: NSNumber(value: 48), kHISymbolicHotKeyModifiers as String: NSNumber(value: 256),
             kHISymbolicHotKeyEnabled as String: true],
            [kHISymbolicHotKeyCode as String: NSNumber(value: 53), kHISymbolicHotKeyModifiers as String: NSNumber(value: 2304),
             kHISymbolicHotKeyEnabled as String: true],
            [kHISymbolicHotKeyCode as String: NSNumber(value: 20), kHISymbolicHotKeyModifiers as String: NSNumber(value: 768),
             kHISymbolicHotKeyEnabled as String: false],
            [kHISymbolicHotKeyCode as String: NSNumber(value: 65535), kHISymbolicHotKeyModifiers as String: NSNumber(value: 0),
             kHISymbolicHotKeyEnabled as String: true],
        ]
        #expect(KeyComboRules.systemCombos(fromSymbolicHotKeys: entries) == [
            KeyCombo(keyCode: UInt16(kVK_Tab), modifiers: [.command]),
            KeyCombo(keyCode: UInt16(kVK_Escape), modifiers: [.command, .option]),
        ])
    }

    @Test func liveSystemShortcutsIncludeCommandTab() {
        // Read-only: macOS's own table of enabled shortcuts.
        #expect(HotkeyController.enabledSystemCombos().contains(KeyCombo(keyCode: UInt16(kVK_Tab), modifiers: [.command])))
    }
}

@Suite struct KeyComboFormatterTests {
    @Test func glyphsInStandardOrder() {
        #expect(KeyComboFormatter.modifierGlyphs([.command, .shift, .option, .control]) == "⌃⌥⇧⌘")
        #expect(KeyComboFormatter.string(for: KeyCombo(keyCode: UInt16(kVK_F5), modifiers: [])) == "F5")
        #expect(KeyComboFormatter.string(for: KeyCombo(keyCode: UInt16(kVK_Space), modifiers: [.option])) == "⌥Space")
        #expect(KeyComboFormatter.string(for: KeyCombo(keyCode: UInt16(kVK_LeftArrow), modifiers: [.control, .command])) == "⌃⌘←")
        #expect(KeyComboFormatter.string(for: KeyCombo(keyCode: UInt16(kVK_Return), modifiers: [.command])) == "⌘↩")
    }

    @Test func lettersFollowTheLayout() {
        // Any Latin layout labels the ANSI H key with an H.
        #expect(KeyComboFormatter.string(for: cmdH) == "⌃⌥⌘H")
    }
}
