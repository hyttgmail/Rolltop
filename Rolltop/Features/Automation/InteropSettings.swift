import Foundation
import RolltopCore

/// Settings keys of the Interop feature (links, Shortcuts, AppleScript, backups).
///
/// The link policy is a security decision about this Mac, like the script approvals of
/// Automations: every key here is marked transient, so a backup or profile never carries
/// it, an imported file cannot loosen it, and only "Reset everything" (which clears these
/// keys itself) or the Integrations pane changes it.
enum InteropSettings {
    /// Master switch for `rolltop://` links.
    static let linksEnabled = SettingsKey<Bool>("rolltop.interop.links-enabled", default: true)
    /// Links whose sender macOS does not identify as an app (`open rolltop://…` from a script
    /// or terminal arrives this way).
    static let allowUnknownSenders = SettingsKey<Bool>("rolltop.interop.links-unknown-senders", default: true)
    /// Links may also run commands that change settings (sections, appearance, pausing
    /// automations…). Commands that only change what is shown are always allowed.
    static let allowSettingsCommands = SettingsKey<Bool>("rolltop.interop.links-settings-commands", default: false)
    /// Apps the user allowed or blocked, newest decision last.
    static let linkApps = SettingsKey<[InteropLinkAppRecord]>("rolltop.interop.link-apps", default: [])
    /// Focus filter: what to put back when the Focus that applied a profile ends.
    static let focusRestore = SettingsKey<InteropFocusRestoreState?>("rolltop.interop.focus-restore", default: nil)

    /// Marks every key transient; called from `init(context:)`.
    static func markTransient(in settings: SettingsStore) {
        settings.markTransient(linksEnabled)
        settings.markTransient(allowUnknownSenders)
        settings.markTransient(allowSettingsCommands)
        settings.markTransient(linkApps)
        settings.markTransient(focusRestore)
    }

    /// Back to defaults ("Reset everything"; transient keys survive `replaceAll`).
    static func reset(in settings: SettingsStore) {
        resetLinkPolicy(in: settings)
        settings.reset(focusRestore)
    }

    static func resetLinkPolicy(in settings: SettingsStore) {
        settings.reset(linksEnabled)
        settings.reset(allowUnknownSenders)
        settings.reset(allowSettingsCommands)
        settings.reset(linkApps)
    }
}

/// What the Focus filter puts back when its Focus ends: the profile that was active
/// before, else the layout from before (with no active profile).
nonisolated struct InteropFocusRestoreState: Codable, Hashable, Sendable {
    var appliedProfileID: String
    var previousProfileID: String?
    var previousLayout: Layout
}

/// A remembered answer for one app.
nonisolated struct InteropLinkAppRecord: Codable, Hashable, Sendable, Identifiable {
    enum Decision: String, Codable, Sendable { case allowed, blocked }

    var bundleID: String
    var name: String
    var decision: Decision
    var decidedAt: Date

    var id: String { bundleID }
}
