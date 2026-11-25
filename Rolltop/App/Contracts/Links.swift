import AppKit
import Foundation
import RolltopCore

// Every `rolltop://` link goes through one gate (docs/CONTRACTS.md, "Links"). The core owns
// AppKit's `GURL` Apple event handler from `applicationWillFinishLaunching`, so it also
// sees the link that launches Rolltop; it resolves the sender when the event arrives (the
// sending process may be gone a moment later), queues links until every feature has
// started, then hands each to `services[.linkGate]`.

/// Who sent a link, as far as macOS tells.
nonisolated struct LinkSender: Hashable, Sendable, CustomStringConvertible {
    enum Kind: String, Sendable {
        /// An app with a bundle id: decisions are remembered per bundle id.
        case app
        /// A process without an app identity (a command-line tool such as `open`). Its path
        /// is shown, but it counts as unknown: any program can run it.
        case tool
        /// No sender at all (the event carried none, or the process is gone).
        case unknown
        /// Rolltop itself (its own "Test" buttons).
        case rolltop
    }

    var kind: Kind
    var bundleID: String?
    var name: String?
    var path: String?
    var pid: Int32?

    static let unknown = LinkSender(kind: .unknown)

    /// The rate-limit bucket and the key of remembered decisions.
    var key: String {
        switch kind {
        case .app: "app:" + (bundleID ?? "?")
        case .tool: "tool:" + (path ?? "?")
        case .unknown: "unknown"
        case .rolltop: "rolltop"
        }
    }

    /// Shown to the user: the app's name, else the tool's file name.
    var displayName: String {
        if let name, !name.isEmpty { return name }
        if let path { return (path as NSString).lastPathComponent }
        return bundleID ?? (kind == .unknown ? String(localized: "Unknown sender", table: "Automation") : kind.rawValue)
    }

    var description: String {
        "\(kind.rawValue)(\(bundleID ?? path ?? "-"), pid \(pid.map(String.init) ?? "-"))"
    }
}

/// Decides and runs a `rolltop://` link. The Interop feature registers its policy gate (sender
/// checks, prompts, rate limit); the default runs only what is safe without one.
protocol LinkGating: AnyObject {
    func handle(_ url: URL, sender: LinkSender)
}

/// Without a policy gate: `rolltop://command/<id>` runs only commands that allow URLs and only
/// change what is shown; other hosts go to `context.urlRoutes`.
final class CoreLinkGate: LinkGating {
    private unowned let context: AppContext
    private let log = Log.logger("url")

    init(context: AppContext) { self.context = context }

    func handle(_ url: URL, sender: LinkSender) {
        if let route = URLRouter.parse(url) {
            guard let command = context.commands.command(route.command), command.allowedFromURL,
                  command.id.isDebugOnly || command.resolvedEffect == .display else {
                log.notice("link \(route.command) from \(sender): refused (no link policy for this command)")
                return
            }
            context.commands.runDetached(route.command, arguments: route.arguments, source: .url)
        } else if url.scheme?.lowercased() == "rolltop", let host = url.host?.lowercased(), let handler = context.urlRoutes.handlers[host] {
            handler(url)
        } else {
            log.error("ignoring link \(url.scheme ?? "?")://\(url.host ?? "?")")
        }
    }
}

extension ServiceKey where Service == any LinkGating {
    static var linkGate: Self { .init("linkGate") { CoreLinkGate(context: $0) } }
}
