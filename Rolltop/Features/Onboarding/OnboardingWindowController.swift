import AppKit
import SwiftUI

/// The onboarding window. Closing it (Done or the close button) counts as a dismissal.
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let windowIdentifier = NSUserInterfaceItemIdentifier("rolltop.onboarding")

    private let permissions: Permissions
    /// Called once per dismissal; `simulated` is true for Debug captures, which record nothing.
    private let onDismiss: (_ simulated: Bool) -> Void
    private var window: NSWindow?
    private var hosting: NSHostingController<OnboardingView>?
    private var simulation: OnboardingSimulation?
    private let log = Log.logger("onboarding")

    init(permissions: Permissions, onDismiss: @escaping (_ simulated: Bool) -> Void) {
        self.permissions = permissions
        self.onDismiss = onDismiss
        super.init()
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func close() {
        window?.performClose(nil)
    }

    func show(simulation: OnboardingSimulation? = nil) {
        self.simulation = simulation
        let view = OnboardingView(permissions: permissions, simulation: simulation) { [weak self] in
            self?.window?.performClose(nil)
        }
        if let hosting {
            hosting.rootView = view
        } else {
            makeWindow(view)
        }
        guard let window else { return }
        WindowPresentation.present(window, log: log)
    }

    private func makeWindow(_ view: OnboardingView) {
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.identifier = Self.windowIdentifier
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = String(localized: "Welcome to Rolltop", table: "Onboarding")
        window.setContentSize(OnboardingView.size)
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenNone]
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.delegate = self
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        window.center()
        self.hosting = hosting
        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        let simulated = simulation != nil
        simulation = nil
        onDismiss(simulated)
    }
}
