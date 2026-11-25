import AppKit
import Foundation

/// Calls back on the main actor whenever the set of running applications changes.
/// KVO on `runningApplications`: NSWorkspace posts no launch notification for agent
/// (LSUIElement) apps (docs/PLATFORM.md §2).
nonisolated final class RunningAppsObserver: @unchecked Sendable {
    private var observation: NSKeyValueObservation?

    init(onChange: @escaping @MainActor @Sendable () -> Void) {
        observation = NSWorkspace.shared.observe(\.runningApplications, options: [.new, .old]) { _, _ in
            Task { @MainActor in onChange() }
        }
    }

    func invalidate() {
        observation?.invalidate()
        observation = nil
    }

    deinit { observation?.invalidate() }
}
