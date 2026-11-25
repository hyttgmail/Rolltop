import Foundation
import RolltopCore

// Cross-feature services added by wave 1. The protocol, its default and its key live here
// so that the feature providing a service and the features using it never name each
// other's types (docs/CONTRACTS.md, "Services").

// MARK: - Hotkey bindings (provided by Hotkeys)

/// What a shortcut runs: a command id plus its arguments (`item.activate owner=… button=…`).
nonisolated struct HotkeyAction: Hashable, Codable, Sendable, CustomStringConvertible {
    var command: CommandID
    var arguments: [String: String]

    init(_ command: CommandID, arguments: [String: String] = [:]) {
        self.command = command
        self.arguments = arguments
    }

    var description: String {
        arguments.isEmpty ? command.rawValue
            : command.rawValue + " " + arguments.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    }

    /// Deterministic order for tie-breaks and lists.
    static func < (lhs: HotkeyAction, rhs: HotkeyAction) -> Bool { lhs.description < rhs.description }
}

/// Why a binding is not registered.
nonisolated enum HotkeyProblem: Sendable, Equatable {
    /// Another Rolltop action has the same shortcut and wins.
    case conflict(HotkeyAction)
    /// An enabled macOS shortcut (System Settings › Keyboard › Keyboard Shortcuts) uses it.
    case reservedBySystem
    /// `RegisterEventHotKey` refused it (e.g. another app registered it exclusively).
    case registrationFailed(Int32)
}

/// Shortcut bindings for other features: show a command's shortcut (palette, menus,
/// profiles), let the user change it, and react to changes through `revision`.
///
///     let hotkeys = context.services[.hotkeyBindings]
///     if let combo = hotkeys.shortcut(for: "profiles.apply", arguments: ["id": "work"]) {
///         Text(hotkeys.displayString(for: combo))
///     }
protocol HotkeyBindingProviding: AnyObject {
    /// Bumps whenever a binding, its registration state or the command list changes.
    /// Implementations are `@Observable`, so SwiftUI and `ChangeObserver` follow it.
    var revision: Int { get }
    /// The effective shortcut (the user's choice, else the command's `defaultShortcut`).
    func shortcut(for command: CommandID, arguments: [String: String]) -> KeyCombo?
    /// Sets (nil: clears) the shortcut; applies and registers it at once.
    func setShortcut(_ combo: KeyCombo?, for command: CommandID, arguments: [String: String])
    /// Why the shortcut is not active, nil when it is (or there is none).
    func problem(for command: CommandID, arguments: [String: String]) -> HotkeyProblem?
    /// The title of another Rolltop action that already uses `combo`, if any.
    func conflictingTitle(for combo: KeyCombo, excluding command: CommandID, arguments: [String: String]) -> String?
    /// While recording, every shortcut is suspended so its keys reach the recorder.
    func setRecording(_ recording: Bool)
    /// "⌃⌥⌘H".
    func displayString(for combo: KeyCombo) -> String
    /// A readable title for an action (command title, or "Click Wi-Fi" for item shortcuts).
    func title(for action: HotkeyAction) -> String
}

/// Before the Hotkeys feature registers itself: no shortcuts.
final class NoHotkeyBindings: HotkeyBindingProviding {
    var revision: Int { 0 }
    func shortcut(for command: CommandID, arguments: [String: String]) -> KeyCombo? { nil }
    func setShortcut(_ combo: KeyCombo?, for command: CommandID, arguments: [String: String]) {}
    func problem(for command: CommandID, arguments: [String: String]) -> HotkeyProblem? { nil }
    func conflictingTitle(for combo: KeyCombo, excluding command: CommandID, arguments: [String: String]) -> String? { nil }
    func setRecording(_ recording: Bool) {}
    func displayString(for combo: KeyCombo) -> String { "#\(combo.keyCode)" }
    func title(for action: HotkeyAction) -> String { action.command.rawValue }
}

extension ServiceKey where Service == any HotkeyBindingProviding {
    static var hotkeyBindings: Self { .init("hotkeys.bindings") { _ in NoHotkeyBindings() } }
}

// MARK: - Profile layout restorer (provided by Profiles)

/// Put back a captured layout and active profile marker without re-applying a profile.
/// Automations uses it for "restore the previous profile" when no profile was active
/// before the rule applied one.
protocol ProfileLayoutRestoring: AnyObject {
    /// Replaces the layout atomically and sets which profile counts as active (nil = none).
    func restoreLayout(_ layout: Layout, activeProfileID: String?)
}

/// Default when Profiles is not running: restores the layout only.
final class ProfileLayoutOnlyRestorer: ProfileLayoutRestoring {
    private let layout: LayoutStore
    init(layout: LayoutStore) { self.layout = layout }
    func restoreLayout(_ layout: Layout, activeProfileID: String?) { self.layout.replace(with: layout) }
}

extension ServiceKey where Service == any ProfileLayoutRestoring {
    static var profileLayoutRestorer: Self {
        .init("profiles.layout-restorer") { context in ProfileLayoutOnlyRestorer(layout: context.layout) }
    }
}

// MARK: - Item changes (consumed by Automations; nothing provides it yet)

/// When each owner's item image last changed, for the planned "item changed" automation
/// condition. The feature that watches item images (Capture) is expected to register an
/// implementation; until then the default reports nothing.
protocol AutomationItemChangeReporting: AnyObject {
    /// Observable implementations let rules re-evaluate on change.
    var lastChanges: [OwnerID: Date] { get }
}

final class AutomationNoItemChanges: AutomationItemChangeReporting {
    var lastChanges: [OwnerID: Date] { [:] }
}

extension ServiceKey where Service == any AutomationItemChangeReporting {
    static var automationItemChanges: Self { .init("automations.item-changes") { _ in AutomationNoItemChanges() } }
}

// MARK: - Palette results (registry kept by CommandPalette; any feature may add a provider)

import AppKit
import Observation

/// What a palette row shows at its leading edge.
enum PaletteResultIcon {
    /// An SF Symbol name.
    case symbol(String)
    /// Drawn at the row's icon size; templates take the label colour.
    case image(NSImage)
}

/// One row a feature adds to the Search panel (the command palette).
struct PaletteProvidedResult: Identifiable {
    /// Stable for the same underlying thing across queries: the palette keys its usage
    /// history (ranking by frequency and recency) by provider id + this id.
    let id: String
    var title: String
    var subtitle: String?
    var icon: PaletteResultIcon?
    /// Extra words matched besides `title` and `subtitle`; never shown.
    var keywords: [String] = []
    /// Runs when the row is chosen, after the panel has closed (or, when the user turned
    /// "close after running" off, while it stays open). A thrown error is shown to the user
    /// as a short message (`localizedDescription`).
    var action: @MainActor () async throws -> Void
    /// A second thing the row can do ("Paste" for a clipboard row), nil for none. The palette
    /// runs it on ⌘Return instead of `action`, under the same rules (after the panel has
    /// closed, errors shown the same way), and names it in its footer while the row is
    /// selected ("⌘↩ Paste").
    var alternateAction: PaletteAlternateAction?

    init(id: String, title: String, subtitle: String? = nil, icon: PaletteResultIcon? = nil,
         keywords: [String] = [], alternateAction: PaletteAlternateAction? = nil,
         action: @escaping @MainActor () async throws -> Void) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.keywords = keywords
        self.alternateAction = alternateAction
        self.action = action
    }
}

/// The ⌘Return action of a palette row (`PaletteProvidedResult.alternateAction`).
struct PaletteAlternateAction {
    /// Short and localized, a verb in Title Case like a button ("Paste").
    var title: String
    /// Same signature and rules as `PaletteProvidedResult.action`.
    var action: @MainActor () async throws -> Void

    init(title: String, action: @escaping @MainActor () async throws -> Void) {
        self.title = title
        self.action = action
    }
}

/// A source of palette rows from another feature (the Shelf's clipboard history…).
///
///     context.services[.paletteResultProviders].register(MyProvider())   // init or start
protocol PaletteResultProviding: AnyObject {
    /// `<feature-id>.<name>`, unique among providers. Also the key of the user's on/off
    /// choice in the Search settings.
    var id: String { get }
    /// Names the rows' source: shown as their tag and in the Search settings ("Clipboard").
    var title: String { get }
    /// Rows for `query` (trimmed; empty while nothing is typed: return what is worth showing
    /// before typing, usually nothing). Called on the main actor on every keystroke: answer
    /// from memory, no I/O, at most ~50 rows. A provider may match on content the palette
    /// cannot see; the palette ranks the rows with its own by title, subtitle and keywords
    /// and keeps rows it cannot match after the matched ones.
    func results(for query: String) -> [PaletteProvidedResult]
}

/// Every registered provider. The service's default *is* the registry: resolve it and call
/// `register`; never replace the service, or providers registered earlier are lost.
@Observable
final class PaletteResultProviderRegistry {
    /// In registration order.
    private(set) var providers: [any PaletteResultProviding] = []

    /// Adds a provider or replaces the one with the same id.
    func register(_ provider: any PaletteResultProviding) {
        if let index = providers.firstIndex(where: { $0.id == provider.id }) {
            providers[index] = provider
        } else {
            providers.append(provider)
        }
    }

    func unregister(id: String) {
        providers.removeAll { $0.id == id }
    }
}

extension ServiceKey where Service == PaletteResultProviderRegistry {
    static var paletteResultProviders: Self { .init("palette.result-providers") { _ in PaletteResultProviderRegistry() } }
}

// MARK: - Backup participation (consumed by Interop's backups; Profiles and Automations take part)

/// Data a feature keeps outside the settings store, or under settings keys it handles
/// itself, that belongs in a Rolltop backup (`.rolltopbackup`). The backup holds the exportable
/// settings, the layout, and one section per participant; export, import, restore and
/// "Reset everything" reach the feature's data only through these methods.
///
/// Rules for participants:
/// - Keep ids on import (rules and links refer to them); the import replaces the data.
/// - Never put approvals or other per-Mac trust decisions in the data. Anything that can
///   run a script (script conditions, script widgets) arrives disabled after an import.
/// - Data is self-describing (JSON with its own format id and version) and tolerates
///   unknown fields from newer versions.
///
///     context.services[.backupParticipants].register(MyBackupParticipant(…))   // in init(context:)
protocol BackupParticipating: AnyObject {
    /// Section id in the backup file: the feature id (`profiles`, `automations`).
    var backupID: String { get }
    /// Shown in the import preview's "what to bring in" choice ("Profiles").
    var backupTitle: String { get }
    /// Settings keys this participant exports itself. The backup's settings section leaves
    /// them out, and importing only the settings section keeps their current values.
    var backupOwnedSettingsKeys: Set<String> { get }
    /// The participant's current data.
    func exportBackupData() throws -> Data
    /// One line for the import preview ("3 profiles"). Throws when `data` cannot be
    /// imported; the backup checks every selected section with it before changing anything.
    func backupSummary(for data: Data) throws -> String
    /// Replaces the participant's data with `data`.
    func importBackupData(_ data: Data) throws
    /// Removes the participant's data ("Reset everything").
    func resetBackupData() throws
}

/// The participants, in registration order. Features register in `init(context:)`.
final class BackupParticipantRegistry {
    private(set) var participants: [any BackupParticipating] = []

    func register(_ participant: any BackupParticipating) {
        participants.removeAll { $0.backupID == participant.backupID }
        participants.append(participant)
    }

    func participant(id: String) -> (any BackupParticipating)? {
        participants.first { $0.backupID == id }
    }
}

extension ServiceKey where Service == BackupParticipantRegistry {
    static var backupParticipants: Self { .init("interop.backup-participants") { _ in BackupParticipantRegistry() } }
}
