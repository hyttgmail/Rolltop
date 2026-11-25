import AppKit
import RolltopCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var state: AppState?
    /// Owns the `GURL` handler from before launch finishes (links that launch Rolltop).
    private let links = LinkIntake()
    private let log = Log.logger("app")

    /// Unit tests run inside this app (TEST_HOST); then nothing is started: no status
    /// item, no restriction, no single-instance check.
    static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || NSClassFromString("XCTestCase") != nil

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningTests else { return }
        guard SingleInstance.claim() else {
            log.notice("another Rolltop instance is running; exiting")
            exit(0)
        }
        links.install()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningTests else {
            log.notice("running as a unit-test host: not starting")
            return
        }
        // The launching Apple event (`oapp`; a login item's carries `keyAELaunchedAsLogInItem`)
        // is current only now.
        let event = NSAppleEventManager.shared().currentAppleEvent
        let propData = event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
        let loginMarker = StatusItemLaunch.isLoginItemEvent(eventClass: event?.eventClass, eventID: event?.eventID, propData: propData)
        let state = AppState()
        self.state = state
        state.start()
        let loginDate = StatusItemLaunch.consoleLoginDate()
        let trigger = StatusItemLaunch.trigger(launchedByLaunchServices: state.context.launchInfo.launchedByLaunchServices,
                                               loginItemMarker: loginMarker, linkQueued: links.queuedCount > 0,
                                               secondsSinceLogin: loginDate.map { Date().timeIntervalSince($0) })
        log.notice("launch event \(Self.fourCC(event?.eventClass))/\(Self.fourCC(event?.eventID)) prop \(Self.fourCC(propData)); "
            + "console login \(loginDate.map { "\(Int(Date().timeIntervalSince($0))) s ago" } ?? "unknown"); queued links \(links.queuedCount)")
        state.openSettingsIfIconHidden(trigger: trigger)
        links.startDelivering { [weak state] url, sender in state?.open(url, sender: sender) }
    }

    /// `oapp`, `aevt`… for the launch log; "-" when absent.
    private static func fourCC(_ code: UInt32?) -> String {
        guard let code, code != 0 else { return "-" }
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return bytes.allSatisfy { $0 >= 0x20 && $0 < 0x7F } ? String(decoding: bytes, as: UTF8.self) : String(code)
    }

    func applicationWillTerminate(_ notification: Notification) {
        state?.stop()
        state = nil
    }

    /// Last resort of `AppTermination`: stop every feature and release the menu bar.
    func stopBeforeExit() {
        state?.stop()
        state = nil
    }

    /// Only reached if AppKit's own `GURL` handling runs (the intake replaces it): the
    /// sender is unknown.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard !Self.isRunningTests else { return }
        for url in urls { links.receive(url, sender: .unknown) }
    }

    /// Opening the app again (Finder, Spotlight, `open -a`) shows Settings: the status item
    /// may be hidden (Settings › General). The one way back that no setting can turn off.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        log.notice("reopened (visible windows: \(flag)); showing Settings")
        state?.showSettings()
        return false
    }
}

/// `app.quit` always quits: it ends Rolltop's own modal sessions, sheets and alerts first
/// (a sheet or modal session can make AppKit defer or refuse `terminate`), then
/// terminates; if the process is still alive after `fallbackDelay`, it stops every feature
/// and exits. macOS releases the menu bar restriction when the process exits.
enum AppTermination {
    static let fallbackDelay: Duration = .seconds(2)
    private static let log = Log.logger("app")

    static func quit() {
        if let modal = NSApp.modalWindow {
            log.notice("quit: aborting modal session of \(modal.className)")
            NSApp.abortModal()
        }
        for window in NSApp.windows {
            if let sheet = window.attachedSheet {
                log.notice("quit: ending sheet \(sheet.className) on \(window.title)")
                window.endSheet(sheet)
                sheet.orderOut(nil)
            }
        }
        Task { @MainActor in
            try? await Task.sleep(for: fallbackDelay)
            log.error("quit: still running \(fallbackDelay) after terminate; stopping and exiting")
            (NSApp.delegate as? AppDelegate)?.stopBeforeExit()
            exit(0)
        }
        // Let the sheets close on this turn, then terminate.
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
}

/// One Rolltop per user session. The copy in /Applications (the only one whose items macOS
/// shows) ignores copies running elsewhere, such as a unit-test host in a build folder;
/// a copy outside /Applications defers to any other instance.
enum SingleInstance {
    static func claim() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return true }
        let me = ProcessInfo.processInfo.processIdentifier
        let iAmInstalled = isInApplications(Bundle.main.bundleURL)
        return !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains { other in
            guard other.processIdentifier != me, !other.isTerminated else { return false }
            return !iAmInstalled || isInApplications(other.bundleURL)
        }
    }

    private static func isInApplications(_ url: URL?) -> Bool {
        guard let url else { return false }
        return !RunningAppRecord.isOutsideApplications(resolvedPath: url.resolvingSymlinksInPath().path)
    }
}
