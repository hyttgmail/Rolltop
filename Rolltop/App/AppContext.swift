import Foundation
import RolltopCore

/// How this process was started, recorded once at launch.
struct LaunchInfo: Codable, Sendable {
    let bundlePath: String
    let executablePath: String
    let pid: Int32
    let parentPID: Int32
    /// Parent is launchd: started by LaunchServices (`open`, Finder, login item). Otherwise
    /// a shell launch, which inherits the terminal's permissions.
    let launchedByLaunchServices: Bool
    let runsFromApplications: Bool
    let accessibilityTrustedAtLaunch: Bool
    let launchedAt: Date

    static func current(accessibilityTrusted: Bool) -> LaunchInfo {
        let bundlePath = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let parent = getppid()
        return LaunchInfo(bundlePath: bundlePath,
                          executablePath: Bundle.main.executableURL?.path ?? "",
                          pid: ProcessInfo.processInfo.processIdentifier,
                          parentPID: parent,
                          launchedByLaunchServices: launchedByLaunchServices(parentPID: parent,
                                                                             environment: ProcessInfo.processInfo.environment,
                                                                             bundleID: Bundle.main.bundleIdentifier ?? ""),
                          runsFromApplications: !RunningAppRecord.isOutsideApplications(resolvedPath: bundlePath),
                          accessibilityTrustedAtLaunch: accessibilityTrusted,
                          launchedAt: Date())
    }

    /// A parent pid of 1 alone does not tell: a shell launch whose shell exited (`nohup … &`)
    /// is adopted by launchd too, and `open` passes the caller's environment (`SHLVL`, `TERM`)
    /// on to the app. LaunchServices does run the app as its own launchd job, though:
    /// `XPC_SERVICE_NAME` is `application.<bundle id>.…` (a shell launch inherits the
    /// terminal's value, `0` or the terminal's job) and `__CFBundleIdentifier` is the app's own
    /// (a shell launch inherits the terminal's). Measured on 27.2 (docs/PLATFORM.md §9).
    nonisolated static func launchedByLaunchServices(parentPID: Int32, environment: [String: String],
                                                     bundleID: String) -> Bool {
        guard parentPID == 1 else { return false }
        if let job = environment["XPC_SERVICE_NAME"], job.hasPrefix("application.\(bundleID).") { return true }
        return environment["__CFBundleIdentifier"] == bundleID
    }
}

/// What every feature receives. Created once by `AppState`; lives for the whole process.
final class AppContext {
    /// The running app's context, for framework entry points that cannot be handed one
    /// (AppleScript command classes, App Intents, Focus filters). Everywhere else use the
    /// context passed to `init(context:)`. Nil in unit tests.
    private(set) static weak var current: AppContext?

    let settings: SettingsStore
    let layout: LayoutStore
    let catalog: ItemCatalog
    let visibility: VisibilityEngine
    let activator: ItemActivator
    let clockBridge: ClockBridge
    let permissions: Permissions
    let commands: CommandRegistry
    let settingsPanes: SettingsPaneRegistry
    let services: ServiceLocator
    let urlRoutes: URLRouteRegistry
    let launchInfo: LaunchInfo
    /// Rolltop's own bundle ids: always allowed by the planner.
    let ownBundleIDs: Set<String>
    /// Frame of Rolltop's main status item in global AppKit coordinates (bottom-left origin),
    /// nil while it is not drawn.
    let statusItemFrame: () -> CGRect?

    init(settings: SettingsStore, layout: LayoutStore, catalog: ItemCatalog, visibility: VisibilityEngine,
         activator: ItemActivator, clockBridge: ClockBridge, permissions: Permissions, commands: CommandRegistry,
         settingsPanes: SettingsPaneRegistry, services: ServiceLocator, urlRoutes: URLRouteRegistry, launchInfo: LaunchInfo,
         ownBundleIDs: Set<String>, statusItemFrame: @escaping () -> CGRect?) {
        self.settings = settings
        self.layout = layout
        self.catalog = catalog
        self.visibility = visibility
        self.activator = activator
        self.clockBridge = clockBridge
        self.permissions = permissions
        self.commands = commands
        self.settingsPanes = settingsPanes
        self.services = services
        self.urlRoutes = urlRoutes
        self.launchInfo = launchInfo
        self.ownBundleIDs = ownBundleIDs
        self.statusItemFrame = statusItemFrame
        services.attach(self)
    }

    /// Makes this the context returned by `AppContext.current`.
    func makeCurrent() { Self.current = self }
}
