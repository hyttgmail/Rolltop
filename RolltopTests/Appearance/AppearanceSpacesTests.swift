import AppKit
import Foundation
import Testing
@testable import Rolltop

@Suite struct AppearanceSpacesTests {
    private func style(_ kind: StyleKind) -> AppearanceStyle {
        var style = AppearanceStyle()
        style.kind = kind
        return style
    }

    @Test func currentSpaceOverrideWinsOtherSpacesAreIgnored() {
        let display = style(.tint)
        let overrides = ["space-a": style(.glass), "gone": style(.outline)]
        #expect(AppearanceSpaceResolver.resolve(displayStyle: display, overrides: overrides, currentSpace: "space-a") == style(.glass))
        #expect(AppearanceSpaceResolver.resolve(displayStyle: display, overrides: overrides, currentSpace: "space-b") == display)
        #expect(AppearanceSpaceResolver.resolve(displayStyle: display, overrides: overrides, currentSpace: nil) == display)
    }

    @Test func aSystemDisplayStillRunsForASpaceOverride() {
        // The display draws nothing, but one of its desktops does: the overlays must keep
        // running (and observing Space changes), and draw only on that desktop.
        let config = AppearanceConfiguration(isEnabled: true, style: .system)
        var resolver = AppearanceSpaceResolver(configuration: config, spaceStyles: ["d": ["": style(.tint)]],
                                               currentSpaces: ["d": "other"])
        #expect(resolver.style(forDisplay: "d") == nil)
        #expect(resolver.drawsAnything(on: ["d"]))
        resolver.currentSpaces["d"] = ""
        #expect(resolver.style(forDisplay: "d") == style(.tint))
        resolver.configuration.isEnabled = false
        #expect(!resolver.drawsAnything(on: ["d"]))
    }

    @Test func parsesTheManagedSpacesShape() {
        // As measured on 27.2.1: the main display's first desktop has an empty uuid.
        let raw: [Any] = [[
            "Display Identifier": "3C1CA7B0-7118-48C1-9772-9B456B521977",
            "Current Space": ["ManagedSpaceID": 1, "id64": 1, "type": 0, "uuid": ""],
            "Spaces": [["ManagedSpaceID": 1, "id64": 1, "type": 0, "uuid": ""],
                       ["ManagedSpaceID": 5, "id64": 5, "type": 4, "uuid": "F00"]],
        ] as [String: Any]]
        let lists = ManagedSpaces.parse(raw)
        #expect(lists?.first?.currentID == "")
        #expect(lists?.first?.desktops.map(\.id) == [""])
        #expect(lists?.first?.spaces.last?.kind == .fullScreen)
        #expect(ManagedSpaces.parse([["Spaces": []]]) == nil)
    }

    @Test func cornerSquaresSitAtTheTopAndBelowTheBar() {
        let screen = CGRect(x: 0, y: 0, width: 2304, height: 1296)
        let both = AppearanceCorners(screenCorners: true, belowMenuBar: true, radius: 10)
        let placements = AppearanceCornerGeometry.placements(screenFrame: screen, stripHeight: 30, corners: both)
        #expect(placements.map(\.frame) == [CGRect(x: 0, y: 1286, width: 10, height: 10),
                                             CGRect(x: 2294, y: 1286, width: 10, height: 10),
                                             CGRect(x: 0, y: 1256, width: 10, height: 10),
                                             CGRect(x: 2294, y: 1256, width: 10, height: 10)])
        // No strip (full screen, hidden bar): both options land on the same squares once.
        #expect(AppearanceCornerGeometry.placements(screenFrame: screen, stripHeight: 0, corners: both).count == 2)
    }
}
