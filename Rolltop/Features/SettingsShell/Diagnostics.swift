import AppKit
import Foundation
import RolltopCore

/// The text "Copy diagnostics" puts on the pasteboard: versions, permissions, launch path
/// and restriction state. Never item names, bundle ids of other apps or settings values.
nonisolated struct Diagnostics: Equatable, Sendable {
    var appVersion: String
    var appBuild: String
    var osVersion: String
    var bundlePath: String
    var runsFromApplications: Bool
    var launchedByLaunchServices: Bool
    var accessibility: Bool
    var accessibilityAtLaunch: Bool
    var screenRecording: Bool
    var restrictionAvailable: Bool
    var restrictionHeld: Bool
    var presentation: String
    var concealShown: Bool
    var lastError: String?
    var catalogEntryCount: Int
    var explicitSectionCount: Int
    var openAtLogin: String

    var text: String {
        func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }
        var lines = [
            "Rolltop \(appVersion) (\(appBuild))",
            "macOS \(osVersion)",
            "Path: \(bundlePath)",
            "Runs from /Applications: \(yesNo(runsFromApplications))",
            "Launched by: \(launchedByLaunchServices ? "LaunchServices" : "shell (inherits the terminal's permissions)")",
            "Accessibility: \(yesNo(accessibility)) (at launch: \(yesNo(accessibilityAtLaunch)))",
            "Screen Recording: \(yesNo(screenRecording))",
            "Restriction API available: \(yesNo(restrictionAvailable))",
            "Restriction held: \(yesNo(restrictionHeld))",
            "Presentation: \(presentation)\(concealShown ? ", shown items concealed" : "")",
            "Menu bar entries: \(catalogEntryCount), with a saved section: \(explicitSectionCount)",
            "Open at login: \(openAtLogin)",
        ]
        if let lastError { lines.append("Last error: \(lastError)") }
        return lines.joined(separator: "\n")
    }
}

extension Diagnostics {
    @MainActor
    static func current(_ context: AppContext, launchAtLogin: LaunchAtLogin) -> Diagnostics {
        let info = Bundle.main.infoDictionary ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let build = ProcessInfo.processInfo.operatingSystemVersionString
        return Diagnostics(
            appVersion: info["CFBundleShortVersionString"] as? String ?? "?",
            appBuild: info["CFBundleVersion"] as? String ?? "?",
            osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion) (\(build))",
            bundlePath: context.launchInfo.bundlePath,
            runsFromApplications: context.launchInfo.runsFromApplications,
            launchedByLaunchServices: context.launchInfo.launchedByLaunchServices,
            accessibility: context.permissions.accessibility,
            accessibilityAtLaunch: context.launchInfo.accessibilityTrustedAtLaunch,
            screenRecording: context.permissions.screenRecording,
            restrictionAvailable: context.visibility.isAvailable,
            restrictionHeld: context.visibility.isRestrictionHeld,
            presentation: context.visibility.level.rawValue,
            concealShown: context.visibility.concealShown,
            lastError: context.visibility.lastError,
            catalogEntryCount: context.catalog.entries.count,
            explicitSectionCount: context.layout.layout.sections.count,
            openAtLogin: launchAtLogin.rawStatus)
    }

    @MainActor
    func copyToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// "Reset all settings": every `rolltop.*` setting goes back to its default, the in-memory
/// layout included (`LayoutStore` does not reread the defaults by itself). Open at login
/// and permissions live outside Rolltop's settings and are not touched, nor is runtime state
/// stored under transient keys (onboarding, active rules, spacing record…).
enum SettingsReset {
    static func resetAll(settings: SettingsStore, layout: LayoutStore) {
        layout.replace(with: .empty)
        settings.replaceAll(with: [:])
    }
}
