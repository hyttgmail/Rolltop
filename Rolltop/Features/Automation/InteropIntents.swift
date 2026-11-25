import AppIntents
import Foundation
import RolltopCore

// Shortcuts actions. They run inside the running Rolltop (`allowedExecutionTargets = .main`,
// background mode: no window comes forward) and go through `InteropActions`, which throws
// a readable error when Rolltop is not running or Accessibility is missing.

// MARK: - Entities

struct InteropProfileEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: LocalizedStringResource("Rolltop Profile", table: "Automation"))
    static let defaultQuery = InteropProfileQuery()

    let id: String
    @Property(title: LocalizedStringResource("Name", table: "Automation"))
    var name: String
    var symbol: String

    init(id: String, name: String, symbol: String) {
        self.id = id
        self.symbol = symbol
        self.name = name
    }

    init(_ summary: ProfileSummary) {
        self.init(id: summary.id, name: summary.name, symbol: summary.symbol ?? "square.stack.3d.up")
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: symbol))
    }
}

struct InteropProfileQuery: EntityStringQuery {
    static let allowedExecutionTargets: IntentExecutionTargets = .main

    @MainActor
    func entities(for identifiers: [String]) async throws -> [InteropProfileEntity] {
        let profiles = try InteropActions.current(source: .shortcuts).profiles
        return identifiers.compactMap { id in profiles.first { $0.id == id }.map(InteropProfileEntity.init) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [InteropProfileEntity] {
        try InteropActions.current(source: .shortcuts).profiles
            .filter { $0.name.localizedStandardContains(string) || $0.id.contains(string.lowercased()) }
            .map(InteropProfileEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [InteropProfileEntity] {
        try InteropActions.current(source: .shortcuts).profiles.map(InteropProfileEntity.init)
    }
}

nonisolated enum InteropSectionAppEnum: String, AppEnum {
    case shown
    case hidden
    case alwaysHidden = "always-hidden"

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: LocalizedStringResource("Section", table: "Automation"))
    static let caseDisplayRepresentations: [InteropSectionAppEnum: DisplayRepresentation] = [
        .shown: DisplayRepresentation(title: LocalizedStringResource("Shown", table: "Automation")),
        .hidden: DisplayRepresentation(title: LocalizedStringResource("Hidden", table: "Automation")),
        .alwaysHidden: DisplayRepresentation(title: LocalizedStringResource("Always Hidden", table: "Automation")),
    ]

    init(_ section: RolltopCore.Section) {
        switch section {
        case .shown: self = .shown
        case .hidden: self = .hidden
        case .alwaysHidden: self = .alwaysHidden
        }
    }

    var section: RolltopCore.Section {
        switch self {
        case .shown: .shown
        case .hidden: .hidden
        case .alwaysHidden: .alwaysHidden
        }
    }
}

nonisolated enum InteropClickAppEnum: String, AppEnum {
    case left
    case right

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: LocalizedStringResource("Click", table: "Automation"))
    static let caseDisplayRepresentations: [InteropClickAppEnum: DisplayRepresentation] = [
        .left: DisplayRepresentation(title: LocalizedStringResource("Click", table: "Automation")),
        .right: DisplayRepresentation(title: LocalizedStringResource("Right-click", table: "Automation")),
    ]
}

struct InteropMenuBarItemEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: LocalizedStringResource("Menu Bar Item", table: "Automation"))
    static let defaultQuery = InteropMenuBarItemQuery()

    /// The owner: a bundle id or `system:<module>`.
    let id: String
    @Property(title: LocalizedStringResource("Name", table: "Automation"))
    var name: String
    @Property(title: LocalizedStringResource("Bundle Identifier", table: "Automation"))
    var bundleIdentifier: String?
    @Property(title: LocalizedStringResource("Section", table: "Automation"))
    var section: InteropSectionAppEnum
    @Property(title: LocalizedStringResource("Visible", table: "Automation"))
    var isVisible: Bool

    init(_ item: InteropItem) {
        id = item.owner.stringValue
        name = item.name
        bundleIdentifier = item.bundleID
        section = InteropSectionAppEnum(item.section)
        isVisible = item.isVisible
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(id)")
    }
}

struct InteropMenuBarItemQuery: EntityStringQuery {
    static let allowedExecutionTargets: IntentExecutionTargets = .main

    @MainActor
    func entities(for identifiers: [String]) async throws -> [InteropMenuBarItemEntity] {
        let items = try InteropActions.current(source: .shortcuts).items()
        return identifiers.compactMap { id in items.first { $0.owner.stringValue == id }.map(InteropMenuBarItemEntity.init) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [InteropMenuBarItemEntity] {
        try InteropActions.current(source: .shortcuts).items()
            .filter { $0.name.localizedStandardContains(string) || $0.owner.stringValue.localizedStandardContains(string) }
            .map(InteropMenuBarItemEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [InteropMenuBarItemEntity] {
        try InteropActions.current(source: .shortcuts).items().map(InteropMenuBarItemEntity.init)
    }
}

// MARK: - Visibility

struct InteropShowHiddenIntent: AppIntent {
    static let title = LocalizedStringResource("Show Hidden Items", table: "Automation")
    static let description = IntentDescription(LocalizedStringResource("Shows the items in Rolltop’s Hidden section.", table: "Automation"))
    static let supportedModes: IntentModes = .background
    static let allowedExecutionTargets: IntentExecutionTargets = .main

    @MainActor
    func perform() async throws -> some IntentResult {
        try await InteropActions.current(source: .shortcuts).showHidden()
        return .result()
    }
}

struct InteropHideHiddenIntent: AppIntent {
    static let title = LocalizedStringResource("Hide Hidden Items", table: "Automation")
    static let description = IntentDescription(LocalizedStringResource("Hides the items in Rolltop’s Hidden section again.", table: "Automation"))
    static let supportedModes: IntentModes = .background
    static let allowedExecutionTargets: IntentExecutionTargets = .main

    @MainActor
    func perform() async throws -> some IntentResult {
        try await InteropActions.current(source: .shortcuts).hideHidden()
        return .result()
    }
}

struct InteropToggleHiddenIntent: AppIntent {
    static let title = LocalizedStringResource("Toggle Hidden Items", table: "Automation")
    static let description = IntentDescription(LocalizedStringResource("Shows the hidden items, or hides them when they are showing. Returns whether they are showing now.",
                                                                       table: "Automation"))
    static let supportedModes: IntentModes = .background
    static let allowedExecutionTargets: IntentExecutionTargets = .main

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let actions = try InteropActions.current(source: .shortcuts)
        let wasShowing = actions.isHiddenPresented
        try await actions.toggleHidden()
        return .result(value: !wasShowing)
    }
}

struct InteropShowAllIntent: AppIntent {
    static let title = LocalizedStringResource("Show All Items", table: "Automation")
    static let description = IntentDescription(LocalizedStringResource("Shows every menu bar item, including the always-hidden ones.", table: "Automation"))
    static let supportedModes: IntentModes = .background
    static let allowedExecutionTargets: IntentExecutionTargets = .main

    @MainActor
    func perform() async throws -> some IntentResult {
        try await InteropActions.current(source: .shortcuts).showAll()
        return .result()
    }
}

// MARK: - Profiles

struct InteropApplyProfileIntent: AppIntent {
    static let title = LocalizedStringResource("Apply Profile", table: "Automation")
    static let description = IntentDescription(LocalizedStringResource("Applies a Rolltop profile: every item moves to the section the profile remembers.",
                                                                       table: "Automation"))
    static let supportedModes: IntentModes = .background
    static let allowedExecutionTargets: IntentExecutionTargets = .main

    @Parameter(title: LocalizedStringResource("Profile", table: "Automation"))
    var profile: InteropProfileEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Apply \(\.$profile)", table: "Automation")
    }

    init() {}

    init(profile: InteropProfileEntity) { self.profile = profile }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<InteropProfileEntity> {
        let applied = try await InteropActions.current(source: .shortcuts).applyProfile(profile.id)
        return .result(value: InteropProfileEntity(applied))
    }
}

struct InteropGetCurrentProfileIntent: AppIntent {
    static let title = LocalizedStringResource("Get Current Profile", table: "Automation")
    static let description = IntentDescription(LocalizedStringResource("Returns the profile applied last, or nothing when the menu bar follows no profile.",
                                                                       table: "Automation"))
    static let supportedModes: IntentModes = .background
    static let allowedExecutionTargets: IntentExecutionTargets = .main

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<InteropProfileEntity?> {
        let active = try InteropActions.current(source: .shortcuts).activeProfile
        return .result(value: active.map(InteropProfileEntity.init))
    }
}

// MARK: - Items

struct InteropOpenItemIntent: AppIntent {
    static let title = LocalizedStringResource("Open Menu Bar Item", table: "Automation")
    static let description = IntentDescription(LocalizedStringResource("Clicks or right-clicks a menu bar item, including a hidden one: Rolltop shows it, opens its menu, and hides it again when the menu closes.",
                                                                       table: "Automation"))
    static let supportedModes: IntentModes = .background
    static let allowedExecutionTargets: IntentExecutionTargets = .main

    @Parameter(title: LocalizedStringResource("Item", table: "Automation"))
    var item: InteropMenuBarItemEntity

    @Parameter(title: LocalizedStringResource("Click", table: "Automation"), default: .left)
    var click: InteropClickAppEnum

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$item) with \(\.$click)", table: "Automation")
    }

    init() {}

    init(item: InteropMenuBarItemEntity, click: InteropClickAppEnum = .left) {
        self.item = item
        self.click = click
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await InteropActions.current(source: .shortcuts).openItem(item.id, button: click == .right ? .right : .left)
        return .result()
    }
}

struct InteropSetSectionIntent: AppIntent {
    static let title = LocalizedStringResource("Set Section of Menu Bar Item", table: "Automation")
    static let description = IntentDescription(LocalizedStringResource("Moves a menu bar item to Shown, Hidden or Always Hidden.", table: "Automation"))
    static let supportedModes: IntentModes = .background
    static let allowedExecutionTargets: IntentExecutionTargets = .main

    @Parameter(title: LocalizedStringResource("Item", table: "Automation"))
    var item: InteropMenuBarItemEntity

    @Parameter(title: LocalizedStringResource("Section", table: "Automation"))
    var section: InteropSectionAppEnum

    static var parameterSummary: some ParameterSummary {
        Summary("Move \(\.$item) to \(\.$section)", table: "Automation")
    }

    init() {}

    init(item: InteropMenuBarItemEntity, section: InteropSectionAppEnum) {
        self.item = item
        self.section = section
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<InteropMenuBarItemEntity> {
        let actions = try InteropActions.current(source: .shortcuts)
        try await actions.setSection(section.section, of: item.id)
        return .result(value: InteropMenuBarItemEntity(try actions.item(item.id)))
    }
}

struct InteropGetItemsIntent: AppIntent {
    static let title = LocalizedStringResource("Get Menu Bar Items", table: "Automation")
    static let description = IntentDescription(LocalizedStringResource("Returns the menu bar items Rolltop manages, with their names, bundle identifiers, sections and whether they are visible.",
                                                                       table: "Automation"))
    static let supportedModes: IntentModes = .background
    static let allowedExecutionTargets: IntentExecutionTargets = .main

    @Parameter(title: LocalizedStringResource("Section", table: "Automation"))
    var section: InteropSectionAppEnum?

    static var parameterSummary: some ParameterSummary {
        Summary("Get menu bar items in \(\.$section)", table: "Automation")
    }

    init() {}

    init(section: InteropSectionAppEnum?) { self.section = section }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[InteropMenuBarItemEntity]> {
        let items = try InteropActions.current(source: .shortcuts).items()
        let filtered = section.map { wanted in items.filter { $0.section == wanted.section } } ?? items
        return .result(value: filtered.map(InteropMenuBarItemEntity.init))
    }
}

// MARK: - Advanced

struct InteropRunCommandIntent: AppIntent {
    static let title = LocalizedStringResource("Run Rolltop Command", table: "Automation")
    static let description = IntentDescription(LocalizedStringResource("Advanced: runs a Rolltop command by its id (as in rolltop://command/<id>) with name=value arguments. Commands that delete, reset, import or turn on scripts cannot be run this way.",
                                                                       table: "Automation"))
    static let supportedModes: IntentModes = .background
    static let allowedExecutionTargets: IntentExecutionTargets = .main

    @Parameter(title: LocalizedStringResource("Command", table: "Automation"),
               inputOptions: String.IntentInputOptions(keyboardType: .default, capitalizationType: .none, autocorrect: false))
    var command: String

    @Parameter(title: LocalizedStringResource("Arguments", table: "Automation"),
               description: LocalizedStringResource("Each argument as name=value, for example owner=com.apple.menuextra.wifi.", table: "Automation"))
    var arguments: [String]?

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$command) with \(\.$arguments)", table: "Automation")
    }

    init() {}

    init(command: String, arguments: [String]? = nil) {
        self.command = command
        self.arguments = arguments
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let actions = try InteropActions.current(source: .shortcuts)
        try await actions.runCommand(command.trimmingCharacters(in: .whitespaces), arguments: try InteropActions.arguments(from: arguments ?? []))
        return .result()
    }
}

// MARK: - Focus filter

/// "Use Rolltop profile": while the Focus is on, its profile is applied. When the Focus ends
/// the system calls `perform()` again with the parameter at its default (nil), and the
/// profile that was active before comes back (else the layout from before).
struct InteropFocusFilter: SetFocusFilterIntent {
    static let title = LocalizedStringResource("Use Rolltop Profile", table: "Automation")
    static let description = IntentDescription(LocalizedStringResource("Applies a Rolltop profile while this Focus is on.", table: "Automation"))
    static let allowedExecutionTargets: IntentExecutionTargets = .main

    @Parameter(title: LocalizedStringResource("Profile", table: "Automation"))
    var profile: InteropProfileEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Use \(\.$profile)", table: "Automation")
    }

    init() {}

    init(profile: InteropProfileEntity?) { self.profile = profile }

    var displayRepresentation: DisplayRepresentation {
        if let profile {
            DisplayRepresentation(title: "\(profile.name)", subtitle: LocalizedStringResource("Rolltop profile", table: "Automation"))
        } else {
            DisplayRepresentation(title: LocalizedStringResource("No profile", table: "Automation"))
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await InteropActions.current(source: .shortcuts).focusChanged(profileID: profile?.id)
        return .result()
    }
}

// MARK: - App Shortcuts

struct InteropShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: InteropToggleHiddenIntent(),
                    phrases: ["Toggle hidden items in \(.applicationName)", "Toggle \(.applicationName)"],
                    shortTitle: LocalizedStringResource("Toggle Hidden Items", table: "Automation"), systemImageName: "eye")
        AppShortcut(intent: InteropShowHiddenIntent(),
                    phrases: ["Show hidden items in \(.applicationName)", "Show my hidden menu bar items with \(.applicationName)"],
                    shortTitle: LocalizedStringResource("Show Hidden Items", table: "Automation"), systemImageName: "eye")
        AppShortcut(intent: InteropHideHiddenIntent(),
                    phrases: ["Hide hidden items in \(.applicationName)", "Tidy the menu bar with \(.applicationName)"],
                    shortTitle: LocalizedStringResource("Hide Hidden Items", table: "Automation"), systemImageName: "eye.slash")
        AppShortcut(intent: InteropApplyProfileIntent(),
                    phrases: ["Apply a \(.applicationName) profile", "Switch \(.applicationName) profile"],
                    shortTitle: LocalizedStringResource("Apply Profile", table: "Automation"), systemImageName: "rectangle.stack")
    }

    static let shortcutTileColor: ShortcutTileColor = .grayBlue
}
