import Foundation
import Observation
import ServiceManagement

/// "Open at login" through `SMAppService.mainApp`. Reads the real status from macOS (the
/// user can change it in System Settings at any time) and keeps the last failure.
@Observable
final class LaunchAtLogin {
    enum State: Equatable, Sendable {
        case enabled
        case disabled
        /// Registered, but the user has to allow it in System Settings › General › Login Items.
        case requiresApproval
    }

    private(set) var state: State
    /// The status as macOS reports it (`not-registered`, `enabled`, `requires-approval`,
    /// `not-found`), for diagnostics.
    private(set) var rawStatus: String
    private(set) var lastError: String?
    @ObservationIgnored private let log = Log.logger("settings-shell")

    init() {
        let status = SMAppService.mainApp.status
        state = Self.state(for: status)
        rawStatus = Self.name(of: status)
        log.info("open at login: status \(rawStatus)")
    }

    /// `.notFound` is what macOS 27.2.1 reported for the unregistered copy in /Applications
    /// (measured 2026-11-24), so it reads as "off", not as an error. A failed
    /// register call is reported through `lastError`.
    nonisolated static func state(for status: SMAppService.Status) -> State {
        switch status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered, .notFound: .disabled
        @unknown default: .disabled
        }
    }

    nonisolated static func name(of status: SMAppService.Status) -> String {
        switch status {
        case .enabled: "enabled"
        case .requiresApproval: "requires-approval"
        case .notRegistered: "not-registered"
        case .notFound: "not-found"
        @unknown default: "unknown-\(status.rawValue)"
        }
    }

    /// Whether the toggle shows as on: registered, approved or not yet.
    var isOn: Bool { state != .disabled }

    func refresh() {
        let status = SMAppService.mainApp.status
        let new = Self.state(for: status)
        if new != state { state = new }
        let name = Self.name(of: status)
        if name != rawStatus {
            rawStatus = name
            log.info("open at login: status \(name)")
        }
    }

    /// Registers or unregisters, then reads the status back. Only from a user action.
    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
            log.info("open at login \(enabled ? "registered" : "unregistered")")
        } catch {
            lastError = error.localizedDescription
            log.error("open at login \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)")
        }
        refresh()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
