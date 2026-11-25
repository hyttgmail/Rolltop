import AppKit
import Foundation
import RolltopCore
import Testing
@testable import Rolltop

/// One transient surface at a time, both ways (docs/CONTRACTS.md, "Transient surfaces").
@MainActor
@Suite struct SurfaceCoordinatorTests {
    private func coordinator(front: NSRunningApplication?, active: Bool = true) -> (TransientSurfaceCoordinator, () -> [String]) {
        let coordinator = TransientSurfaceCoordinator()
        var activated: [String] = []
        coordinator.frontmostApplication = { front }
        coordinator.isRolltopActive = { active }
        coordinator.activate = { activated.append($0.bundleIdentifier ?? "?") }
        return (coordinator, { activated })
    }

    private var otherApp: NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && $0.bundleIdentifier != nil }
    }

    @Test func secondSurfaceClosesTheFirstWhicheverOrder() {
        for (first, second) in [("palette", "shelf"), ("shelf", "palette"), ("secondary-bar", "palette"), ("palette", "secondary-bar"),
                                ("shelf", "custom-items.group"), ("custom-items.group", "secondary-bar")] {
            let (surfaces, _) = coordinator(front: nil)
            var closed: [String] = []
            surfaces.willPresent(first) { by in closed.append("\(first) for \(by)"); surfaces.didDismiss(first, restoreFocus: true) }
            surfaces.willPresent(second) { _ in closed.append(second) }
            #expect(closed == ["\(first) for \(second)"])
            #expect(surfaces.current == second)
            surfaces.didDismiss(second, restoreFocus: false)
            #expect(surfaces.current == nil)
        }
    }

    @Test func keyboardGoesBackOnceWhenTheLastSurfaceCloses() throws {
        let other = try #require(otherApp)
        let (surfaces, activated) = coordinator(front: other)
        surfaces.willPresent("palette") { _ in surfaces.didDismiss("palette", restoreFocus: true) }
        // A surface that takes over never hands the keyboard back, and keeps the app to return to.
        surfaces.willPresent("secondary-bar") { _ in }
        #expect(activated().isEmpty)
        #expect(surfaces.previousApp == other)
        surfaces.didDismiss("secondary-bar", restoreFocus: true)
        #expect(activated() == [other.bundleIdentifier ?? "?"])
        #expect(surfaces.previousApp == nil)
    }

    @Test func lateOrForeignDismissalsAreIgnored() throws {
        let other = try #require(otherApp)
        let (surfaces, activated) = coordinator(front: other)
        surfaces.willPresent("shelf") { _ in }   // never reports back
        surfaces.willPresent("palette") { _ in }
        #expect(surfaces.current == "palette", "a surface that does not report back is forgotten")
        surfaces.didDismiss("shelf", restoreFocus: true)
        #expect(surfaces.current == "palette")
        #expect(activated().isEmpty)
        surfaces.didDismiss("palette", restoreFocus: false)
        #expect(activated().isEmpty, "a click elsewhere keeps the app the user chose")
    }

    @Test func rolltopItselfIsNeverThePreviousApp() {
        // Rolltop's Settings window was frontmost: closing the surface by Escape activates nothing.
        let (surfaces, activated) = coordinator(front: NSRunningApplication.current)
        surfaces.willPresent("palette") { _ in }
        #expect(surfaces.previousApp == nil)
        surfaces.didDismiss("palette", restoreFocus: true)
        #expect(activated().isEmpty)
    }

    @Test func nothingIsActivatedWhileRolltopIsNotActive() throws {
        // The Rolltop Bar or the Shelf opened by a click never took the keyboard: Escape (a
        // global monitor) closes it and the frontmost app simply keeps the keyboard.
        let other = try #require(otherApp)
        let (surfaces, activated) = coordinator(front: other, active: false)
        surfaces.willPresent("secondary-bar") { _ in }
        surfaces.didDismiss("secondary-bar", restoreFocus: true)
        #expect(activated().isEmpty)
        #expect(surfaces.previousApp == nil)
    }
}

/// A presenter with the real one's ownership rules, without a window.
@MainActor
final class SurfaceTestPresenter: ItemPanelPresenting {
    private(set) var isPanelVisible = false
    private(set) var currentOpener: String?
    private var request: ItemPanelRequest?
    private(set) var presented: [String] = []

    func presentPanel(owners: [OwnerID], anchor: PanelAnchor, request: ItemPanelRequest) {
        let previous = isPanelVisible ? self.request : nil
        self.request = request
        currentOpener = request.opener
        isPanelVisible = true
        presented.append(request.opener + ":" + (request.gesture?.rawValue ?? "inferred"))
        if let previous, previous.opener != request.opener { previous.onDismiss?(.takenOver(by: request.opener)) }
    }

    func dismissPanel() {
        guard isPanelVisible else { return }
        let request = self.request
        isPanelVisible = false
        currentOpener = nil
        self.request = nil
        request?.onDismiss?(.closed)
    }

    func dismissPanel(opener: String) {
        if currentOpener == opener { dismissPanel() }
    }
}

/// Groups on the item panel contract: who opened it, how, and the callback that replaced
/// polling `isPanelVisible`.
@MainActor
@Suite struct GroupPanelOwnershipTests {
    private func make() throws -> (CustomItemsPanelAdapter, SurfaceTestPresenter, () -> [String]) {
        let context = try TestContext.make()
        let presenter = SurfaceTestPresenter()
        context.services.register(presenter as any ItemPanelPresenting, for: .itemPanel)
        let adapter = CustomItemsPanelAdapter(context: context)
        var closed: [String] = []
        adapter.onClosed = { closed.append($0) }
        return (adapter, presenter, { closed })
    }

    @Test func eachGroupIsItsOwnOpenerWithItsGesture() throws {
        let (adapter, presenter, closed) = try make()
        adapter.present(group: "g1", owners: [.app("com.example.A")], anchor: .statusItem, gesture: .click)
        adapter.present(group: "g2", owners: [.app("com.example.B")], anchor: .statusItem, gesture: .hover)
        #expect(presenter.presented == ["custom-items.group.g1:click", "custom-items.group.g2:hover"])
        #expect(closed() == ["g1"], "the first group hears it went away exactly once")
        #expect(adapter.visibleGroup == "g2")
    }

    @Test func revealTakingThePanelOverClosesTheGroup() throws {
        let (adapter, presenter, closed) = try make()
        adapter.present(group: "g1", owners: [.app("com.example.A")], anchor: .statusItem, gesture: .click)
        presenter.presentPanel(owners: [], anchor: .statusItem, request: ItemPanelRequest(opener: ItemPanelRequest.revealOpener))
        #expect(closed() == ["g1"])
        #expect(adapter.visibleGroup == nil)
        #expect(adapter.lastDismissal == "taken over by reveal")
        // A displaced group never closes its successor's panel.
        adapter.dismiss()
        #expect(presenter.isPanelVisible)
        #expect(presenter.currentOpener == ItemPanelRequest.revealOpener)
    }

    @Test func dismissingTheGroupReportsOnce() throws {
        let (adapter, presenter, closed) = try make()
        adapter.present(group: "g1", owners: [.app("com.example.A")], anchor: .statusItem, gesture: .keyboard)
        adapter.dismiss()
        adapter.dismiss()
        #expect(!presenter.isPanelVisible)
        #expect(closed() == ["g1"])
    }
}
