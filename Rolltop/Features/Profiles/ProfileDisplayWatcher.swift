import AppKit
import ColorSync
import CoreGraphics

/// Reads the connected displays with stable ids and follows changes of the set.
///
/// Fires only when the set of display ids changes (not on resolution or arrangement
/// changes), after the configuration has been stable for a moment, so a profile is never
/// re-applied over the user's edits by an unrelated screen-parameters notification.
final class ProfileDisplayWatcher {
    private var observer: NSObjectProtocol?
    private var pending: Task<Void, Never>?
    private(set) var lastIDs: Set<String>
    private let onChange: (ProfileDisplayConfiguration) -> Void
    private let settleDelay: Duration

    init(settleDelay: Duration = .seconds(1), onChange: @escaping (ProfileDisplayConfiguration) -> Void) {
        self.onChange = onChange
        self.settleDelay = settleDelay
        self.lastIDs = Self.current().ids
    }

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleCheck() }
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        pending?.cancel()
    }

    private func scheduleCheck() {
        pending?.cancel()
        let delay = settleDelay
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            let configuration = Self.current()
            guard configuration.ids != self.lastIDs else { return }
            self.lastIDs = configuration.ids
            self.onChange(configuration)
        }
    }

    /// The active displays, in `NSScreen` order.
    static func current() -> ProfileDisplayConfiguration {
        let displays = NSScreen.screens.compactMap { screen -> ProfileDisplay? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let displayID = CGDirectDisplayID(number.uint32Value)
            return ProfileDisplay(id: stableID(of: displayID), name: screen.localizedName,
                                  isBuiltIn: CGDisplayIsBuiltin(displayID) != 0)
        }
        return ProfileDisplayConfiguration(displays: displays)
    }

    /// ColorSync's per-display UUID (stable across reconnects and reboots), else
    /// vendor-model-serial.
    static func stableID(of displayID: CGDirectDisplayID) -> String {
        if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
           let string = CFUUIDCreateString(nil, uuid) as String? {
            return string
        }
        return "\(CGDisplayVendorNumber(displayID))-\(CGDisplayModelNumber(displayID))-\(CGDisplaySerialNumber(displayID))"
    }
}
