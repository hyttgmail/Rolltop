import Foundation
import RolltopCore

/// What a `rolltop://` link asks for.
nonisolated enum InteropLinkTarget: Equatable, Sendable {
    /// A command with arguments (`rolltop://command/<id>` or an alias).
    case command(CommandID, [String: String])
    /// `rolltop://search` before the command palette registered an opening command.
    case unavailable(String)
    /// A host registered by another feature through `context.urlRoutes`.
    case route(String)
    case invalid
}

/// The human-friendly aliases and how each maps to a command. Registered through
/// `context.urlRoutes` so the core router (which serves links that arrive before Rolltop's
/// features start) resolves them too.
nonisolated enum InteropLinkRoutes {
    static let aliasHosts = ["show", "show-all", "hide", "toggle", "profile", "item", "search", "settings"]

    /// Parses any `rolltop://` link. `paletteCommand` resolves `rolltop://search` at run time
    /// (the palette is another feature); `routeHosts` are hosts other features registered.
    static func target(of url: URL, paletteCommand: CommandID?, routeHosts: Set<String> = []) -> InteropLinkTarget {
        guard url.scheme?.lowercased() == "rolltop", let host = url.host()?.lowercased(), !host.isEmpty else { return .invalid }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let parts = url.pathComponents.filter { $0 != "/" }
        switch host {
        case "command":
            guard parts.count == 1, let id = parts.first, !id.isEmpty else { return .invalid }
            return .command(CommandID(id), query)
        case "show":
            return parts.isEmpty ? .command(.showHidden, query) : .invalid
        case "show-all":
            return parts.isEmpty ? .command(.showAll, [:]) : .invalid
        case "hide":
            return parts.isEmpty ? .command(.collapse, [:]) : .invalid
        case "toggle":
            return parts.isEmpty ? .command(.toggleHidden, query) : .invalid
        case "profile":
            guard parts.count == 1, let id = parts.first, !id.isEmpty else { return .invalid }
            return .command("profiles.apply", ["id": id])
        case "item":
            guard parts.count == 1, let owner = parts.first, OwnerID(stringValue: owner) != nil else { return .invalid }
            var arguments = ["owner": owner]
            if let button = query["button"], !button.isEmpty { arguments["button"] = button }
            if let index = query["index"], !index.isEmpty { arguments["index"] = index }
            return .command(.activateItem, arguments)
        case "search":
            guard parts.isEmpty else { return .invalid }
            guard let paletteCommand else { return .unavailable("search") }
            return .command(paletteCommand, query)
        case "settings":
            guard parts.count <= 1 else { return .invalid }
            return .command(.openSettings, parts.first.map { ["pane": $0] } ?? [:])
        default:
            return routeHosts.contains(host) ? .route(host) : .invalid
        }
    }

    /// The command `rolltop://search` runs: the command palette's `show` (by id, as every
    /// link names commands). Nil while no feature registered it.
    static let searchCommand: CommandID = "palette.show"

    static func paletteCommand(in ids: [CommandID]) -> CommandID? {
        ids.contains(searchCommand) ? searchCommand : nil
    }
}

/// One row of the link catalogue in the Integrations pane.
nonisolated struct InteropLinkExample: Identifiable, Hashable, Sendable {
    /// The link with placeholders (`rolltop://profile/<id>`).
    let template: String
    /// A ready link to copy (placeholders filled with a real value when one exists).
    let example: String
    let summary: String
    let parameters: String?

    var id: String { template }
}
