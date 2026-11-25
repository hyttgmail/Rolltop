import AppKit
import ApplicationServices
import CoreGraphics
import Observation

/// Live state of the permissions Rolltop uses. Reading never prompts; only the
/// `request…` methods may show a system dialog, and only when the user asked.
@Observable
final class Permissions {
    enum Kind: String, CaseIterable, Sendable {
        case accessibility
        case screenRecording = "screen-recording"

        /// The exact System Settings pane. The Accessibility link opens Privacy & Security ›
        /// Device Control and Data Access on 27.2.1 (PLATFORM §9); the Screen Recording link
        /// is taken from 14/15 and unverified on 27.
        var settingsURL: URL {
            switch self {
            case .accessibility: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            case .screenRecording: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            }
        }
    }

    private(set) var accessibility: Bool
    private(set) var screenRecording: Bool

    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var timer: Timer?

    init() {
        accessibility = AXIsProcessTrusted()
        screenRecording = CGPreflightScreenCaptureAccess()
    }

    func isGranted(_ kind: Kind) -> Bool {
        switch kind {
        case .accessibility: accessibility
        case .screenRecording: screenRecording
        }
    }

    /// Starts watching: the system posts `com.apple.accessibility.api` when the trust
    /// list changes; a slow timer catches the rest.
    func startMonitoring() {
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main) { [weak self] _ in
            // Trust changes land a moment after the notification.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                self?.refresh()
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        let ax = AXIsProcessTrusted()
        if ax != accessibility { accessibility = ax }
        let sr = CGPreflightScreenCaptureAccess()
        if sr != screenRecording { screenRecording = sr }
    }

    /// Shows the system Accessibility prompt. Call only from an explicit user action.
    func requestAccessibility() {
        // "AXTrustedCheckOptionPrompt" is the value of kAXTrustedCheckOptionPrompt.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        accessibility = AXIsProcessTrustedWithOptions(options)
    }

    /// Shows the system Screen Recording prompt. Call only from an explicit user action.
    func requestScreenRecording() {
        screenRecording = CGRequestScreenCaptureAccess()
    }

    func openSettings(for kind: Kind) {
        NSWorkspace.shared.open(kind.settingsURL)
    }
}
