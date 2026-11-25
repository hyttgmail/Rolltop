import Foundation
import RolltopCore

/// Settings of the Reveal feature (`rolltop.reveal.*`). Every change applies immediately.
enum RevealSettings {
    // Triggers
    static let clickEmptySpace = SettingsKey<Bool>("rolltop.reveal.click-empty", default: true)
    static let hover = SettingsKey<Bool>("rolltop.reveal.hover", default: false)
    /// Seconds, 0–2.
    static let hoverDelay = SettingsKey<Double>("rolltop.reveal.hover-delay", default: 0.3)
    static let scroll = SettingsKey<Bool>("rolltop.reveal.scroll", default: false)
    /// A further scroll down while revealed also shows always-hidden items.
    static let scrollRevealsAlwaysHidden = SettingsKey<Bool>("rolltop.reveal.scroll-always-hidden", default: false)

    // Rehide
    /// Seconds; 0 means never.
    static let rehideDelay = SettingsKey<Int>("rolltop.reveal.rehide-delay", default: 10)
    static let rehideOnClickOutside = SettingsKey<Bool>("rolltop.reveal.rehide-click-outside", default: true)
    static let rehideOnAppSwitch = SettingsKey<Bool>("rolltop.reveal.rehide-app-switch", default: false)

    // Modes
    static let makeRoom = SettingsKey<Bool>("rolltop.reveal.make-room", default: false)
    static let makeRoomScope = SettingsKey<String>("rolltop.reveal.make-room-scope", default: RevealModes.MakeRoomScope.always.rawValue)
    static let hideEverything = SettingsKey<Bool>("rolltop.reveal.hide-everything", default: false)
    /// Keep "hide everything" on after Rolltop restarts.
    static let hideEverythingPersists = SettingsKey<Bool>("rolltop.reveal.hide-everything-persists", default: false)

    static let rehideChoices = [5, 10, 15, 30, 60, 0]
    static let hoverDelayRange: ClosedRange<Double> = 0...2

    /// Removes every stored Reveal value (Debug cleanup after live tests).
    static func resetAll(in settings: SettingsStore) {
        settings.reset(clickEmptySpace)
        settings.reset(hover)
        settings.reset(hoverDelay)
        settings.reset(scroll)
        settings.reset(scrollRevealsAlwaysHidden)
        settings.reset(rehideDelay)
        settings.reset(rehideOnClickOutside)
        settings.reset(rehideOnAppSwitch)
        settings.reset(makeRoom)
        settings.reset(makeRoomScope)
        settings.reset(hideEverything)
        settings.reset(hideEverythingPersists)
    }

    static var allKeyNames: [String] {
        [clickEmptySpace.name, hover.name, hoverDelay.name, scroll.name, scrollRevealsAlwaysHidden.name,
         rehideDelay.name, rehideOnClickOutside.name, rehideOnAppSwitch.name, makeRoom.name, makeRoomScope.name,
         hideEverything.name, hideEverythingPersists.name]
    }
}

extension CommandID {
    static let revealToggleMakeRoom: CommandID = "reveal.toggle-make-room"
    static let revealToggleHideEverything: CommandID = "reveal.toggle-hide-everything"
    static let revealKeepRevealed: CommandID = "reveal.keep-revealed"
}
