import CoreLocation
import Foundation
import Testing
@testable import Rolltop

// Fixed public coordinates only: Royal Observatory Greenwich.
private let greenwich = (lat: 51.4779, lon: -0.0015)
/// About `metres` north of Greenwich.
private func fix(north metres: Double, accuracy: Double = 50) -> AutomationLocationFix {
    AutomationLocationFix(latitude: greenwich.lat + metres / 111_195, longitude: greenwich.lon, accuracy: accuracy)
}
private let place = AutomationPlace(name: "Greenwich", latitude: greenwich.lat, longitude: greenwich.lon, radius: 200)

@Suite struct AutomationPlaceDecisionTests {
    @Test func hysteresisEnterLeaveAndPoorFixes() {
        typealias D = AutomationPlaceDecision
        // Unknown: no fix, or a place without coordinates.
        #expect(D.isInside(previous: nil, fix: nil, place: place) == nil)
        #expect(D.isInside(previous: true, fix: fix(north: 0), place: AutomationPlace(name: "x")) == nil)
        // Inside, and the band (200…250 m) keeps the previous state.
        #expect(D.isInside(previous: nil, fix: fix(north: 150), place: place) == true)
        #expect(D.isInside(previous: true, fix: fix(north: 230), place: place) == true)
        #expect(D.isInside(previous: false, fix: fix(north: 230), place: place) == false)
        #expect(D.isInside(previous: nil, fix: fix(north: 230), place: place) == false)
        // Leaving beyond radius + 50 m, re-entering within the radius.
        #expect(D.isInside(previous: true, fix: fix(north: 260), place: place) == false)
        #expect(D.isInside(previous: false, fix: fix(north: 190), place: place) == true)
        // 20 % margin for large radii: 1000 m leaves beyond 1200 m.
        let large = AutomationPlace(name: "L", latitude: greenwich.lat, longitude: greenwich.lon, radius: 1000)
        #expect(D.isInside(previous: true, fix: fix(north: 1150), place: large) == true)
        #expect(D.isInside(previous: true, fix: fix(north: 1250), place: large) == false)
        // A fix worse than twice the radius is ignored (keeps previous, unknown stays unknown).
        #expect(D.isInside(previous: true, fix: fix(north: 2000, accuracy: 500), place: place) == true)
        #expect(D.isInside(previous: nil, fix: fix(north: 0, accuracy: 500), place: place) == nil)
        #expect(D.isInside(previous: nil, fix: fix(north: 0, accuracy: -1), place: place) == nil)
    }

    @Test func evaluationAtAwayAndUnknown() {
        let at = AutomationCondition(id: "at", .place(.init(test: .at, place: place)))
        let away = AutomationCondition(id: "away", .place(.init(test: .awayFrom, place: place)))
        var environment = AutomationEnvironment()
        // Unknown location: neither form holds.
        #expect(!AutomationEvaluator.evaluate(at, in: environment))
        #expect(!AutomationEvaluator.evaluate(away, in: environment))
        environment.location = fix(north: 0)
        #expect(AutomationEvaluator.evaluate(at, in: environment))
        #expect(!AutomationEvaluator.evaluate(away, in: environment))
        environment.location = fix(north: 1000)
        #expect(!AutomationEvaluator.evaluate(at, in: environment))
        #expect(AutomationEvaluator.evaluate(away, in: environment))
        #expect(AutomationPlaceDecision.parseCoordinate("51,4779", limit: 90) == 51.4779)
        #expect(AutomationPlaceDecision.parseCoordinate("91", limit: 90) == nil)
    }

    @Test func placeConditionRoundTripsThroughJSON() throws {
        let rule = AutomationRule(id: "r", name: "At Greenwich",
                                  conditions: [AutomationCondition(id: "c", .place(.init(test: .awayFrom, place: place)))],
                                  actions: AutomationActions(showItems: [.app("com.alphapengwang.rolltop-fixture")]))
        let data = try JSONEncoder().encode(AutomationRuleList(rules: [rule]))
        let decoded = try JSONDecoder().decode(AutomationRuleList.self, from: data)
        #expect(decoded.rules == [rule])
        // An incomplete place (no coordinates yet) decodes with the default radius.
        let partial = #"{"id":"c","type":"place","parameters":{"test":"at","place":{"name":"Home"}}}"#
        let condition = try JSONDecoder().decode(AutomationCondition.self, from: Data(partial.utf8))
        #expect(condition.kind == .place(.init(test: .at, place: AutomationPlace(name: "Home"))))
    }
}

@MainActor
@Suite struct AutomationPlaceTrackerTests {
    private final class FakeLocation: LocationProviding {
        var authorization: LocationAuthorization
        var servicesEnabled = true
        var isActive = false
        var requests = 0
        var streams = 0
        var continuation: AsyncStream<CLLocation>.Continuation?
        init(_ authorization: LocationAuthorization) { self.authorization = authorization }
        func activate() { isActive = true }
        func requestAuthorization() { requests += 1 }
        func currentLocation() async throws -> CLLocation { throw LocationAccessError.notAuthorized }
        func updates(minimumDistance: CLLocationDistance) -> AsyncStream<CLLocation> {
            streams += 1
            return AsyncStream { self.continuation = $0 }
        }
    }

    @Test func updatesRunOnlyWhileNeededAndNeverPrompt() async {
        let fake = FakeLocation(.notDetermined)
        var fixes: [AutomationLocationFix?] = []
        let tracker = AutomationPlaceTracker(location: fake) { fixes.append($0) }
        tracker.reconcile(needed: false)
        #expect(fake.streams == 0 && !tracker.isRunning)
        // Needed but not allowed: a silent stream, unknown location, no prompt.
        tracker.reconcile(needed: true)
        tracker.reconcile(needed: true)
        #expect(fake.streams == 1 && tracker.isRunning)
        #expect(fixes.last == .some(nil))
        #expect(fake.requests == 0)
        // Allowed later: fixes flow to the evaluation.
        fake.authorization = .authorized
        fake.continuation?.yield(CLLocation(latitude: greenwich.lat, longitude: greenwich.lon))
        for _ in 0..<50 where fixes.compactMap({ $0 }).isEmpty { await Task.yield() }
        #expect(fixes.compactMap { $0 }.first?.latitude == greenwich.lat)
        // The last place rule disabled: updates stop.
        tracker.reconcile(needed: false)
        #expect(!tracker.isRunning)
        #expect(fake.requests == 0)
    }
}
