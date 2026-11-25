import CoreLocation
import Foundation
import Observation

/// Location authorization for Rolltop, as macOS reports it.
nonisolated enum LocationAuthorization: String, Sendable, CaseIterable {
    case notDetermined = "not-determined"
    case denied
    case restricted
    case authorized

    init(_ status: CLAuthorizationStatus) {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse: self = .authorized
        case .denied: self = .denied
        case .restricted: self = .restricted
        case .notDetermined: self = .notDetermined
        @unknown default: self = .denied
        }
    }
}

/// Why `currentLocation()` gave no fix. Messages are short and localized.
nonisolated enum LocationAccessError: Error, Equatable, LocalizedError {
    /// Not authorized (never asked, refused or restricted). Nothing was asked.
    case notAuthorized
    /// Location Services are off for the whole Mac.
    case servicesOff
    case timedOut
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized: String(localized: "Rolltop isn’t allowed to use your location.", table: "UI")
        case .servicesOff: String(localized: "Location Services are turned off.", table: "UI")
        case .timedOut: String(localized: "Your location couldn’t be found in time.", table: "UI")
        case .failed: String(localized: "Your location couldn’t be found.", table: "UI")
        }
    }
}

/// The one shared wrapper around `CLLocationManager` (service `.location`). Used by
/// Automations (Wi-Fi network names, place conditions) and Weather (current location).
///
/// Rules:
/// - Reading `authorization`, `servicesEnabled` or `isActive` never prompts.
/// - `requestAuthorization()` is the only member that may show the system prompt; call it
///   only from the user's click (the `location.access` consent row, or a feature's own
///   "Allow…" button).
/// - `currentLocation()` and `updates(minimumDistance:)` never ask: without authorization
///   they throw or wait.
/// - Never log a coordinate and never store one in settings from this API's callers
///   without the user choosing it (a place the user saved is theirs to store).
protocol LocationProviding: AnyObject {
    /// `.notDetermined` until `activate()` has read the real state. Observable.
    var authorization: LocationAuthorization { get }
    /// Location Services are on for the Mac (read off the main thread, cached; true until
    /// the first read). Observable.
    var servicesEnabled: Bool { get }
    /// `activate()` has run: `authorization` is the real state.
    var isActive: Bool { get }
    /// Creates the location manager (no prompt) so `authorization` follows the system.
    /// Idempotent; cheap after the first call.
    func activate()
    /// Shows the system prompt when the state is `.notDetermined`; no-op otherwise. Only
    /// from a user click.
    func requestAuthorization()
    /// One fix at about 100 m accuracy (or the last one while `updates` are running).
    /// Throws `LocationAccessError` when not authorized, when Location Services are off,
    /// or after 20 s without a fix. Never prompts.
    func currentLocation() async throws -> CLLocation
    /// Locations at low accuracy (about 100 m) whenever the Mac moved at least
    /// `minimumDistance` metres since the last one this stream yielded; the first fix
    /// comes as soon as updates run. Updates run only while at least one stream exists
    /// (from this call until its iterating task is cancelled or the stream is released)
    /// *and* Rolltop is authorized and Location Services are on; while not authorized the
    /// stream stays open and yields nothing (it starts on its own when the user allows
    /// access later). Calling this creates the manager (no prompt). Several streams share
    /// one manager whose distance filter is the smallest requested distance. Cancel the
    /// iterating task to end a stream; updates stop when the last one ends.
    func updates(minimumDistance: CLLocationDistance) -> AsyncStream<CLLocation>
}

extension LocationProviding {
    var isAuthorized: Bool { authorization == .authorized }
}

/// `LocationProviding` on `CLLocationManager`. The manager is created lazily by
/// `activate()`, so resolving the service (and the unit-test host) creates nothing.
@Observable
final class LocationAccess: NSObject, LocationProviding, CLLocationManagerDelegate {
    /// Privacy & Security › Location Services.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!
    static let fixTimeout: Duration = .seconds(20)

    private(set) var authorization: LocationAuthorization = .notDetermined
    private(set) var servicesEnabled = true
    private(set) var isActive = false

    @ObservationIgnored private var manager: CLLocationManager?
    @ObservationIgnored private var pendingFixes: [UUID: CheckedContinuation<CLLocation, any Error>] = [:]
    @ObservationIgnored private var listeners: [UUID: Listener] = [:]
    @ObservationIgnored private var isUpdating = false
    private let log = Log.logger("location")

    private struct Listener {
        var minimumDistance: CLLocationDistance
        var continuation: AsyncStream<CLLocation>.Continuation
        var lastYielded: CLLocation?
    }

    func activate() {
        guard manager == nil else { return }
        let manager = CLLocationManager()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        self.manager = manager
        isActive = true
        authorization = LocationAuthorization(manager.authorizationStatus)
        refreshServicesEnabled()
    }

    func requestAuthorization() {
        activate()
        guard let manager, authorization == .notDetermined else { return }
        log.notice("asking for Location access (user click)")
        manager.requestWhenInUseAuthorization()
    }

    func currentLocation() async throws -> CLLocation {
        activate()
        guard servicesEnabled else { throw LocationAccessError.servicesOff }
        guard authorization == .authorized, let manager else { throw LocationAccessError.notAuthorized }
        if isUpdating, let last = manager.location { return last }
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            pendingFixes[id] = continuation
            // `requestLocation` while continuous updates run is not needed: the next update
            // resolves every pending fix.
            if pendingFixes.count == 1, !isUpdating { manager.requestLocation() }
            Task { [weak self] in
                try? await Task.sleep(for: Self.fixTimeout)
                self?.pendingFixes.removeValue(forKey: id)?.resume(throwing: LocationAccessError.timedOut)
            }
        }
    }

    func updates(minimumDistance: CLLocationDistance) -> AsyncStream<CLLocation> {
        // Read the real authorization first (no prompt), or a fresh launch never starts.
        activate()
        let id = UUID()
        return AsyncStream { continuation in
            listeners[id] = Listener(minimumDistance: max(0, minimumDistance), continuation: continuation)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.removeListener(id) }
            }
            updateStreaming()
        }
    }

    private func removeListener(_ id: UUID) {
        listeners[id] = nil
        updateStreaming()
    }

    /// Starts or stops continuous updates: only with listeners, authorization and services.
    private func updateStreaming() {
        let shouldRun = !listeners.isEmpty && authorization == .authorized && servicesEnabled
        if shouldRun {
            activate()
            guard let manager else { return }
            manager.distanceFilter = listeners.values.map(\.minimumDistance).min() ?? kCLDistanceFilterNone
            if !isUpdating {
                isUpdating = true
                manager.startUpdatingLocation()
                log.info("location updates started for \(listeners.count) listener(s)")
            }
        } else if isUpdating {
            isUpdating = false
            manager?.stopUpdatingLocation()
            log.info("location updates stopped")
        }
    }

    /// `CLLocationManager.locationServicesEnabled()` can block: read it off the main thread.
    private func refreshServicesEnabled() {
        Task { [weak self] in
            let enabled = await Self.readServicesEnabled()
            guard let self, enabled != self.servicesEnabled else { return }
            self.servicesEnabled = enabled
            self.updateStreaming()
        }
    }

    nonisolated private static func readServicesEnabled() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: CLLocationManager.locationServicesEnabled())
            }
        }
    }

    // MARK: CLLocationManagerDelegate (called on the main run loop: the manager is created there)

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            let next = LocationAuthorization(status)
            if next != authorization { authorization = next }
            refreshServicesEnabled()
            updateStreaming()
            if next != .authorized { failPendingFixes(.notAuthorized) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        MainActor.assumeIsolated { deliver(location) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        let code = (error as? CLError)?.code
        let message = String(describing: code.map(\.rawValue) ?? -1)
        MainActor.assumeIsolated {
            // `locationUnknown` is transient: continuous updates keep trying; a one-shot
            // request reports it as a failure.
            log.error("location fix failed (CLError \(message))")
            failPendingFixes(code == .denied ? .notAuthorized : .failed(message))
        }
    }

    private func deliver(_ location: CLLocation) {
        let fixes = pendingFixes
        pendingFixes.removeAll()
        for continuation in fixes.values { continuation.resume(returning: location) }
        for (id, listener) in listeners {
            if let last = listener.lastYielded, location.distance(from: last) < listener.minimumDistance { continue }
            listeners[id]?.lastYielded = location
            listener.continuation.yield(location)
        }
    }

    private func failPendingFixes(_ error: LocationAccessError) {
        let fixes = pendingFixes
        pendingFixes.removeAll()
        for continuation in fixes.values { continuation.resume(throwing: error) }
    }
}

extension ServiceKey where Service == any LocationProviding {
    /// The shared location wrapper. Nobody replaces it in the app; tests may register a
    /// fake before features are created. Features may keep the resolved instance.
    static var location: Self { .init("location") { _ in LocationAccess() } }
}
