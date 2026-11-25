import AppKit
import RolltopCore

/// One row of the palette, ready to draw and run.
struct PaletteRow: Identifiable {
    enum Action {
        /// Show the item and click it (`context.activator`).
        case item(OwnerID, index: Int)
        case profile(id: String)
        case command(PaletteCommandInvocation)
        case settings(paneID: String)
        case provided(@MainActor () async throws -> Void)
    }

    enum Icon {
        case image(NSImage)
        case symbol(String)
    }

    /// Usage key; unique among the rows.
    let id: String
    let kind: PaletteCandidate.Kind
    let title: String
    var subtitle: String?
    /// Where an item lives, "Active" for the active profile, a provider's name.
    var tag: String?
    var icon: Icon?
    /// Active profile, a command that is on.
    var isOn = false
    let action: Action
    /// Matched besides the title (bundle id, profile name, pane keywords).
    var alternates: [String] = []
    var emptyQueryOrder: Int?
    /// A provider row's ⌘Return action (`PaletteProvidedResult.alternateAction`), nil for none.
    var secondAction: PaletteAlternateAction?

    var candidate: PaletteCandidate {
        // Providers' subtitles carry content worth matching; ours are positions ("Item 2 of 3").
        let matchedSubtitle = kind == .provided ? subtitle.map { [$0] } ?? [] : []
        return PaletteCandidate(key: id, kind: kind, title: title, alternates: alternates + matchedSubtitle,
                                emptyQueryOrder: emptyQueryOrder)
    }

    var isItem: Bool { if case .item = action { true } else { false } }
}

/// Builds every row from the app's registries and services. Resolves services at call time.
final class PaletteRowSource {
    /// Height of item images in rows.
    static let imageHeight: CGFloat = 20
    /// Most rows per owner (an app with several items gets one row each).
    static let maxItemsPerOwner = 8

    private unowned let context: AppContext

    init(context: AppContext) {
        self.context = context
    }

    func rows() -> [PaletteRow] {
        let settings = context.settings
        var rows: [PaletteRow] = []
        if settings[PaletteSettings.includeItems] { rows += itemRows() }
        if settings[PaletteSettings.includeProfiles] { rows += profileRows() }
        if settings[PaletteSettings.includeCommands] { rows += commandRows() }
        if settings[PaletteSettings.includeSettings] { rows += settingsRows() }
        // Keys must be unique: the first row with a key wins.
        var seen = Set<String>()
        return rows.filter { seen.insert($0.id).inserted }
    }

    /// Rows of other features' providers for this query (rebuilt on every keystroke).
    func providedRows(for query: String) -> [PaletteRow] {
        let disabled = Set(context.settings[PaletteSettings.disabledProviders])
        var rows: [PaletteRow] = []
        for provider in context.services[.paletteResultProviders].providers where !disabled.contains(provider.id) {
            for result in provider.results(for: query).prefix(50) {
                let icon: PaletteRow.Icon? = switch result.icon {
                case .symbol(let name)?: .symbol(name)
                case .image(let image)?: .image(image)
                case nil: nil
                }
                rows.append(PaletteRow(id: "provider:\(provider.id):\(result.id)", kind: .provided, title: result.title,
                                       subtitle: result.subtitle, tag: provider.title, icon: icon,
                                       action: .provided(result.action), alternates: result.keywords,
                                       secondAction: result.alternateAction))
            }
        }
        return rows
    }

    // MARK: Items

    func itemRows() -> [PaletteRow] {
        let images = context.services[.itemImages]
        var rows: [PaletteRow] = []
        var hiddenOrder = 0
        let entries = context.catalog.entries
        // Hidden first, then always hidden, each in bar order (left to right).
        let order: [Section: Int] = [.hidden: 0, .alwaysHidden: 1000]
        for entry in entries {
            guard let owner = entry.owner, !entry.isOwn else { continue }
            let name = context.catalog.displayName(for: owner)
            let count = min(Self.maxItemsPerOwner, max(1, entry.itemCount))
            for index in 0..<count {
                var row = PaletteRow(id: Self.itemKey(owner, index: index), kind: .item, title: name,
                                     action: .item(owner, index: index))
                if count > 1 {
                    row.subtitle = String(localized: "Item \(index + 1) of \(count)", table: "CommandPalette")
                }
                row.tag = Self.tag(for: entry)
                row.icon = images.image(for: owner, itemIndex: index, height: Self.imageHeight).map(PaletteRow.Icon.image)
                    ?? .symbol("questionmark.app.dashed")
                row.alternates = Self.alternates(for: owner)
                if let section = entry.section, let base = order[section] {
                    row.emptyQueryOrder = base + hiddenOrder
                    hiddenOrder += 1
                }
                rows.append(row)
            }
        }
        return rows
    }

    static func itemKey(_ owner: OwnerID, index: Int) -> String {
        index == 0 ? "item:\(owner.stringValue)" : "item:\(owner.stringValue)#\(index)"
    }

    /// Where the item lives: its section when not shown, else whether macOS draws it.
    static func tag(for entry: CatalogEntry) -> String? {
        switch entry.section {
        case .hidden?: return String(localized: "Hidden", table: "CommandPalette")
        case .alwaysHidden?: return String(localized: "Always hidden", table: "CommandPalette")
        case .shown?, nil: break
        }
        if entry.isOverflowed { return String(localized: "Overflowed", table: "CommandPalette") }
        if !entry.isDrawn { return String(localized: "Not drawn", table: "CommandPalette") }
        return nil
    }

    static func alternates(for owner: OwnerID) -> [String] {
        switch owner {
        case .app(let bundleID): [bundleID]
        case .system(let module): [module.axIdentifier]
        }
    }

    // MARK: Profiles

    func profileRows() -> [PaletteRow] {
        let profiles = context.services[.profiles]
        let active = profiles.activeProfileID
        return profiles.profiles.map { profile in
            var row = PaletteRow(id: "profile:\(profile.id)", kind: .profile,
                                 title: String(localized: "Apply profile \(profile.name)", table: "CommandPalette"),
                                 action: .profile(id: profile.id))
            row.icon = .symbol(profile.symbol ?? "rectangle.stack")
            row.isOn = profile.id == active
            if row.isOn { row.tag = String(localized: "Active", table: "CommandPalette") }
            row.alternates = [profile.name]
            return row
        }
    }

    // MARK: Commands

    func commandRows() -> [PaletteRow] {
        var rows: [PaletteRow] = []
        for command in context.commands.commands {
            let descriptor = PaletteCommandDescriptor(
                id: command.id,
                arguments: command.arguments.map { .init(name: $0.name, isRequired: $0.isRequired, allowedValues: $0.allowedValues) },
                isAvailable: command.isAvailable?() ?? true)
            let invocations = PaletteCommandExpansion.invocations(for: descriptor)
            guard !invocations.isEmpty else { continue }
            let title = command.localizedTitle
            let isOn = command.isOn?() ?? false
            for invocation in invocations {
                let values = invocation.orderedValues.map { valueTitle(argument: $0.name, value: $0.value) }
                let rowTitle = values.isEmpty ? title
                    : String(localized: "\(title): \(values.joined(separator: ", "))", table: "CommandPalette",
                             comment: "Command row with argument values: “Set Section for New Items: Hidden”")
                var row = PaletteRow(id: invocation.key, kind: .command, title: rowTitle, action: .command(invocation))
                row.icon = .symbol(command.symbol)
                row.isOn = values.isEmpty && isOn
                if row.isOn { row.tag = String(localized: "On", table: "CommandPalette") }
                rows.append(row)
            }
        }
        return rows
    }

    /// A readable name for an argument value: a profile's or pane's name, an item's name, a
    /// section, else the raw value made readable. `CommandArgument` carries no per-value titles.
    func valueTitle(argument: String, value: String) -> String {
        if let profile = context.services[.profiles].profiles.first(where: { $0.id == value }) { return profile.name }
        if let pane = context.settingsPanes.pane(value) { return String(localized: pane.title) }
        if let section = Section(rawValue: value) {
            switch section {
            case .shown: return String(localized: "Shown", table: "CommandPalette")
            case .hidden: return String(localized: "Hidden", table: "CommandPalette")
            case .alwaysHidden: return String(localized: "Always hidden", table: "CommandPalette")
            }
        }
        if value.contains("."), let owner = OwnerID(stringValue: value) { return context.catalog.displayName(for: owner) }
        return PaletteCommandExpansion.humanize(value)
    }

    // MARK: Settings panes

    func settingsRows() -> [PaletteRow] {
        context.settingsPanes.panes.map { pane in
            let name = String(localized: pane.title)
            var row = PaletteRow(id: "settings:\(pane.id)", kind: .setting,
                                 title: String(localized: "Open \(name) settings", table: "CommandPalette"),
                                 action: .settings(paneID: pane.id))
            row.icon = .symbol(pane.symbol)
            let keywords = context.settingsPanes.keywords(for: pane.id)
                .flatMap { String(localized: $0).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
            row.alternates = [name] + keywords
            return row
        }
    }
}
