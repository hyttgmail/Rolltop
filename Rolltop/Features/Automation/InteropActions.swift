import AppKit
import Foundation
import RolltopCore

/// A menu bar item as Shortcuts and AppleScript see it.
struct InteropItem: Equatable, Sendable {
    let owner: OwnerID
    let name: String
    let bundleID: String?
    let section: RolltopCore.Section
    /// Drawn in the menu bar right now.
    let isVisible: Bool
}

enum InteropActionError: LocalizedError, Equatable {
    case notRunning
    case accessibilityMissing
    case unknownProfile(String)
    case noProfiles
    case unknownItem(String)
    case notAllowed(String)
    case unknownCommand(String)
    case invalidArgument(String)

    var errorDescription: String? {
        switch self {
        case .notRunning:
            String(localized: "Rolltop is not running. Open Rolltop and try again.", table: "Automation")
        case .accessibilityMissing:
            String(localized: "Rolltop can’t manage menu bar items yet. Allow Rolltop in System Settings › Privacy & Security › Device Control and Data Access, then try again.",
                   table: "Automation")
        case .unknownProfile(let name):
            String(localized: "There is no profile named “\(name)”.", table: "Automation")
        case .noProfiles:
            String(localized: "There are no profiles. Save one in Rolltop’s settings first.", table: "Automation")
        case .unknownItem(let name):
            String(localized: "There is no menu bar item “\(name)”.", table: "Automation")
        case .notAllowed(let id):
            String(localized: "“\(id)” can only be run inside Rolltop.", table: "Automation")
        case .unknownCommand(let id):
            String(localized: "Rolltop has no command “\(id)”.", table: "Automation")
        case .invalidArgument(let text):
            String(localized: "“\(text)” is not an argument. Write arguments as name=value.", table: "Automation")
        }
    }
}

/// What App Intents and AppleScript commands do, in one place, on the running app's
/// context (`AppContext.current`). Visibility goes through the commands, so the reveal
/// router (inline or Rolltop Bar) applies as it does for every other trigger.
///
/// Tests replace the seams that would touch the live Mac (Accessibility, the catalog's
/// reads, pressing an item) through `testSeams`.
final class InteropActions {
    struct Seams {
        var isAccessibilityTrusted: (AppContext) -> Bool = { $0.permissions.accessibility }
        var catalogEntries: (AppContext) -> [CatalogEntry] = { $0.catalog.entries }
        var activate: (AppContext, OwnerID, ItemActivator.Button) async throws -> Void = { context, owner, button in
            _ = try await context.activator.activate(owner, button: button, index: 0)
        }
    }

    /// Unit tests only; nil in the app.
    static var testSeams: Seams?
    /// Unit tests only: a context to use instead of `AppContext.current`.
    static var testContext: AppContext?

    let context: AppContext
    let source: CommandSource
    private let seams: Seams

    init(context: AppContext, source: CommandSource, seams: Seams = Seams()) {
        self.context = context
        self.source = source
        self.seams = seams
    }

    /// The running app's actions, or `notRunning`.
    static func current(source: CommandSource) throws -> InteropActions {
        guard let context = testContext ?? AppContext.current else { throw InteropActionError.notRunning }
        return InteropActions(context: context, source: source, seams: testSeams ?? Seams())
    }

    private func requireAccessibility() throws {
        guard seams.isAccessibilityTrusted(context) else { throw InteropActionError.accessibilityMissing }
    }

    // MARK: Visibility

    /// Shortcuts and scripts have no pointer gesture: a panel opens below Rolltop's item.
    private static let anchor = ["anchor": RevealAnchorArgument.statusItem]

    func showHidden() async throws {
        try requireAccessibility()
        try await context.commands.run(.showHidden, arguments: Self.anchor, source: source)
    }

    func hideHidden() async throws {
        try requireAccessibility()
        try await context.commands.run(.collapse, source: source)
    }

    func toggleHidden() async throws {
        try requireAccessibility()
        try await context.commands.run(.toggleHidden, arguments: Self.anchor, source: source)
    }

    func showAll() async throws {
        try requireAccessibility()
        try await context.commands.run(.showAll, source: source)
    }

    /// Whether hidden items are presented now (inline or in the Rolltop Bar).
    var isHiddenPresented: Bool { context.services[.revealRouting].isHiddenPresented }

    // MARK: Profiles

    var profiles: [ProfileSummary] { context.services[.profiles].profiles }

    var activeProfile: ProfileSummary? {
        let profiles = context.services[.profiles]
        return profiles.activeProfileID.flatMap { id in profiles.profiles.first { $0.id == id } }
    }

    /// By id, else by name (case-insensitive).
    func profile(named nameOrID: String) throws -> ProfileSummary {
        let all = profiles
        guard !all.isEmpty else { throw InteropActionError.noProfiles }
        if let match = all.first(where: { $0.id == nameOrID }) { return match }
        if let match = all.first(where: { $0.name.compare(nameOrID, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
            return match
        }
        throw InteropActionError.unknownProfile(nameOrID)
    }

    @discardableResult
    func applyProfile(_ nameOrID: String) async throws -> ProfileSummary {
        let profile = try profile(named: nameOrID)
        try await context.commands.run("profiles.apply", arguments: ["id": profile.id], source: source)
        return profile
    }

    // MARK: Items

    /// Assignable items (apps and system modules), left to right; Rolltop's own excluded.
    func items() throws -> [InteropItem] {
        try requireAccessibility()
        return seams.catalogEntries(context).compactMap { entry in
            guard let owner = entry.owner, !entry.isOwn else { return nil }
            let bundleID: String? = if case .app(let id) = owner { id } else { nil }
            return InteropItem(owner: owner, name: entry.displayName, bundleID: bundleID,
                               section: entry.section ?? context.layout.section(for: owner),
                               isVisible: entry.isDrawn && !entry.isOverflowed)
        }
    }

    /// By owner string (`com.foo.bar`, `system:wifi`), else by name (case-insensitive).
    func item(_ reference: String) throws -> InteropItem {
        let all = try items()
        if let owner = OwnerID(stringValue: reference), let match = all.first(where: { $0.owner == owner }) { return match }
        if let match = all.first(where: { $0.name.compare(reference, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
            return match
        }
        throw InteropActionError.unknownItem(reference)
    }

    func openItem(_ reference: String, button: ItemActivator.Button) async throws {
        let item = try item(reference)
        try await seams.activate(context, item.owner, button)
    }

    /// nil: follow the section for new items.
    func setSection(_ section: RolltopCore.Section?, of reference: String) async throws {
        let item = try item(reference)
        try await context.commands.run(.setSection, arguments: ["owner": item.owner.stringValue,
                                                                "section": section?.rawValue ?? "default"], source: source)
    }

    // MARK: Commands

    /// Runs any command a link could run with every link option on: commands that only
    /// change what is shown or change settings (`Command.effect`), never destructive ones
    /// (delete, reset, import, files, scripts) and never Debug commands.
    func runCommand(_ id: String, arguments: [String: String]) async throws {
        let commandID = CommandID(id)
        guard let command = context.commands.command(commandID) else { throw InteropActionError.unknownCommand(id) }
        guard Self.mayRunGenerically(command) else { throw InteropActionError.notAllowed(id) }
        try await context.commands.run(commandID, arguments: arguments, source: source)
    }

    /// The generic "run command" of Shortcuts and AppleScript: declared display or
    /// settings commands only.
    static func mayRunGenerically(_ command: Command) -> Bool {
        !command.id.isDebugOnly && command.resolvedEffect != .destructive
    }

    /// `["owner=com.foo", "button=right"]` → dictionary.
    nonisolated static func arguments(from pairs: [String]) throws -> [String: String] {
        var result: [String: String] = [:]
        for pair in pairs where !pair.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let equals = pair.firstIndex(of: "="), equals != pair.startIndex else { throw InteropActionError.invalidArgument(pair) }
            result[pair[..<equals].trimmingCharacters(in: .whitespaces)] = String(pair[pair.index(after: equals)...])
        }
        return result
    }

    // MARK: Focus filter

    /// Focus on with a profile: remember what to put back (once per Focus session), apply.
    /// Focus off (nil): put back the profile that was active before, else the layout.
    func focusChanged(profileID: String?) async throws {
        // First: the Focus is on even when its profile was deleted since.
        (context.services[.focusState] as? InteropFocusState)?.filterRan(profileID: profileID)
        let settings = context.settings
        if let profileID {
            let profile = try profile(named: profileID)
            if settings[InteropSettings.focusRestore] == nil {
                settings[InteropSettings.focusRestore] = InteropFocusRestoreState(
                    appliedProfileID: profile.id, previousProfileID: context.services[.profiles].activeProfileID,
                    previousLayout: context.layout.layout)
            }
            try await context.commands.run("profiles.apply", arguments: ["id": profile.id], source: source)
        } else if let restore = settings[InteropSettings.focusRestore] {
            settings[InteropSettings.focusRestore] = nil
            if let previous = restore.previousProfileID, profiles.contains(where: { $0.id == previous }) {
                try await context.commands.run("profiles.apply", arguments: ["id": previous], source: source)
            } else {
                context.services[.profileLayoutRestorer].restoreLayout(restore.previousLayout, activeProfileID: nil)
            }
        }
    }
}
