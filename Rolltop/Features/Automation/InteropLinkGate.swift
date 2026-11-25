import AppKit
import Foundation
import Observation
import RolltopCore

/// One handled link, for the pane's "Recent links" and the Debug dump. Holds the command
/// id and the sender, never the link's arguments (they may carry names).
struct InteropLinkLogEntry: Identifiable, Equatable, Codable {
    enum Outcome: String, Codable { case ran, failed, asked, allowedAfterAsking, refused, dropped }

    let id: UUID
    let date: Date
    let command: String
    let sender: String
    let senderKind: String
    let senderBundleID: String?
    let senderPath: String?
    var outcome: Outcome
    var reason: String?
}

/// The link gate (`LinkGating`, registered as `services[.linkGate]`): the core link intake
/// hands it every `rolltop://` link with its sender, also the link that launched Rolltop (queued
/// until features started). It applies the link policy, then runs the command (source
/// `.url`) or another feature's route.
@Observable
final class InteropLinkGate: LinkGating {
    private(set) var recent: [InteropLinkLogEntry] = []
    static let recentLimit = 30
    /// Links waiting for the user's answer, per bundle id.
    private(set) var pending: [String: [PendingLink]] = [:]

    struct PendingLink {
        let sender: LinkSender
        let command: CommandID
        let arguments: [String: String]
        let entryID: UUID
    }

    @ObservationIgnored private unowned let context: AppContext
    @ObservationIgnored private var limiter = InteropRateLimiter()
    @ObservationIgnored var prompter: InteropLinkPrompter?
    @ObservationIgnored private let log = Log.logger("interop")
    /// The sender of the link being dispatched to a `urlRoutes` handler (nil: the core
    /// router called it, the sender is unknown).
    @ObservationIgnored private(set) var currentSender: LinkSender?
    @ObservationIgnored var now: () -> Date = Date.init

    static let maximumPendingPerApp = 5

    init(context: AppContext) {
        self.context = context
    }

    // MARK: Aliases

    /// Keeps the alias hosts reserved in `context.urlRoutes` so no other feature takes
    /// them; this gate resolves aliases itself, before routes.
    func registerAliases() {
        for host in InteropLinkRoutes.aliasHosts {
            context.urlRoutes.register(host: host) { [weak self] url in
                guard let self else { return }
                self.handle(url, sender: self.currentSender ?? .unknown)
            }
        }
    }

    // MARK: Handling

    var policySettings: InteropLinkPolicySettings {
        let settings = context.settings
        var apps: [String: InteropLinkAppRecord.Decision] = [:]
        for record in settings[InteropSettings.linkApps] { apps[record.bundleID] = record.decision }
        return InteropLinkPolicySettings(linksEnabled: settings[InteropSettings.linksEnabled],
                                         allowUnknownSenders: settings[InteropSettings.allowUnknownSenders],
                                         allowSettingsCommands: settings[InteropSettings.allowSettingsCommands],
                                         apps: apps)
    }

    private var foreignRouteHosts: Set<String> {
        Set(context.urlRoutes.handlers.keys).subtracting(InteropLinkRoutes.aliasHosts)
    }

    func handle(_ url: URL, sender: LinkSender) {
        handle(url, sender: sender, asRelease: false)
    }

    /// `asRelease`: decide as a Release build would (Debug test links that pretend a sender).
    func handle(_ url: URL, sender: LinkSender, asRelease: Bool) {
        let palette = InteropLinkRoutes.paletteCommand(in: context.commands.commands.map(\.id))
        switch InteropLinkRoutes.target(of: url, paletteCommand: palette, routeHosts: foreignRouteHosts) {
        case .command(let id, let arguments):
            handleCommand(id, arguments: arguments, sender: sender, asRelease: asRelease)
        case .route(let host):
            handleRoute(host, url: url, sender: sender, asRelease: asRelease)
        case .unavailable(let what):
            record(command: what, sender: sender, outcome: .refused, reason: "not available")
        case .invalid:
            record(command: url.host() ?? "?", sender: sender, outcome: .refused, reason: InteropLinkRefusal.unknownRoute.rawValue)
        }
    }

    private func handleCommand(_ id: CommandID, arguments: [String: String], sender: LinkSender, asRelease: Bool) {
        let command = context.commands.command(id)
        let request = InteropLinkRequest(command: command == nil ? nil : id,
                                         commandAllowsLinks: command?.allowedFromURL ?? false, effect: command?.effect, sender: sender)
        let rateAllowed = sender.kind == .rolltop || limiter.allow(sender.key, now: now())
        let decision = InteropLinkPolicy.decide(request, settings: policySettings,
                                                isDebugBuild: InteropLinkPolicy.isDebugBuild && !asRelease, rateAllowed: rateAllowed)
        switch decision {
        case .run:
            let entry = record(command: id.rawValue, sender: sender, outcome: .ran)
            run(id, arguments: arguments, entryID: entry)
        case .ask:
            enqueue(id, arguments: arguments, sender: sender)
        case .refuse(let reason):
            record(command: id.rawValue, sender: sender, outcome: .refused, reason: reason.rawValue)
        }
    }

    /// Another feature's host: the sender checks apply as for a display command.
    private func handleRoute(_ host: String, url: URL, sender: LinkSender, asRelease: Bool) {
        let request = InteropLinkRequest(command: "visibility.show-hidden", commandAllowsLinks: true, effect: .display, sender: sender)
        let rateAllowed = sender.kind == .rolltop || limiter.allow(sender.key, now: now())
        let decision = InteropLinkPolicy.decide(request, settings: policySettings,
                                                isDebugBuild: InteropLinkPolicy.isDebugBuild && !asRelease, rateAllowed: rateAllowed)
        guard decision == .run, let handler = context.urlRoutes.handlers[host] else {
            record(command: "route:" + host, sender: sender, outcome: .refused,
                   reason: decision == .ask ? "app not yet allowed" : (decision == .run ? "no handler" : "\(decision)"))
            return
        }
        record(command: "route:" + host, sender: sender, outcome: .ran)
        currentSender = sender
        handler(url)
        currentSender = nil
    }

    private func run(_ id: CommandID, arguments: [String: String], entryID: UUID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.context.commands.run(id, arguments: arguments, source: .url)
            } catch {
                self.update(entryID, outcome: .failed, reason: error.localizedDescription)
                self.log.error("link \(id) failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Asking

    private func enqueue(_ id: CommandID, arguments: [String: String], sender: LinkSender) {
        guard let bundleID = sender.bundleID else { return }
        var queue = pending[bundleID] ?? []
        guard queue.count < Self.maximumPendingPerApp else {
            record(command: id.rawValue, sender: sender, outcome: .dropped, reason: "waiting for an answer")
            return
        }
        let entry = record(command: id.rawValue, sender: sender, outcome: .asked)
        let isFirst = queue.isEmpty
        queue.append(PendingLink(sender: sender, command: id, arguments: arguments, entryID: entry))
        pending[bundleID] = queue
        if isFirst {
            let title = context.commands.command(id)?.localizedTitle ?? id.rawValue
            prompter?.ask(sender: sender, firstCommandTitle: title) { [weak self] answer in
                self?.answer(answer, for: sender)
            }
        }
    }

    /// The user's answer (nil: the prompt timed out or was closed; nothing is remembered).
    func answer(_ decision: InteropLinkAppRecord.Decision?, for sender: LinkSender) {
        guard let bundleID = sender.bundleID else { return }
        let queue = pending.removeValue(forKey: bundleID) ?? []
        if let decision {
            // The name the app had when it asked (a caller may only know the bundle id).
            setDecision(decision, bundleID: bundleID, name: queue.first?.sender.displayName ?? sender.displayName)
        }
        for link in queue {
            if decision == .allowed {
                update(link.entryID, outcome: .allowedAfterAsking, reason: nil)
                run(link.command, arguments: link.arguments, entryID: link.entryID)
            } else {
                update(link.entryID, outcome: .refused, reason: decision == .blocked ? InteropLinkRefusal.blockedApp.rawValue : "not answered")
            }
        }
    }

    // MARK: App list

    func setDecision(_ decision: InteropLinkAppRecord.Decision, bundleID: String, name: String) {
        var records = context.settings[InteropSettings.linkApps].filter { $0.bundleID != bundleID }
        records.append(InteropLinkAppRecord(bundleID: bundleID, name: name, decision: decision, decidedAt: now()))
        context.settings[InteropSettings.linkApps] = records
        log.notice("links from \(bundleID): \(decision.rawValue)")
    }

    func forget(bundleID: String) {
        context.settings[InteropSettings.linkApps] = context.settings[InteropSettings.linkApps].filter { $0.bundleID != bundleID }
    }

    // MARK: Log

    @discardableResult
    private func record(command: String, sender: LinkSender, outcome: InteropLinkLogEntry.Outcome, reason: String? = nil) -> UUID {
        let entry = InteropLinkLogEntry(id: UUID(), date: now(), command: command, sender: sender.displayName,
                                        senderKind: sender.kind.rawValue, senderBundleID: sender.bundleID,
                                        senderPath: sender.path, outcome: outcome, reason: reason)
        recent.insert(entry, at: 0)
        if recent.count > Self.recentLimit { recent.removeLast(recent.count - Self.recentLimit) }
        let line = "link \(command) from \(sender): \(outcome.rawValue)\(reason.map { " (\($0))" } ?? "")"
        if outcome == .refused || outcome == .dropped { log.notice(line) } else { log.info(line) }
        return entry.id
    }

    private func update(_ id: UUID, outcome: InteropLinkLogEntry.Outcome, reason: String?) {
        guard let index = recent.firstIndex(where: { $0.id == id }) else { return }
        recent[index].outcome = outcome
        recent[index].reason = reason
    }

    func clearRecent() { recent.removeAll() }
}
