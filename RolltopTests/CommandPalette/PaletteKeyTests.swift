import AppKit
import Foundation
import RolltopCore
import Testing
@testable import Rolltop

@Suite struct PaletteKeyMappingTests {
    private func action(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags = [], _ characters: String? = nil,
                        marked: Bool = false) -> PaletteKeys.Action? {
        PaletteKeys.action(keyCode: code, modifiers: modifiers, characters: characters, hasMarkedText: marked)
    }

    @Test func navigationAndRunning() {
        #expect(action(125) == .move(1))
        #expect(action(126) == .move(-1))
        #expect(action(45, .control, "n") == .move(1))
        #expect(action(35, .control, "p") == .move(-1))
        #expect(action(36) == .runSelected(.left))
        #expect(action(76) == .runSelected(.left))
        #expect(action(36, .shift) == .runSelected(.right))
        #expect(action(36, .control) == .runSelected(.right))
        #expect(action(53) == .close)
        #expect(action(13, .command, "w") == .close)
        #expect(action(121) == .move(8))
    }

    @Test func commandDigitsRunTheFirstNineRows() {
        let codes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        for (index, code) in codes.enumerated() {
            #expect(action(code, .command, "\(index + 1)") == .runIndex(index))
        }
        // ⌥⌘1 is not ⌘1.
        #expect(action(18, [.command, .option], "1") == nil)
    }

    @Test func textAndEditingKeysGoToTheField() {
        #expect(action(0, [], "a") == nil)
        #expect(action(45, [], "n") == nil)          // plain n types
        #expect(action(9, .command, "v") == nil)     // paste through the Edit menu
        #expect(action(0, .command, "a") == nil)
        #expect(action(12, .command, "q") == .swallow)   // never quits Rolltop from the panel
        #expect(action(43, .command, ",") == .swallow)
        #expect(action(48) == .swallow)              // Tab keeps the focus in the field
    }

    @Test func commandReturnAsksForTheSecondAction() {
        #expect(action(36, .command, "\r") == .runSelectedSecond)
        #expect(action(76, .command, "\r") == .runSelectedSecond)
        // Other combinations with ⌘ keep running the row itself.
        #expect(action(36, [.command, .shift], "\r") == .runSelected(.left))
    }

    @Test func inputMethodsKeepTheirKeys() {
        // While Pinyin is composing, Return commits and arrows pick candidates.
        #expect(action(36, marked: true) == nil)
        #expect(action(125, marked: true) == nil)
        #expect(action(53, marked: true) == nil)
        #expect(action(18, .command, "1", marked: true) == nil)
    }
}

/// Real `NSEvent`s handed straight to the panel (`sendEvent` and `performKeyEquivalent`),
/// the path a key press takes. The panel is never put on screen and nothing is posted.
@Suite struct PaletteKeyEventTests {
    private func makeController() throws -> (PaletteController, AppContext) {
        let context = try TestContext.make()
        let controller = PaletteController(context: context)
        controller.presentsOnScreen = false
        controller.show()
        controller.setQuery("show")
        return (controller, context)
    }

    private func event(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags = [], _ characters: String = "",
                       window: NSWindow?) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                      windowNumber: window?.windowNumber ?? 0, context: nil, characters: characters,
                                      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    @Test func arrowsAndControlKeysMoveTheSelection() throws {
        let (controller, _) = try makeController()
        let panel = try #require(controller.panel)
        #expect(controller.isVisible)
        #expect(controller.model.results.count >= 2)
        #expect(controller.model.selected == 0)
        panel.sendEvent(try event(125, window: panel))
        #expect(controller.model.selected == 1)
        panel.sendEvent(try event(35, .control, "p", window: panel))
        #expect(controller.model.selected == 0)
        panel.sendEvent(try event(126, window: panel))   // stops at the top
        #expect(controller.model.selected == 0)
        panel.sendEvent(try event(45, .control, "n", window: panel))
        #expect(controller.model.selected == 1)
    }

    @Test func returnRunsTheSelectionAndShiftReturnRightClicks() throws {
        let (controller, _) = try makeController()
        let panel = try #require(controller.panel)
        var runs: [(String, PaletteClick)] = []
        controller.runOverride = { row, click in runs.append((row.id, click)) }
        panel.sendEvent(try event(125, window: panel))
        panel.sendEvent(try event(36, [], "\r", window: panel))
        panel.sendEvent(try event(36, .shift, "\r", window: panel))
        #expect(runs.count == 2)
        #expect(runs.first?.0 == controller.model.results[1].id)
        #expect(runs.first?.1 == .left)
        #expect(runs.last?.1 == .right)
    }

    @Test func commandDigitsRunThroughKeyEquivalents() throws {
        let (controller, _) = try makeController()
        let panel = try #require(controller.panel)
        var runs: [String] = []
        controller.runOverride = { row, _ in runs.append(row.id) }
        #expect(panel.performKeyEquivalent(with: try event(19, .command, "2", window: panel)))
        #expect(runs == [controller.model.results[1].id])
        // ⌘Q is swallowed while the panel is open; ⌘V goes on to the Edit menu.
        #expect(panel.performKeyEquivalent(with: try event(12, .command, "q", window: panel)))
        #expect(controller.isVisible)
        #expect(!controller.handleKey(try event(9, .command, "v", window: panel)))
    }

    @Test func escapeCloses() throws {
        let (controller, _) = try makeController()
        let panel = try #require(controller.panel)
        panel.sendEvent(try event(53, [], "\u{1b}", window: panel))
        #expect(!controller.isVisible)
        #expect(controller.lastCloseReason == .escape)
        // Showing again opens the same panel, not a second one.
        controller.show()
        controller.show()
        #expect(controller.panel === panel)
        #expect(controller.showCount == 2)
    }

    @Test func runningRecordsUsageAndRanksItHigher() throws {
        let (controller, context) = try makeController()
        let titles = controller.model.results.map(\.title)
        #expect(titles.contains("Show Hidden Items"))
        #expect(titles.contains("Show All Items"))
        let usage = PaletteUsageStore(settings: context.settings)
        // Same tier and type: usage decides.
        let all = try #require(controller.model.results.first { $0.title == "Show All Items" })
        let hidden = try #require(controller.model.results.first { $0.title == "Show Hidden Items" })
        usage.record(all.id)
        controller.setQuery("show")
        let order = controller.model.results.map(\.id)
        #expect(try #require(order.firstIndex(of: all.id)) < #require(order.firstIndex(of: hidden.id)))
        // Before anything is typed, the recently used row is listed.
        controller.setQuery("")
        #expect(controller.model.results.first?.id == all.id)
        usage.clear()
    }

    @Test func providerRowsAppearAndRun() async throws {
        let (controller, context) = try makeController()
        let provider = PaletteTestProvider()
        context.services[.paletteResultProviders].register(provider)
        controller.setQuery("fixture")
        let index = try #require(controller.model.results.firstIndex { $0.id == "provider:test.clipboard:1" })
        controller.run(index, click: .left)
        #expect(!controller.isVisible)   // closes after running by default
        for _ in 0..<50 where provider.ran == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(provider.ran == 1)
        PaletteUsageStore(settings: context.settings).clear()
    }

    @Test func commandReturnRunsTheSecondActionWhereThereIsOne() async throws {
        let (controller, context) = try makeController()
        let panel = try #require(controller.panel)
        let provider = PaletteDebugSampleProvider()
        context.services[.paletteResultProviders].register(provider)
        defer { PaletteUsageStore(settings: context.settings).clear() }

        controller.setQuery("sample")
        controller.model.select(try #require(controller.model.results.firstIndex { $0.id.hasSuffix(":with") }))
        #expect(controller.model.secondActionTitle == "Paste")   // the footer's "⌘↩ Paste"
        panel.sendEvent(try event(36, .command, "\r", window: panel))
        #expect(!controller.isVisible)
        for _ in 0..<50 where provider.secondRuns == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(provider.secondRuns == 1)
        #expect(provider.mainRuns == 0)

        // Without a second action, ⌘Return does what Return does, and the footer names nothing.
        controller.show()
        controller.setQuery("sample")
        controller.model.select(try #require(controller.model.results.firstIndex { $0.id.hasSuffix(":without") }))
        #expect(controller.model.secondActionTitle == nil)
        panel.sendEvent(try event(36, .command, "\r", window: panel))
        for _ in 0..<50 where provider.mainRuns == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(provider.mainRuns == 1)
        #expect(provider.secondRuns == 1)
    }
}

@Suite struct PaletteMessageTests {
    @Test func failedRunsSayWhatHappened() {
        #expect(PaletteController.message(for: ItemActivator.ActivationError.accessibilityDenied, title: "Wi-Fi")
            == "Rolltop needs Device Control and Data Access to open menu bar items.")
        #expect(PaletteController.message(for: ItemActivator.ActivationError.notDrawn(.system(.wifi)), title: "Wi-Fi")
            == "Wi-Fi did not appear in the menu bar. There may be no room for it.")
        #expect(PaletteController.message(for: CancellationError(), title: "Wi-Fi") == nil)
        #expect(PaletteController.message(for: CommandError.unavailable("demo.x"), title: "Demo")
            == "Demo failed: The command “demo.x” isn’t available right now.")
    }
}
