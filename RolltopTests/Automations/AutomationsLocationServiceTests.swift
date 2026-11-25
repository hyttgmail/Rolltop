import CoreLocation
import Foundation
import Testing
@testable import Rolltop

/// Automations reads Location through the shared `.location` service (Platform), so tests
/// and other features see the same state.
@MainActor
@Suite struct AutomationsLocationServiceTests {
    private final class FakeLocation: LocationProviding {
        var authorization: LocationAuthorization = .authorized
        var servicesEnabled = true
        var isActive = false
        func activate() { isActive = true }
        func requestAuthorization() {}
        func currentLocation() async throws -> CLLocation { CLLocation(latitude: 51.4779, longitude: -0.0015) }
        func updates(minimumDistance: CLLocationDistance) -> AsyncStream<CLLocation> { AsyncStream { $0.finish() } }
    }

    @Test func featureUsesTheSharedLocationService() throws {
        let context = try TestContext.make()
        let fake = FakeLocation()
        context.services.register(fake as any LocationProviding, for: .location)
        let feature = AutomationsFeature(context: context)
        #expect(feature.location === fake)
        #expect(feature.location.isAuthorized)
        #expect(!fake.isActive, "nothing activates Location before a rule needs it")
    }
}
