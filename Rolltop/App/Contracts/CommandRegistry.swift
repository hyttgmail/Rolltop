import Foundation
import Observation
import RolltopCore

/// Where a command invocation came from.
nonisolated enum CommandSource: String, Sendable {
    case statusMenu = "status-menu"
    case url
    case hotkey
    case palette
    case shortcuts
    case appleScript = "applescript"
    case automation
    /// A custom item's click action (a widget that runs a command).
    case customItem = "custom-item"
    case `internal`
}

/// What running a command can change. Every feature declares it on its commands
/// (`Command.effect`); links, the generic "Run Rolltop Command" of Shortcuts and AppleScript,
/// automations, custom items and the palette decide by it, never by the command's id.
nonisolated enum CommandEffect: String, Sendable, CaseIterable, Comparable {
    /// Only changes what is shown, and only until it is shown differently: reveal and hide
    /// items, open an item, a panel or a settings pane, apply a profile, quit Rolltop.
    case display
    /// Changes settings or other lasting state that the user can change back (sections,
    /// styles, pausing automations, turning a custom item off).
    case changesSettings = "changes-settings"
    /// Deletes, resets, imports, writes files, or can start scripts (turning automations
    /// back on runs approved script conditions). Runs only from Rolltop's own menus, shortcuts
    /// the user bound and the palette (after a confirmation step); never from a source that
    /// another app, a web page or an imported rule or widget controls.
    case destructive

    static func < (lhs: Self, rhs: Self) -> Bool { allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)! }
}

/// Which sources may run which effects. Pure, so every consumer agrees.
nonisolated enum CommandEffectPolicy {
    /// Sources another app, a web page, a script, or data that arrived through an import
    /// (automation rules, custom items) control. They never run destructive commands.
    static let externalSources: Set<CommandSource> = [.url, .shortcuts, .appleScript, .automation, .customItem]

    /// Whether `source` may run a command with this effect at all. Debug commands
    /// (`CommandID.isDebugOnly`) are not decided here: they exist only in Debug builds.
    static func allows(_ effect: CommandEffect, from source: CommandSource) -> Bool {
        effect != .destructive || !externalSources.contains(source)
    }
}

/// A named argument a command accepts. All arguments are strings (URL query items,
/// Shortcuts parameters, AppleScript parameters).
struct CommandArgument: Sendable {
    let name: String
    let title: LocalizedStringResource
    var isRequired = true
    /// When set, the only accepted values (shown by the palette / Shortcuts).
    var allowedValues: [String]?
}

/// One invocation: arguments and source.
struct CommandInvocation: Sendable {
    var arguments: [String: String] = [:]
    var source: CommandSource = .internal

    func string(_ name: String) -> String? { arguments[name] }

    func require(_ name: String) throws -> String {
        guard let value = arguments[name], !value.isEmpty else { throw CommandError.missingArgument(name) }
        return value
    }

    func owner(_ name: String = "owner") throws -> OwnerID {
        let raw = try require(name)
        guard let owner = OwnerID(stringValue: raw) else { throw CommandError.invalidArgument(name, raw) }
        return owner
    }
}

enum CommandError: LocalizedError, Equatable {
    case unknownCommand(CommandID)
    case notAllowed(CommandID, CommandSource)
    case unavailable(CommandID)
    case missingArgument(String)
    case invalidArgument(String, String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unknownCommand(let id): String(localized: "Unknown command “\(id.rawValue)”.")
        case .notAllowed(let id, let source): String(localized: "The command “\(id.rawValue)” can’t be run from \(source.rawValue).")
        case .unavailable(let id): String(localized: "The command “\(id.rawValue)” isn’t available right now.")
        case .missingArgument(let name): String(localized: "The argument “\(name)” is missing.")
        case .invalidArgument(let name, let value): String(localized: "“\(value)” isn’t a valid value for “\(name)”.")
        case .failed(let reason): reason
        }
    }
}

/// A command: data plus a handler. Hotkeys, the palette, URLs, Shortcuts and the status
/// menu all run commands by id through `CommandRegistry`.
struct Command {
    let id: CommandID
    let title: LocalizedStringResource
    /// SF Symbol name.
    let symbol: String
    var arguments: [CommandArgument] = []
    /// Declared only; the Hotkeys feature binds it.
    var defaultShortcut: KeyCombo?
    var showInStatusMenu = false
    /// The status menu shows `symbol` next to the title. Only for commands that identify an
    /// object (a profile, an item, a device), per DESIGN.md's menu rule; contributed
    /// commands are grouped by feature, so a group is all icons or none.
    var showsSymbolInMenu = false
    var allowedFromURL = false
    /// What running it can change. Nil (undeclared) counts as `.destructive`: a command
    /// whose author forgot to declare it is refused wherever destructive commands are.
    /// Every feature declares it on every non-Debug command (checked by a unit test).
    var effect: CommandEffect?
    /// Checkmark state in menus, when the command toggles something.
    var isOn: (() -> Bool)?
    /// Hidden from menus and the palette and refused while false.
    var isAvailable: (() -> Bool)?
    let perform: (CommandInvocation) async throws -> Void

    var localizedTitle: String { String(localized: title) }

    /// `effect`, with undeclared counted as destructive.
    var resolvedEffect: CommandEffect { effect ?? .destructive }

    /// The feature id part of `id` (`profiles` for `profiles.apply-1`).
    var featurePrefix: Substring { id.rawValue.prefix { $0 != "." } }
}

@Observable
final class CommandRegistry {
    /// In registration order.
    private(set) var commands: [Command] = []
    @ObservationIgnored private let log = Log.logger("commands")

    /// Registers or replaces a command with the same id.
    func register(_ command: Command) {
        if !command.id.isWellFormed { log.error("malformed command id \(command.id)") }
        if let index = commands.firstIndex(where: { $0.id == command.id }) {
            log.notice("replacing command \(command.id)")
            commands[index] = command
        } else {
            commands.append(command)
        }
    }

    func register(_ commands: [Command]) { commands.forEach(register) }

    func unregister(_ id: CommandID) {
        commands.removeAll { $0.id == id }
    }

    func command(_ id: CommandID) -> Command? {
        commands.first { $0.id == id }
    }

    var statusMenuCommands: [Command] {
        commands.filter { $0.showInStatusMenu && ($0.isAvailable?() ?? true) }
    }

    /// Runs a command by id. Checks the source and the required arguments first.
    func run(_ id: CommandID, arguments: [String: String] = [:], source: CommandSource = .internal) async throws {
        guard let command = command(id) else { throw CommandError.unknownCommand(id) }
        if source == .url, !command.allowedFromURL { throw CommandError.notAllowed(id, source) }
        if !id.isDebugOnly, !CommandEffectPolicy.allows(command.resolvedEffect, from: source) {
            throw CommandError.notAllowed(id, source)
        }
        if let isAvailable = command.isAvailable, !isAvailable() { throw CommandError.unavailable(id) }
        for argument in command.arguments where argument.isRequired {
            guard let value = arguments[argument.name], !value.isEmpty else { throw CommandError.missingArgument(argument.name) }
            if let allowed = argument.allowedValues, !allowed.contains(value) {
                throw CommandError.invalidArgument(argument.name, value)
            }
        }
        log.info("run \(id) from \(source.rawValue) \(arguments.isEmpty ? "" : arguments.description)")
        try await command.perform(CommandInvocation(arguments: arguments, source: source))
    }

    /// Fire-and-forget variant for menus and other synchronous callers; errors are logged.
    func runDetached(_ id: CommandID, arguments: [String: String] = [:], source: CommandSource) {
        Task {
            do { try await run(id, arguments: arguments, source: source) } catch {
                log.error("\(id) failed: \(error.localizedDescription)")
            }
        }
    }
}
