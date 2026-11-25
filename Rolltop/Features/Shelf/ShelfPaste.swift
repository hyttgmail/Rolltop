import Foundation

/// How a paste ended.
nonisolated enum ShelfPasteOutcome: String, Sendable, Equatable {
    case pasted
    /// The clip could not be put on the clipboard.
    case copyFailed = "copy-failed"
    /// No app to paste into (Rolltop was frontmost).
    case noTarget = "no-target"
    /// The app the user was in did not come back in time; the clip stays on the clipboard.
    case timedOut = "timed-out"
    /// Rolltop lacks Device Control and Data Access, so no key was posted.
    case notTrusted = "not-trusted"

    /// What the user is told; nil when there is nothing to say.
    var notice: String? {
        switch self {
        case .pasted, .copyFailed: nil
        case .noTarget, .timedOut:
            String(localized: "Copied, not pasted: the app you were in didn’t come back in time.", table: "Shelf")
        case .notTrusted:
            String(localized: "Copied, not pasted: Rolltop needs Device Control and Data Access.", table: "Shelf")
        }
    }
}

/// The paste sequence with injected steps (tests use fakes; nothing but the controller's
/// `paster` reaches `EventSynthesizer.postPaste()`): put the clip on the clipboard → close
/// the surface → wait until the target app is frontmost again (poll, give up after
/// `timeout`, leaving the clip on the clipboard) → post ⌘V.
struct ShelfPasteFlow {
    var copy: @MainActor () -> Bool
    var close: @MainActor () -> Void
    var frontmostPID: @MainActor () -> pid_t?
    var post: @MainActor () -> Bool
    var timeout: Duration = .milliseconds(600)
    var interval: Duration = .milliseconds(40)
    var sleep: @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }

    func run(target: pid_t?) async -> ShelfPasteOutcome {
        guard copy() else { return .copyFailed }
        close()
        guard let target else { return .noTarget }
        var waited: Duration = .zero
        while frontmostPID() != target {
            guard waited < timeout else { return .timedOut }
            await sleep(interval)
            waited += interval
        }
        return post() ? .pasted : .notTrusted
    }
}
