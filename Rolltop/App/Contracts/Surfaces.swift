import AppKit
import Observation

/// Rolltop's transient surfaces: the Rolltop Bar (hidden items or a group's members), the command
/// palette, the Shelf and a group's empty-state panel. One at a time, whichever opens
/// second (DESIGN.md, "Floating panels"): a surface calls `willPresent` before it shows
/// (the one on screen is told to close and must call `didDismiss` from that call) and
/// `didDismiss` whenever it went away.
///
/// It also remembers the app that was frontmost when the first of a run of surfaces
/// opened, and gives it the keyboard back when the last one closes by the user's choice
/// while Rolltop is active (a surface such as the palette made it so). A surface handing over
/// to another never does, nor one closed by a click elsewhere.
///
///     let surfaces = context.services[.surfaces]
///     surfaces.willPresent("palette") { [weak self] newSurface in self?.close(.yielded) }
///     …
///     surfaces.didDismiss("palette", restoreFocus: reason == .escape)
@Observable
final class TransientSurfaceCoordinator {
    /// The surface on screen: `secondary-bar`, `palette`, `shelf`, `custom-items.group`.
    private(set) var current: String?
    /// Frontmost app when the first surface of this run opened (never Rolltop).
    @ObservationIgnored private(set) var previousApp: NSRunningApplication?
    /// True while the surface on screen closes because another one takes over.
    @ObservationIgnored private(set) var isHandingOver = false
    /// The last handovers, newest last (`from→to`), for Debug dumps.
    @ObservationIgnored private(set) var handovers: [String] = []
    @ObservationIgnored private var dismissCurrent: ((String) -> Void)?
    // Seams for tests.
    @ObservationIgnored var frontmostApplication: () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication }
    @ObservationIgnored var isRolltopActive: () -> Bool = { NSApp.isActive }
    @ObservationIgnored var activate: (NSRunningApplication) -> Void = { _ = $0.activate() }
    @ObservationIgnored private let log = Log.logger("surfaces")

    /// `dismiss` receives the id of the surface that takes over.
    func willPresent(_ id: String, dismiss: @escaping (String) -> Void) {
        if let current, current != id {
            handovers.append("\(current)→\(id)")
            if handovers.count > 20 { handovers.removeFirst(handovers.count - 20) }
            log.info("\(current) yields to \(id)")
            let closeCurrent = dismissCurrent
            isHandingOver = true
            closeCurrent?(id)
            isHandingOver = false
            if self.current == current {
                // The surface did not report back: forget it rather than block the new one.
                log.error("\(current) did not report its dismissal")
                self.current = nil
            }
        } else if current == nil {
            let front = frontmostApplication()
            previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        }
        current = id
        dismissCurrent = dismiss
    }

    /// `restoreFocus`: the surface closed by the user's choice inside Rolltop (Escape, a toggle,
    /// a row that ran), so the app that was frontmost gets the keyboard back if Rolltop has it.
    func didDismiss(_ id: String, restoreFocus: Bool) {
        guard current == id else { return }
        current = nil
        dismissCurrent = nil
        guard !isHandingOver else { return }
        if restoreFocus, isRolltopActive(), let previousApp, !previousApp.isTerminated {
            log.info("handing the keyboard back to \(previousApp.bundleIdentifier ?? "?")")
            activate(previousApp)
        }
        previousApp = nil
    }
}

extension ServiceKey where Service == TransientSurfaceCoordinator {
    static var surfaces: Self { .init("surfaces") { _ in TransientSurfaceCoordinator() } }
}
