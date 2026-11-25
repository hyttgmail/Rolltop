import Foundation
import RolltopCore

/// Extra `rolltop://<host>/…` routes contributed by features (the core owns `command`).
final class URLRouteRegistry {
    private(set) var handlers: [String: (URL) -> Void] = [:]

    /// Registers the handler for `rolltop://<host>/…`. Hosts are lowercase; `command` is reserved.
    func register(host: String, handler: @escaping (URL) -> Void) {
        let key = host.lowercased()
        precondition(key != URLRouter.commandHost, "the command host belongs to the core")
        handlers[key] = handler
    }
}

/// Parses `rolltop://command/<id>?key=value&…`. Links are decided and run by the link gate
/// (`services[.linkGate]`, App/Contracts/Links.swift).
enum URLRouter {
    nonisolated static let commandHost = "command"

    nonisolated static func parse(_ url: URL) -> (command: CommandID, arguments: [String: String])? {
        guard url.scheme?.lowercased() == "rolltop", url.host?.lowercased() == commandHost,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 1, let id = parts.first, !id.isEmpty else { return nil }
        var arguments: [String: String] = [:]
        for item in components.queryItems ?? [] {
            arguments[item.name] = item.value ?? ""
        }
        return (CommandID(id), arguments)
    }
}
