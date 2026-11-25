import CoreLocation
import Foundation

// Place conditions: the pure inside/outside decision with hysteresis, and the tracker that
// runs location updates only while an enabled rule needs them. Coordinates are never logged.

/// One location fix as the evaluation sees it.
nonisolated struct AutomationLocationFix: Hashable, Sendable {
    var latitude: Double
    var longitude: Double
    /// Horizontal accuracy in metres; negative means invalid.
    var accuracy: Double
    var timestamp: Date

    init(latitude: Double, longitude: Double, accuracy: Double, timestamp: Date = Date()) {
        self.latitude = latitude
        self.longitude = longitude
        self.accuracy = accuracy
        self.timestamp = timestamp
    }

    init(_ location: CLLocation) {
        self.init(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                  accuracy: location.horizontalAccuracy, timestamp: location.timestamp)
    }
}

nonisolated enum AutomationPlaceDecision {
    /// Leave only beyond radius + max(50 m, 20 % of the radius).
    static func exitDistance(radius: Double) -> Double { radius + max(50, radius * 0.2) }

    /// A fix less accurate than this (twice the radius) is ignored.
    static func maximumAccuracy(radius: Double) -> Double { radius * 2 }

    /// Great-circle distance in metres (haversine, mean Earth radius).
    static func distance(latitude1: Double, longitude1: Double, latitude2: Double, longitude2: Double) -> Double {
        let r = 6_371_008.8
        let p1 = latitude1 * .pi / 180, p2 = latitude2 * .pi / 180
        let dp = p2 - p1, dl = (longitude2 - longitude1) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * atan2(sqrt(a), sqrt(1 - a))
    }

    /// Whether the Mac is inside `place`, or nil when unknown (no fix, no coordinates, or
    /// only poor fixes so far). Enter within the radius; leave beyond `exitDistance`; in
    /// between, or for a fix that is too inaccurate, keep `previous`.
    static func isInside(previous: Bool?, fix: AutomationLocationFix?, place: AutomationPlace) -> Bool? {
        guard let fix, place.hasCoordinates, let latitude = place.latitude, let longitude = place.longitude else { return nil }
        let radius = place.effectiveRadius
        guard fix.accuracy >= 0, fix.accuracy <= maximumAccuracy(radius: radius) else { return previous }
        let d = distance(latitude1: fix.latitude, longitude1: fix.longitude, latitude2: latitude, longitude2: longitude)
        if d <= radius { return true }
        if d > exitDistance(radius: radius) { return false }
        return previous ?? false
    }

    /// The condition's value for a known inside state; nil (unknown) stays nil.
    static func holds(_ condition: AutomationPlaceCondition, inside: Bool?) -> Bool? {
        inside.map { condition.test == .at ? $0 : !$0 }
    }

    /// A coordinate typed by the user ("51.4779" or "51,4779"), or nil when it is not a
    /// number within ±`limit`.
    static func parseCoordinate(_ text: String, limit: Double) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let value = Double(cleaned), value.isFinite, abs(value) <= limit else { return nil }
        return value
    }

    /// Six decimals (about 10 cm), without trailing zeros.
    static func format(_ coordinate: Double) -> String {
        String((coordinate * 1e6).rounded() / 1e6)
    }
}

/// Runs location updates (through the shared `.location` service) only while `reconcile`
/// says a rule needs them. Never asks for access: `updates` stays silent until the user
/// allowed Location, and the fix is unknown (nil) meanwhile.
final class AutomationPlaceTracker {
    /// Distance filter for updates; below the smallest hysteresis band (50 m).
    static let minimumDistance: CLLocationDistance = 50

    private let location: any LocationProviding
    private let onFix: (AutomationLocationFix?) -> Void
    private var task: Task<Void, Never>?
    private var authorizationObserver: ChangeObserver?
    private var needed = false
    /// A simulated fix (Debug command): replaces the service while set.
    private(set) var injected: AutomationLocationFix?

    var isRunning: Bool { task != nil }

    init(location: any LocationProviding, onFix: @escaping (AutomationLocationFix?) -> Void) {
        self.location = location
        self.onFix = onFix
    }

    func reconcile(needed: Bool) {
        self.needed = needed
        if let injected {
            stopUpdates()
            onFix(injected)
            return
        }
        guard needed else {
            stopUpdates()
            onFix(nil)
            return
        }
        guard task == nil else { return }
        // Creates the manager and reads the state; no prompt. Silent until allowed.
        let stream = location.updates(minimumDistance: Self.minimumDistance)
        task = Task { [weak self] in
            for await fix in stream {
                guard let self, !Task.isCancelled, self.injected == nil else { return }
                self.onFix(AutomationLocationFix(fix))
            }
        }
        authorizationObserver = ChangeObserver(track: { [weak self] in _ = self?.location.authorization }) { [weak self] in
            guard let self, self.injected == nil, !self.location.isAuthorized else { return }
            self.onFix(nil)
        }
        if !location.isAuthorized { onFix(nil) }
    }

    func stop() { stopUpdates() }

    private func stopUpdates() {
        task?.cancel()
        task = nil
        authorizationObserver?.cancel()
        authorizationObserver = nil
    }

    #if DEBUG
    /// Feeds `fix` to the evaluation instead of the service (nil: back to the service).
    func inject(_ fix: AutomationLocationFix?) {
        injected = fix
        if fix == nil { onFix(nil) }
        reconcile(needed: needed)
    }
    #endif
}
