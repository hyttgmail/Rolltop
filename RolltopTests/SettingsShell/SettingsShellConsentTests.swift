import Foundation
import Testing
@testable import Rolltop

/// The shared `location.access` consent row (CONTRACTS.md, "Consent rows").
@MainActor
@Suite struct SettingsShellLocationConsentTests {
    @Test func statusFollowsAuthorizationAndServices() {
        typealias Row = SettingsShellLocationConsent
        #expect(Row.status(authorization: .authorized, servicesEnabled: true) == .allowed)
        #expect(Row.status(authorization: .denied, servicesEnabled: true) == .notAllowed)
        #expect(Row.status(authorization: .notDetermined, servicesEnabled: true) == .notAsked)
        if case .unavailable(let reason) = Row.status(authorization: .restricted, servicesEnabled: true) {
            #expect(!reason.isEmpty)
        } else {
            Issue.record("restricted is unavailable")
        }
        for authorization in LocationAuthorization.allCases {
            guard case .cannotAskNow(let reason) = Row.status(authorization: authorization, servicesEnabled: false) else {
                Issue.record("services off: cannot ask now (\(authorization))")
                continue
            }
            #expect(!reason.isEmpty)
        }
    }

    @Test func settingsShellRegistersTheLocationRowWithoutReadingIt() throws {
        let context = try TestContext.make()
        _ = SettingsShellFeature(context: context)
        let registry = context.services[.consents]
        let row = try #require(registry.item(id: "location.access"))
        #expect(row.settingsURL == LocationAccess.settingsURL)
        #expect(registry.status(for: "location.access") == nil, "nothing is read before the pane refreshes")
        #expect(!context.services[.location].isActive, "registering creates no location manager")
    }
}
