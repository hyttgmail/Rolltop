import Foundation
import RolltopCore
import Testing
@testable import Rolltop

/// Stands in for MBAssessmentModeAssertion: records invalidation.
final class FakeAssertionObject: NSObject {
    private(set) var invalidated = false
    @objc func invalidate() { invalidated = true }
}

/// Never answers unless told to.
final class FakeRestriction: MenuBarRestricting {
    var isAvailable = true
    var autoComplete = false
    private(set) var objects: [FakeAssertionObject] = []
    private var completions: [@MainActor (Error?) -> Void] = []

    func activate(systemIDs: [Int], bundleIDs: [String],
                  completion: @escaping @MainActor (Error?) -> Void) -> RestrictionAssertion? {
        let object = FakeAssertionObject()
        objects.append(object)
        completions.append(completion)
        if autoComplete { completion(nil) }
        return RestrictionAssertion(raw: object, serial: objects.count)
    }

    func completeLast(error: Error? = nil) { completions.last?(error) }
}

@Suite struct VisibilityEngineTests {
    private let fixture = OwnerID.app("com.example.fixture")

    private func makeEngine(_ restriction: FakeRestriction) throws -> VisibilityEngine {
        let suite = "com.alphapengwang.rolltop.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = SettingsStore(defaults: defaults)
        let layout = LayoutStore(settings: settings)
        layout.setSection(.hidden, for: fixture)
        let catalog = ItemCatalog(layoutStore: layout, settings: settings, permissions: Permissions(), ownBundleIDs: ["com.alphapengwang.rolltop"])
        catalog.setPresenceForTesting(present: [fixture], known: [fixture.bundleID!, "com.example.other"])
        return VisibilityEngine(restriction: restriction, layoutStore: layout, catalog: catalog,
                                settings: settings, ownBundleIDs: ["com.alphapengwang.rolltop"])
    }

    @Test func supersededActivationThatNeverAnswersIsInvalidated() throws {
        let restriction = FakeRestriction()
        let engine = try makeEngine(restriction)
        engine.updateNow()
        #expect(restriction.objects.count == 1)
        #expect(engine.isApplying)
        engine.show(.hiddenRevealed)
        engine.updateNow()
        #expect(restriction.objects[0].invalidated)
        #expect(!engine.isRestrictionHeld)
        #expect(!engine.isApplying)
    }

    @Test func watchdogFailsOpenAndInvalidates() async throws {
        let restriction = FakeRestriction()
        let engine = try makeEngine(restriction)
        engine.activationTimeout = .milliseconds(50)
        engine.updateNow()
        try await Task.sleep(for: .milliseconds(300))
        #expect(restriction.objects[0].invalidated)
        #expect(!engine.isRestrictionHeld)
        #expect(engine.lastError == "Activation timed out")
    }

    @Test func newAssertionReplacesOldOnlyAfterSuccess() throws {
        let restriction = FakeRestriction()
        let engine = try makeEngine(restriction)
        engine.updateNow()
        restriction.completeLast()
        #expect(engine.isRestrictionHeld)
        let first = restriction.objects[0]
        engine.setForcedVisible([.app("com.example.other")], source: "test")   // same plan: no new activation
        engine.updateNow()
        #expect(restriction.objects.count == 1)
        engine.setConcealShown(true)
        engine.updateNow()
        #expect(restriction.objects.count == 2)
        #expect(!first.invalidated)            // still held while the new one is in flight
        restriction.completeLast()
        #expect(first.invalidated)
        #expect(!restriction.objects[1].invalidated)
        #expect(engine.isRestrictionHeld)
    }

    @Test func activationErrorFailsOpen() throws {
        let restriction = FakeRestriction()
        let engine = try makeEngine(restriction)
        engine.updateNow()
        restriction.completeLast(error: CommandError.failed("boom"))
        #expect(!engine.isRestrictionHeld)
        #expect(restriction.objects[0].invalidated)
        #expect(engine.lastError?.contains("boom") == true)
    }
}
