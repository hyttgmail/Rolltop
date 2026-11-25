import Foundation
import RolltopCore

// Pure decisions for `rolltop://` links: what a command may do, who sent the link, and
// whether it runs, asks the user, or is refused. No AppKit, no settings store.

/// The settings the decision reads.
nonisolated struct InteropLinkPolicySettings: Sendable, Equatable {
    var linksEnabled = true
    var allowUnknownSenders = true
    var allowSettingsCommands = false
    /// bundle id → remembered answer.
    var apps: [String: InteropLinkAppRecord.Decision] = [:]
}

nonisolated enum InteropLinkDecision: Equatable, Sendable {
    case run
    /// Ask the user once whether this app may send links; run on "Allow".
    case ask
    case refuse(InteropLinkRefusal)
}

nonisolated enum InteropLinkRefusal: String, Equatable, Sendable {
    case linksOff = "links are turned off"
    case unknownCommand = "unknown command"
    case notAllowedFromLinks = "command does not allow links"
    case restricted = "destructive or security-relevant command"
    case testHook = "Debug command from an app"
    case settingsCommandsOff = "links that change settings are turned off"
    case unknownSenderOff = "links from unknown senders are turned off"
    case blockedApp = "app is blocked"
    case rateLimited = "too many links"
    case unknownRoute = "unknown link"
}

/// What the gate knows about one link before deciding.
nonisolated struct InteropLinkRequest: Sendable, Equatable {
    var command: CommandID?
    /// The registered command allows URLs (`Command.allowedFromURL`); false when unknown.
    var commandAllowsLinks: Bool
    /// The command's declared effect (`Command.effect`); nil (undeclared) counts as
    /// destructive.
    var effect: CommandEffect?
    var sender: LinkSender
}

nonisolated enum InteropLinkPolicy {
    /// Debug builds let links from a sender without an app identity (the shell's `open`,
    /// which is how `scripts/rolltop-cmd.sh` sends) run every non-destructive command that
    /// allows URLs, and the Debug commands, with no prompt, settings check or rate limit,
    /// so live test scripts keep working. Destructive commands are refused in every build.
    /// Compiled in; never stored.
    #if DEBUG
    static let isDebugBuild = true
    #else
    static let isDebugBuild = false
    #endif

    /// `rateAllowed` is the rate limiter's answer for this sender (checked by the caller,
    /// which also records the hit).
    static func decide(_ request: InteropLinkRequest, settings: InteropLinkPolicySettings,
                       isDebugBuild: Bool = isDebugBuild, rateAllowed: Bool) -> InteropLinkDecision {
        guard let command = request.command else { return .refuse(.unknownCommand) }
        guard request.commandAllowsLinks else { return .refuse(.notAllowedFromLinks) }
        let anonymous = request.sender.kind == .tool || request.sender.kind == .unknown
        // Debug-build commands: only Debug builds have them, and only test scripts (no app
        // identity) and Rolltop's own buttons may run them.
        if command.isDebugOnly {
            return isDebugBuild && (anonymous || request.sender.kind == .rolltop) ? .run : .refuse(.testHook)
        }
        let effect = request.effect ?? .destructive
        // Never from a link, whoever sends it and whatever the build.
        if effect == .destructive { return .refuse(.restricted) }
        if isDebugBuild, anonymous { return .run }
        guard settings.linksEnabled || request.sender.kind == .rolltop else { return .refuse(.linksOff) }
        if effect == .changesSettings, !settings.allowSettingsCommands, request.sender.kind != .rolltop {
            return .refuse(.settingsCommandsOff)
        }
        switch request.sender.kind {
        case .rolltop:
            return .run
        case .tool, .unknown:
            guard settings.allowUnknownSenders else { return .refuse(.unknownSenderOff) }
            return rateAllowed ? .run : .refuse(.rateLimited)
        case .app:
            switch request.sender.bundleID.flatMap({ settings.apps[$0] }) {
            case .blocked?: return .refuse(.blockedApp)
            case .allowed?: return rateAllowed ? .run : .refuse(.rateLimited)
            case nil: return rateAllowed ? .ask : .refuse(.rateLimited)
            }
        }
    }
}

/// Token bucket per sender: `capacity` links at once, then `refillPerSecond`.
nonisolated struct InteropRateLimiter: Sendable {
    var capacity: Double = 10
    var refillPerSecond: Double = 2
    private var buckets: [String: (tokens: Double, updated: Date)] = [:]

    init(capacity: Double = 10, refillPerSecond: Double = 2) {
        self.capacity = capacity
        self.refillPerSecond = refillPerSecond
    }

    /// Takes one token for `key`; false when the bucket is empty (the link is dropped).
    mutating func allow(_ key: String, now: Date) -> Bool {
        var bucket = buckets[key] ?? (capacity, now)
        let elapsed = max(0, now.timeIntervalSince(bucket.updated))
        bucket.tokens = min(capacity, bucket.tokens + elapsed * refillPerSecond)
        bucket.updated = now
        let allowed = bucket.tokens >= 1
        if allowed { bucket.tokens -= 1 }
        buckets[key] = bucket
        return allowed
    }
}
