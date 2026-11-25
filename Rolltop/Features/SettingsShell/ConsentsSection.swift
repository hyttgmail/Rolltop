import AppKit
import SwiftUI

/// Settings › Permissions, "Features that need your permission": one row per registered
/// `ConsentItem` (docs/CONTRACTS.md, "Consent rows"). Hidden while nothing is registered.
/// Statuses are read when the pane appears, every 2 s while it is visible and after each
/// request; buttons are off in a Rolltop started from a terminal.
struct SettingsShellConsentsSection: View {
    let context: AppContext

    static let refreshInterval: Duration = .seconds(2)

    private var registry: ConsentRegistry { context.services[.consents] }
    private var buttonsEnabled: Bool {
        ConsentAction.buttonsEnabled(launchedByLaunchServices: context.launchInfo.launchedByLaunchServices)
    }

    var body: some View {
        let registry = registry
        if !registry.items.isEmpty {
            SwiftUI.Section {
                Text("macOS records each permission for the app that asks for it. Open Rolltop the usual way (from Applications, Spotlight or at login) before you allow anything here.",
                     tableName: "SettingsShell")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !buttonsEnabled {
                    LimitationNote(Text("This Rolltop was started from a terminal. macOS would record what you allow now for the terminal instead of Rolltop, so these buttons are off. Quit Rolltop and open it from Applications.",
                                        tableName: "SettingsShell"),
                                   tone: .warning)
                }
                ForEach(registry.items) { item in
                    SettingsShellConsentRow(item: item, status: registry.status(for: item.id),
                                            isRequesting: registry.requesting.contains(item.id),
                                            buttonsEnabled: buttonsEnabled) {
                        Task { await registry.request(id: item.id) }
                    }
                }
            } header: {
                Text("Features that need your permission", tableName: "SettingsShell")
            }
        }
    }

    /// Re-reads every status now and then every `refreshInterval` until cancelled. Run it
    /// once per pane from a `.task` on the pane's `Form` (a modifier on a `Section` may be
    /// applied per row).
    static func pollStatuses(_ registry: ConsentRegistry) async {
        while !Task.isCancelled {
            registry.refresh()
            try? await Task.sleep(for: refreshInterval)
        }
    }
}

/// One consent row: title, purpose, reason, live status and the button that fits it.
struct SettingsShellConsentRow: View {
    let item: ConsentItem
    let status: ConsentStatus?
    let isRequesting: Bool
    let buttonsEnabled: Bool
    let request: () -> Void

    var body: some View {
        LabeledContent {
            ConsentStatusLabel(status: status)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                Text(item.purpose)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let note {
                    note
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                buttons
            }
        }
        .accessibilityIdentifier("consent.\(item.id)")
    }

    private var note: Text? {
        switch status {
        case .cannotAskNow(let reason), .unavailable(let reason): Text(verbatim: reason)
        case .notAllowed where item.settingsURL != nil: Text("Change this in System Settings.", tableName: "SettingsShell")
        default: nil
        }
    }

    @ViewBuilder private var buttons: some View {
        let primary = status.flatMap { ConsentAction.primary(for: $0, hasSettingsURL: item.settingsURL != nil) }
        let secondary = status.map(ConsentAction.showsSecondary(for:)) == true ? item.secondaryAction : nil
        if primary != nil || secondary != nil {
            HStack(spacing: 8) {
                switch primary {
                case .ask:
                    Button(action: request) { Text("Allow…", tableName: "SettingsShell") }
                        .accessibilityIdentifier("consent.ask.\(item.id)")
                case .openSystemSettings:
                    Button {
                        if let url = item.settingsURL { NSWorkspace.shared.open(url) }
                    } label: {
                        Text("Open System Settings", tableName: "SettingsShell")
                    }
                case nil:
                    EmptyView()
                }
                if let secondary {
                    Button {
                        Task { await secondary.action() }
                    } label: {
                        Text(secondary.title)
                    }
                }
            }
            .controlSize(.small)
            .disabled(!buttonsEnabled || isRequesting)
            .padding(.top, 2)
        }
    }
}

/// The shared `location.access` row (several features use Location; SettingsShell owns
/// the row so it appears once).
enum SettingsShellLocationConsent {
    static let id = "location.access"
    static let sortOrder = 100

    /// Pure: what the row shows for the manager's state.
    static func status(authorization: LocationAuthorization, servicesEnabled: Bool) -> ConsentStatus {
        guard servicesEnabled else {
            return .cannotAskNow(String(localized: "Turn on Location Services in System Settings › Privacy & Security.",
                                        table: "SettingsShell"))
        }
        return switch authorization {
        case .authorized: .allowed
        case .denied: .notAllowed
        case .notDetermined: .notAsked
        case .restricted: .unavailable(String(localized: "Location Services are restricted on this Mac.", table: "SettingsShell"))
        }
    }

    /// Reading the status creates the location manager (no prompt); asking is the row's
    /// button only. No persisted marker is needed: reading Location's status never prompts.
    static func item(context: AppContext) -> ConsentItem {
        ConsentItem(id: id, title: LocalizedStringResource("Location Services", table: "SettingsShell"),
                    purpose: LocalizedStringResource("Lets Rolltop read the name of the current Wi-Fi network, check place conditions in automations and show the weather where you are.",
                                                     table: "SettingsShell"),
                    sortOrder: sortOrder,
                    status: { [unowned context] in
                        let location = context.services[.location]
                        location.activate()
                        return status(authorization: location.authorization, servicesEnabled: location.servicesEnabled)
                    },
                    request: { [unowned context] in context.services[.location].requestAuthorization() },
                    settingsURL: LocationAccess.settingsURL)
    }
}

#if DEBUG
/// `settings-shell.debug-consents`: sample rows in every status, for screenshots. Their
/// buttons change nothing but the sample's own status.
@MainActor
enum SettingsShellConsentSamples {
    static let prefix = "settings-shell.sample-"
    private static var statuses: [String: ConsentStatus] = [:]

    static func register(in registry: ConsentRegistry) {
        let samples: [(String, String, String, ConsentStatus, URL?, Bool)] = [
            ("allowed", "Calendars", "Shows your next events in the shelf.", .allowed, nil, false),
            ("refused", "Music", "Shows what is playing in Music and lets you control it.", .notAllowed,
             URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"), false),
            ("not-asked", "Menu bar layout file", "Lets Rolltop change the order of menu bar items.", .notAsked, nil, true),
            ("cannot-ask", "Spotify", "Shows what is playing in Spotify and lets you control it.",
             .cannotAskNow("Open Spotify first, then allow it here."), nil, false),
            ("unavailable", "Focus status", "Shows whether a Focus is on.",
             .unavailable("This Mac doesn’t let Rolltop read Focus."), nil, false),
            ("refused-file", "Menu bar settings file", "Lists apps that are turned off in System Settings › Menu Bar.",
             .notAllowed, nil, true),
        ]
        for (index, (name, title, purpose, status, url, hasSecondary)) in samples.enumerated() {
            let id = prefix + name
            statuses[id] = status
            registry.register(ConsentItem(
                id: id, title: LocalizedStringResource(stringLiteral: title), purpose: LocalizedStringResource(stringLiteral: purpose),
                sortOrder: 900 + index,
                status: { statuses[id] ?? .notAsked },
                request: { statuses[id] = .allowed },
                settingsURL: url,
                secondaryAction: hasSecondary
                    ? ConsentSecondaryAction(title: LocalizedStringResource(stringLiteral: "Choose File…")) { statuses[id] = .allowed }
                    : nil))
        }
        registry.refresh()
    }

    static func reset(in registry: ConsentRegistry) {
        for item in registry.items where item.id.hasPrefix(prefix) { registry.unregister(id: item.id) }
        statuses.removeAll()
    }
}
#endif
