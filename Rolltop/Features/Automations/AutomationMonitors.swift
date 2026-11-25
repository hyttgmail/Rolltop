import AppKit
import CoreWLAN
import Foundation
import IOKit.ps
import Network
import Observation

// Live sources for the automation environment. Each one reads its state, watches for
// changes, and calls back on the main actor. Nothing here runs under unit tests: the
// controller only creates monitors from `AutomationsFeature.start()`.

// MARK: - Power (IOKit power sources)

nonisolated enum AutomationPowerReader {
    static func read() -> AutomationPowerState {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return AutomationPowerState() }
        let providing = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String?
        let list = (IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]) ?? []
        let descriptions = list.compactMap { source in
            IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any]
        }
        return parse(providingType: providing, descriptions: descriptions)
    }

    /// Pure: the state from `IOPSGetProvidingPowerSourceType` and the source descriptions.
    static func parse(providingType: String?, descriptions: [[String: Any]]) -> AutomationPowerState {
        var state = AutomationPowerState()
        switch providingType {
        case kIOPMACPowerKey: state.source = .ac
        case kIOPMBatteryPowerKey: state.source = .battery
        case kIOPMUPSPowerKey: state.source = .ups
        default: state.source = .unknown
        }
        let battery = descriptions.first { ($0[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType }
        if let battery {
            if let current = battery[kIOPSCurrentCapacityKey] as? Int {
                let maximum = battery[kIOPSMaxCapacityKey] as? Int ?? 100
                state.level = maximum > 0 ? Int((Double(current) / Double(maximum) * 100).rounded()) : current
            }
            state.isCharging = battery[kIOPSIsChargingKey] as? Bool
        }
        return state
    }

    /// Adds a run-loop source on the main run loop that calls `handler` on every power
    /// source change. Created here (nonisolated) because the C callback must not capture.
    static func observe(_ handler: @escaping @Sendable () -> Void) -> CFRunLoopSource? {
        let box = Unmanaged.passRetained(AutomationCallbackBox(handler))
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<AutomationCallbackBox>.fromOpaque(context).takeUnretainedValue().handler()
        }, box.toOpaque())?.takeRetainedValue() else {
            box.release()
            return nil
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        return source
    }
}

nonisolated final class AutomationCallbackBox: @unchecked Sendable {
    let handler: @Sendable () -> Void
    init(_ handler: @escaping @Sendable () -> Void) { self.handler = handler }
}

// MARK: - Wi-Fi

/// Connected or not comes from the network path of the Wi-Fi interface (no permission).
/// The network name needs Location permission; it is read only when a rule asks for it.
nonisolated final class AutomationWiFiMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private let queue = DispatchQueue(label: "com.alphapengwang.rolltop.automations.wifi")

    init(onChange: @escaping @MainActor @Sendable (Bool) -> Void) {
        monitor.pathUpdateHandler = { path in
            let connected = path.status == .satisfied
            Task { @MainActor in onChange(connected) }
        }
    }

    func start() { monitor.start(queue: queue) }
    func stop() { monitor.cancel() }

    var isConnectedNow: Bool { monitor.currentPath.status == .satisfied }

    /// The current network name. Returns nil without Location permission. Blocking: call
    /// off the main thread.
    static func readNetworkName() async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: CWWiFiClient.shared().interface()?.ssid())
            }
        }
    }
}

// Location permission: `Platform/LocationAccess.swift` (service `.location`).

// MARK: - Displays

nonisolated enum AutomationDisplayReader {
    @MainActor static func read() -> AutomationDisplaysState {
        let ids = NSScreen.screens.compactMap { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value }
        return AutomationDisplaysState(count: ids.count, builtInCount: ids.filter { CGDisplayIsBuiltin($0) != 0 }.count)
    }
}

// MARK: - System events (wake, clock, screens, frontmost app)

/// Main-queue notification observers the controller needs; removed on `stop()`.
final class AutomationSystemEvents {
    enum Event {
        case wake, clockChanged, screensChanged, frontmostChanged
    }

    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []

    func start(_ handler: @escaping @MainActor @Sendable (Event) -> Void) {
        let workspace = NSWorkspace.shared.notificationCenter
        let local = NotificationCenter.default
        let observations: [(NotificationCenter, Notification.Name, Event)] = [
            (workspace, NSWorkspace.didWakeNotification, .wake),
            (workspace, NSWorkspace.screensDidWakeNotification, .wake),
            (workspace, NSWorkspace.didActivateApplicationNotification, .frontmostChanged),
            (local, .NSSystemClockDidChange, .clockChanged),
            (local, .NSSystemTimeZoneDidChange, .clockChanged),
            (local, .NSCalendarDayChanged, .clockChanged),
            (local, NSApplication.didChangeScreenParametersNotification, .screensChanged),
        ]
        for (center, name, event) in observations {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { handler(event) }
            }
            tokens.append((center, token))
        }
    }

    func stop() {
        for (center, token) in tokens { center.removeObserver(token) }
        tokens.removeAll()
    }
}
