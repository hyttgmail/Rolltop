import AppKit
import Foundation
import RolltopCore
import SwiftUI
import Testing
@testable import Rolltop

@Suite struct PaletteCommandExpansionTests {
    private typealias Argument = PaletteCommandDescriptor.Argument

    private func descriptor(_ id: CommandID, _ arguments: [Argument] = [], available: Bool = true) -> PaletteCommandDescriptor {
        PaletteCommandDescriptor(id: id, arguments: arguments, isAvailable: available)
    }

    @Test func commandsWithoutRequiredArgumentsGiveOneRow() {
        let rows = PaletteCommandExpansion.invocations(for: descriptor("visibility.toggle-hidden", [
            Argument(name: "anchor", isRequired: false, allowedValues: ["pointer", "status-item"]),
        ]))
        #expect(rows.count == 1)
        #expect(rows.first?.arguments == [:])
        #expect(rows.first?.key == "command:visibility.toggle-hidden")
    }

    @Test func allowedValuesExpandIntoOneRowEach() {
        let rows = PaletteCommandExpansion.invocations(for: descriptor("layout.set-default-section", [
            Argument(name: "section", isRequired: true, allowedValues: ["shown", "hidden", "always-hidden"]),
        ]))
        #expect(rows.map { $0.arguments["section"] } == ["shown", "hidden", "always-hidden"])
        #expect(rows.map(\.key) == ["command:layout.set-default-section?section=shown",
                                    "command:layout.set-default-section?section=hidden",
                                    "command:layout.set-default-section?section=always-hidden"])
    }

    @Test func severalRequiredArgumentsCombineUpToTheCap() {
        let values = (0..<20).map { "v\($0)" }
        let rows = PaletteCommandExpansion.invocations(for: descriptor("demo.pick", [
            Argument(name: "a", isRequired: true, allowedValues: ["x", "y"]),
            Argument(name: "b", isRequired: true, allowedValues: values),
        ]))
        #expect(rows.count == PaletteCommandExpansion.maxRowsPerCommand - 24)   // 2 × 20
        #expect(rows.first?.arguments == ["a": "x", "b": "v0"])
        let many = PaletteCommandExpansion.invocations(for: descriptor("demo.many", [
            Argument(name: "a", isRequired: true, allowedValues: (0..<100).map { "v\($0)" }),
        ]))
        #expect(many.count == PaletteCommandExpansion.maxRowsPerCommand)
    }

    @Test func freeTextDebugUnavailableAndDuplicatesAreLeftOut() {
        #expect(PaletteCommandExpansion.invocations(for: descriptor("item.activate", [
            Argument(name: "owner", isRequired: true, allowedValues: nil),
        ])).isEmpty)
        #expect(PaletteCommandExpansion.invocations(for: descriptor("debug.dump-state")).isEmpty)
        #expect(PaletteCommandExpansion.invocations(for: descriptor("reveal.debug-dump")).isEmpty)
        #expect(PaletteCommandExpansion.invocations(for: descriptor("profiles.apply-1", available: false)).isEmpty)
        #expect(PaletteCommandExpansion.invocations(for: descriptor("profiles.apply", [
            Argument(name: "id", isRequired: true, allowedValues: ["work"]),
        ])).isEmpty)
        #expect(PaletteCommandExpansion.invocations(for: descriptor("palette.toggle")).isEmpty)
        #expect(PaletteCommandExpansion.invocations(for: descriptor("palette.clear-history")).count == 1)
        #expect(PaletteCommandExpansion.invocations(for: descriptor("demo.empty", [
            Argument(name: "a", isRequired: true, allowedValues: []),
        ])).isEmpty)
    }

    @Test func valuesWithoutNamesAreMadeReadable() {
        #expect(PaletteCommandExpansion.humanize("always-hidden") == "Always hidden")
        #expect(PaletteCommandExpansion.humanize("after_press") == "After press")
    }

    @Test func registeredCommandsBecomeRows() throws {
        let context = try TestContext.make()
        let source = PaletteRowSource(context: context)
        let rows = source.commandRows()
        let ids = Set(rows.map(\.id))
        #expect(ids.contains("command:visibility.toggle-hidden"))
        #expect(ids.contains("command:app.quit"))
        // Free-text and Debug commands never appear.
        #expect(!rows.contains { $0.id.hasPrefix("command:item.activate") })
        #expect(!rows.contains { $0.id.hasPrefix("command:layout.set-section") })
        #expect(!rows.contains { $0.id.hasPrefix("command:debug.") })
        // A required argument with allowed values: one row per value, titled by the value.
        let sectionRows = rows.filter { $0.id.hasPrefix("command:layout.set-default-section") }
        #expect(sectionRows.count == 3)
        #expect(sectionRows.map(\.title).contains("Set Section for New Items: Hidden"))
    }

    @Test func settingsPanesBecomeRows() throws {
        let context = try TestContext.make()
        context.settingsPanes.register(SettingsPane(id: "demo", title: "Demo", symbol: "gearshape", sortOrder: 1,
                                                    keywords: ["alpha, beta"]) { EmptyView() })
        let rows = PaletteRowSource(context: context).settingsRows()
        let row = try #require(rows.first { $0.id == "settings:demo" })
        #expect(row.title == "Open Demo settings")
        #expect(row.alternates == ["Demo", "alpha", "beta"])
    }

    @Test func itemTagsSayWhereTheItemLives() {
        func entry(section: RolltopCore.Section?, slots: [DrawnSlotRecord]) -> CatalogEntry {
            CatalogEntry(id: "com.demo", kind: .app, owner: .app("com.demo"), displayName: "Demo", section: section,
                         hasExplicitSection: true, itemCount: 1, pids: [1], axIdentifiers: [], slots: slots,
                         lastKnownFrames: [], runsOutsideApplications: false, isUnreadable: false, isOwn: false,
                         isCarriedOver: false)
        }
        let drawn = DrawnSlotRecord(displayID: 1, frame: CGRect(x: 0, y: 0, width: 20, height: 24), ownerPID: 1,
                                    ownerBundleID: "com.demo", axIdentifier: nil, isOverflowed: false)
        let overflowed = DrawnSlotRecord(displayID: 1, frame: CGRect(x: 0, y: 0, width: 20, height: 24), ownerPID: 1,
                                         ownerBundleID: "com.demo", axIdentifier: nil, isOverflowed: true)
        #expect(PaletteRowSource.tag(for: entry(section: .hidden, slots: [])) == "Hidden")
        #expect(PaletteRowSource.tag(for: entry(section: .alwaysHidden, slots: [])) == "Always hidden")
        #expect(PaletteRowSource.tag(for: entry(section: .shown, slots: [drawn])) == nil)
        #expect(PaletteRowSource.tag(for: entry(section: .shown, slots: [overflowed])) == "Overflowed")
        #expect(PaletteRowSource.tag(for: entry(section: .shown, slots: [])) == "Not drawn")
    }

    @Test func providersAddRows() throws {
        let context = try TestContext.make()
        let provider = PaletteTestProvider()
        context.services[.paletteResultProviders].register(provider)
        let rows = PaletteRowSource(context: context).providedRows(for: "clip")
        #expect(rows.map(\.id) == ["provider:test.clipboard:1"])
        #expect(rows.first?.tag == "Clipboard")
        #expect(provider.queries == ["clip"])
        context.settings[PaletteSettings.disabledProviders] = ["test.clipboard"]
        #expect(PaletteRowSource(context: context).providedRows(for: "clip").isEmpty)
    }
}

final class PaletteTestProvider: PaletteResultProviding {
    let id = "test.clipboard"
    let title = "Clipboard"
    private(set) var queries: [String] = []
    private(set) var ran = 0

    func results(for query: String) -> [PaletteProvidedResult] {
        queries.append(query)
        guard !query.isEmpty else { return [] }
        return [PaletteProvidedResult(id: "1", title: "Copied \(query) text", subtitle: "Just now",
                                      icon: .symbol("doc.on.clipboard")) { [weak self] in self?.ran += 1 }]
    }
}

@Suite struct PaletteLayoutTests {
    private let metrics = PaletteMetrics()

    @Test func panelGrowsWithResultsUpToEightRows() {
        #expect(metrics.panelHeight(rowCount: 0) == metrics.panelHeight(rowCount: 1))
        #expect(metrics.panelHeight(rowCount: 3) - metrics.panelHeight(rowCount: 2) == metrics.rowHeight)
        #expect(metrics.panelHeight(rowCount: 20) == metrics.panelHeight(rowCount: 8))
        #expect(metrics.rowCornerRadius == metrics.cornerRadius - metrics.horizontalInset)
    }

    @Test func placedInTheUpperThirdCentred() {
        let visible = CGRect(x: 0, y: 75, width: 2304, height: 1191)   // LG UltraFine
        let frame = PalettePlacement.frame(height: 300, width: metrics.width, maxHeight: metrics.maxPanelHeight, visibleFrame: visible)
        #expect(frame.midX == visible.midX)
        #expect(frame.maxY == visible.maxY - (visible.height * PalettePlacement.topFraction).rounded())
        #expect(frame.maxY > visible.minY + visible.height * 2 / 3)
        // The top edge does not depend on the height: the panel grows downwards.
        let taller = PalettePlacement.frame(height: 400, width: metrics.width, maxHeight: metrics.maxPanelHeight, visibleFrame: visible)
        #expect(taller.maxY == frame.maxY)
        // A short screen still fits the tallest panel.
        let short = CGRect(x: 2304, y: 216, width: 600, height: 500)
        let fitted = PalettePlacement.frame(height: metrics.maxPanelHeight, width: metrics.width, maxHeight: metrics.maxPanelHeight, visibleFrame: short)
        #expect(fitted.minY >= short.minY + PalettePlacement.margin - 0.5)
        #expect(fitted.width == short.width - 2 * PalettePlacement.margin)
    }

    @Test func scrollingKeepsTheSelectionVisible() {
        var scroll = PaletteScroll()
        scroll.reveal(row: 10, rowCount: 20, metrics: metrics)
        #expect(scroll.offset == 3 * metrics.rowHeight)
        #expect(scroll.row(atListY: metrics.listInset + 1, rowCount: 20, metrics: metrics) == 3)
        scroll.reveal(row: 1, rowCount: 20, metrics: metrics)
        #expect(scroll.offset == metrics.rowHeight)
        scroll.offset = 10_000
        scroll.clamp(rowCount: 20, metrics: metrics)
        #expect(scroll.offset == 12 * metrics.rowHeight)
        #expect(scroll.row(atListY: 2, rowCount: 20, metrics: metrics) == nil)   // in the inset
    }
}
