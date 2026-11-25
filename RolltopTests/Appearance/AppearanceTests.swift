import AppKit
import Foundation
import RolltopCore
import Testing
@testable import Rolltop

// Geometry from frames measured on this machine (2026-11-24): LG UltraFine bar 2304×30,
// built-in bar 1728×33 with the camera housing between x 771.5 and 956.5 (bar-local).

private func input(width: CGFloat = 2304, height: CGFloat = 30, notch: ClosedRange<CGFloat>? = nil,
                   menus: CGFloat? = nil, status: CGFloat? = nil, shape: BarShape,
                   splitAroundNotch: Bool = true, radius: CGFloat = 8) -> BarLayoutInput {
    BarLayoutInput(barSize: CGSize(width: width, height: height), notch: notch, appMenusMaxX: menus,
                   statusItemsMinX: status, shape: shape, splitAroundNotch: splitAroundNotch, cornerRadius: radius)
}

private let builtInNotch: ClosedRange<CGFloat> = 771.5...956.5

@Suite struct AppearanceBarGeometryTests {
    @Test func fullWidthCoversTheStrip() {
        let segments = AppearanceBarGeometry.segments(input(shape: .fullWidth, radius: 40))
        #expect(segments.count == 1)
        #expect(segments[0].frame == CGRect(x: 0, y: 0, width: 2304, height: 30))
        // Only the bottom corners round, capped at half the height.
        #expect(segments[0].corners == SegmentCorners.bottom(15))
    }

    @Test func fullWidthSplitsAroundTheNotch() {
        let segments = AppearanceBarGeometry.segments(input(width: 1728, height: 33, notch: builtInNotch, shape: .fullWidth))
        #expect(segments.map(\.role) == [.leading, .trailing])
        #expect(segments[0].frame == CGRect(x: 0, y: 0, width: 771.5, height: 33))
        #expect(segments[1].frame == CGRect(x: 956.5, y: 0, width: 1728 - 956.5, height: 33))
        // Unless the option is off.
        let joined = AppearanceBarGeometry.segments(input(width: 1728, height: 33, notch: builtInNotch, shape: .fullWidth, splitAroundNotch: false))
        #expect(joined.count == 1)
        #expect(joined[0].frame.width == 1728)
    }

    @Test func insetIsARoundedBar() {
        let segments = AppearanceBarGeometry.segments(input(shape: .inset, radius: 9))
        #expect(segments == [BarSegment(role: .bar, frame: CGRect(x: 4, y: 2, width: 2296, height: 26), corners: .all(9))])
        let capped = AppearanceBarGeometry.segments(input(shape: .inset, radius: 50))
        #expect(capped[0].corners == .all(13))
    }

    @Test func insetSplitsAroundTheNotch() {
        let segments = AppearanceBarGeometry.segments(input(width: 1728, height: 33, notch: builtInNotch, shape: .inset))
        #expect(segments.count == 2)
        #expect(segments[0].frame.minX == 4)
        #expect(segments[0].frame.maxX == 771.5 - AppearanceBarGeometry.notchGap)
        #expect(segments[1].frame.minX == 956.5 + AppearanceBarGeometry.notchGap)
        #expect(segments[1].frame.maxX == 1724)
        for segment in segments { #expect(!segment.frame.intersects(CGRect(x: 771.5, y: 0, width: 185, height: 33))) }
    }

    @Test func splitPillsHugMenusAndStatusItems() {
        // Orca's menus end at 278; the first status item starts at 1562.
        let segments = AppearanceBarGeometry.segments(input(menus: 278, status: 1562, shape: .split, radius: 13))
        #expect(segments.map(\.role) == [.leading, .trailing])
        #expect(segments[0].frame == CGRect(x: 4, y: 2, width: 278 + 6 - 4, height: 26))
        #expect(segments[1].frame == CGRect(x: 1562 - 6, y: 2, width: 2304 - 4 - 1556, height: 26))
        #expect(segments[0].corners == .all(13))
    }

    @Test func splitPillsStayBesideTheNotch() {
        // Menus that would run under the housing stop before it; status items start after it.
        let segments = AppearanceBarGeometry.segments(input(width: 1728, height: 33, notch: builtInNotch, menus: 900, status: 800, shape: .split))
        #expect(segments.count == 2)
        #expect(segments[0].frame.maxX == 771.5 - AppearanceBarGeometry.notchGap)
        #expect(segments[1].frame.minX == 956.5 + AppearanceBarGeometry.notchGap)
        // Measured values: Finder's menus end at 352, status items start at 986.
        let measured = AppearanceBarGeometry.segments(input(width: 1728, height: 33, notch: builtInNotch, menus: 352, status: 986, shape: .split))
        #expect(measured[0].frame.maxX == 358)
        #expect(measured[1].frame.minX == 980)
    }

    @Test func splitFallsBackWhenExtentsAreUnknownOrTouch() {
        let unknown = AppearanceBarGeometry.segments(input(shape: .split))
        #expect(unknown == AppearanceBarGeometry.segments(input(shape: .inset)))
        let onlyStatus = AppearanceBarGeometry.segments(input(status: 1562, shape: .split))
        #expect(onlyStatus.map(\.role) == [.trailing])
        let touching = AppearanceBarGeometry.segments(input(width: 600, menus: 300, status: 310, shape: .split))
        #expect(touching.map(\.role) == [.bar])
        #expect(touching[0].frame == CGRect(x: 4, y: 2, width: 592, height: 26))
    }

    @Test func notchRangeComesFromAuxiliaryAreas() {
        let range = AppearanceBarGeometry.notchRange(screenMinX: 2304,
                                           auxiliaryTopLeft: CGRect(x: 2304, y: 1301, width: 771.5, height: 32),
                                           auxiliaryTopRight: CGRect(x: 3260.5, y: 1301, width: 771.5, height: 32))
        #expect(range == 771.5...956.5)
        #expect(AppearanceBarGeometry.notchRange(screenMinX: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil) == nil)
    }

    @Test func statusExtentSkipsOverflowedSlots() {
        let slots = [
            StatusExtent.Slot(frame: CGRect(x: 3290, y: -37, width: 38, height: 33), isOverflowed: true),
            StatusExtent.Slot(frame: CGRect(x: 3328, y: -37, width: 38, height: 33)),
            StatusExtent.Slot(frame: CGRect(x: 3879, y: -37, width: 133, height: 33)),
        ]
        #expect(StatusExtent.minX(slots: slots, chevron: nil, displayMinX: 2304) == 1024)
        #expect(StatusExtent.minX(slots: slots, chevron: CGRect(x: 3300, y: -37, width: 20, height: 33), displayMinX: 2304) == 996)
        #expect(StatusExtent.minX(slots: [], chevron: nil, displayMinX: 0) == nil)
    }

    @Test func statusExtentDiscountsSlotsOfExitedApps() {
        // Main bar on 27.2.1: fixture at 1496 (33 wide), Rolltop at 1529, LaunchOS at 1562.
        let fixture = StatusExtent.Slot(frame: CGRect(x: 1496, y: 0, width: 33, height: 30), isLive: false)
        let rolltop = StatusExtent.Slot(frame: CGRect(x: 1529, y: 0, width: 33, height: 30))
        let launch = StatusExtent.Slot(frame: CGRect(x: 1562, y: 0, width: 38, height: 30))
        // The leftmost item quit: the edge is where the next one starts.
        #expect(StatusExtent.minX(slots: [fixture, rolltop, launch], chevron: nil, displayMinX: 0) == 1529)
        // An item in the middle quit: everything left of it moves right by its width.
        var middle = rolltop
        middle.isLive = false
        var first = fixture
        first.isLive = true
        #expect(StatusExtent.minX(slots: [first, middle, launch], chevron: nil, displayMinX: 0) == 1529)
        // Only dead slots left: nothing to hug.
        #expect(StatusExtent.minX(slots: [fixture], chevron: nil, displayMinX: 0) == nil)
    }

    @Test func shadowNeedsRoomBelowTheBar() {
        #expect(AppearanceBarGeometry.shadowMargin(ShadowOptions(isEnabled: false, strength: 1)) == 0)
        #expect(AppearanceBarGeometry.shadowMargin(ShadowOptions(isEnabled: true, strength: 0)) == 4)
        #expect(AppearanceBarGeometry.shadowMargin(ShadowOptions(isEnabled: true, strength: 1)) == 14)
    }
}

@Suite struct ColorResolutionTests {
    @Test func singleAndPerAppearanceColours() {
        let red = RGBA(1, 0, 0, 0.5)
        let blue = RGBA(0, 0, 1)
        #expect(ColorResolver.resolve(.single(red), role: .fill, appearance: .light) == red)
        #expect(ColorResolver.resolve(.single(red), role: .fill, appearance: .dark) == red)
        #expect(ColorResolver.resolve(.lightAndDark(red, blue), role: .fill, appearance: .light) == red)
        #expect(ColorResolver.resolve(.lightAndDark(red, blue), role: .fill, appearance: .dark) == blue)
    }

    @Test func matchSystemContrastsWithTheBarText() {
        let lightFill = ColorResolver.resolve(.matchSystem, role: .fill, appearance: .light)
        let darkFill = ColorResolver.resolve(.matchSystem, role: .fill, appearance: .dark)
        // Light bar (dark text): a light fill; dark bar (light text): a dark fill.
        #expect(lightFill.red > 0.9 && lightFill.green > 0.9)
        #expect(darkFill.red < 0.2 && darkFill.blue < 0.2)
        let lightBorder = ColorResolver.resolve(.matchSystem, role: .border, appearance: .light)
        let darkBorder = ColorResolver.resolve(.matchSystem, role: .border, appearance: .dark)
        #expect(lightBorder.red == 0 && lightBorder.alpha < 0.5)
        #expect(darkBorder.red == 1 && darkBorder.alpha < 0.5)
    }

    @Test func gradientAngles() {
        let horizontal = ColorResolver.gradientPoints(degrees: 0)
        #expect(horizontal.start == CGPoint(x: 0, y: 0.5))
        #expect(horizontal.end == CGPoint(x: 1, y: 0.5))
        let vertical = ColorResolver.gradientPoints(degrees: 90)
        #expect(vertical.start == CGPoint(x: 0.5, y: 0))
        #expect(vertical.end == CGPoint(x: 0.5, y: 1))
        let reversed = ColorResolver.gradientPoints(degrees: 180)
        #expect(reversed.start == CGPoint(x: 1, y: 0.5))
        #expect(reversed.end == CGPoint(x: 0, y: 0.5))
    }

    @Test func barAppearanceFromNSAppearance() {
        #expect(MenuBarAppearanceProbe.barAppearance(NSAppearance(named: .darkAqua)!) == .dark)
        #expect(MenuBarAppearanceProbe.barAppearance(NSAppearance(named: .vibrantDark)!) == .dark)
        #expect(MenuBarAppearanceProbe.barAppearance(NSAppearance(named: .aqua)!) == .light)
        #expect(MenuBarAppearanceProbe.barAppearance(NSAppearance(named: .vibrantLight)!) == .light)
    }
}

@Suite struct AppearanceConfigurationTests {
    private var tinted: AppearanceStyle {
        var style = AppearanceStyle()
        style.kind = .tint
        return style
    }

    @Test func nothingIsDrawnWhenOffOrSystem() {
        var config = AppearanceConfiguration(isEnabled: false, style: tinted)
        #expect(config.style(forDisplay: "a") == nil)
        config.isEnabled = true
        #expect(config.style(forDisplay: "a") == tinted)
        config.style = .system
        #expect(config.style(forDisplay: "a") == nil)
        #expect(!config.drawsAnything(on: ["a", "b"]))
    }

    @Test func perDisplayStylesFallBackToTheSharedOne() {
        var glass = AppearanceStyle()
        glass.kind = .glass
        let config = AppearanceConfiguration(isEnabled: true, style: tinted, perDisplay: true,
                                             displayStyles: ["a": DisplayStyleEntry(name: "A", style: glass),
                                                             "b": DisplayStyleEntry(name: "B", style: .system)])
        #expect(config.style(forDisplay: "a") == glass)
        #expect(config.style(forDisplay: "b") == nil)
        #expect(config.style(forDisplay: "new") == tinted)
        #expect(config.drawsAnything(on: ["b"]) == false)
        #expect(config.drawsAnything(on: ["b", "a"]))
    }

    @Test func styleDecodesLeniently() throws {
        let partial = Data(#"{"kind":"glass","shape":"split","future":1}"#.utf8)
        let style = try JSONDecoder().decode(AppearanceStyle.self, from: partial)
        #expect(style.kind == .glass)
        #expect(style.shape == .split)
        #expect(style.cornerRadius == AppearanceStyle().cornerRadius)
        var full = AppearanceStyle()
        full.kind = .gradient
        full.gradientAngle = 45
        full.border = BorderOptions(isEnabled: true, color: .single(RGBA(1, 0, 0)), width: 2)
        let decoded = try JSONDecoder().decode(AppearanceStyle.self, from: JSONEncoder().encode(full))
        #expect(decoded == full)
    }

    @Test func outlineAlwaysHasABorder() {
        var style = AppearanceStyle()
        style.kind = .outline
        style.border.isEnabled = false
        style.border.width = 0
        #expect(style.effectiveBorder.isEnabled)
        #expect(style.effectiveBorder.width >= 1)
        style.kind = .tint
        #expect(!style.effectiveBorder.isEnabled)
    }

    @Test func presetsAreDistinctAndVisible() {
        let ids = AppearancePresets.ids
        #expect(Set(ids).count == ids.count)
        #expect(AppearancePresets.preset(id: AppearancePresets.defaultID) != nil)
        for preset in AppearancePresets.all { #expect(preset.style.drawsOverlay) }
        #expect(Set(AppearancePresets.all.map(\.style.kind)).isSuperset(of: [.tint, .gradient, .material, .glass, .outline]))
    }
}

@Suite struct AppearanceStoreTests {
    private func makeStore() throws -> (AppearanceStore, UserDefaults, String) {
        let suite = "com.alphapengwang.rolltop.tests.appearance.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (AppearanceStore(settings: SettingsStore(defaults: defaults)), defaults, suite)
    }

    @Test func applyPresetSwitchesStylingOn() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(store.configuration == AppearanceConfiguration())
        try store.applyPreset(id: "glass-pills")
        #expect(store.isEnabled)
        #expect(store.configuration.style == AppearancePresets.preset(id: "glass-pills")?.style)
        #expect(throws: CommandError.invalidArgument("id", "nope")) { try store.applyPreset(id: "nope") }
        // Every key lives under the profile-snapshotted prefix.
        #expect(store.settings.exportAll().keys.allSatisfy { $0.hasPrefix("rolltop.appearance.") })
    }

    @Test func toggleStartsFromTheDefaultPreset() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.toggle()
        #expect(store.isEnabled)
        #expect(store.configuration.style == AppearancePresets.preset(id: AppearancePresets.defaultID)?.style)
        store.toggle()
        #expect(!store.isEnabled)
        // A chosen style survives toggling.
        try store.applyPreset(id: "dusk")
        store.toggle()
        store.toggle()
        #expect(store.configuration.style == AppearancePresets.preset(id: "dusk")?.style)
    }

    @Test func perDisplayStylesAndRemoval() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let display = DisplayIdentity(key: "uuid-1", name: "Studio", displayID: 7)
        var glass = AppearanceStyle()
        glass.kind = .glass
        store.setStyle(glass, for: .display(display))
        #expect(store.style(for: .display(display)) == glass)
        #expect(store.style(for: .allDisplays) == .system)
        #expect(store.configuration.displayStyles["uuid-1"]?.name == "Studio")
        store.removeAll()
        #expect(store.settings.exportAll().isEmpty)
    }
}

@Suite struct MenuBarSignalTests {
    private func window(_ id: CGWindowID, pid: pid_t = 1, layer: Int, _ rect: CGRect) -> WindowInfo {
        WindowInfo(windowID: id, ownerPID: pid, layer: layer, bounds: rect)
    }

    @Test func barFrameFollowsTheMenubarWindow() {
        let builtIn = CGRect(x: 2304, y: -37, width: 1728, height: 1117)
        let windows = [
            window(9, layer: 24, CGRect(x: 0, y: 0, width: 2304, height: 30)),
            window(14, layer: 24, CGRect(x: 2304, y: -37, width: 1728, height: 33)),
            window(23, layer: 20, CGRect(x: 0, y: 0, width: 2304, height: 1296)),
        ]
        #expect(MenuBarWindows.barFrame(displayBounds: CGRect(x: 0, y: 0, width: 2304, height: 1296), windows: windows)
                == CGRect(x: 0, y: 0, width: 2304, height: 30))
        #expect(MenuBarWindows.barFrame(displayBounds: builtIn, windows: windows) == CGRect(x: 2304, y: -37, width: 1728, height: 33))
        // A bar moved off the top (hidden) or missing counts as no bar.
        let hidden = [window(14, layer: 24, CGRect(x: 2304, y: -70, width: 1728, height: 33))]
        #expect(MenuBarWindows.barFrame(displayBounds: builtIn, windows: hidden) == nil)
        #expect(MenuBarWindows.barFrame(displayBounds: builtIn, windows: []) == nil)
    }

    @Test func frontmostWindowOwnerPerDisplay() {
        let main = CGRect(x: 0, y: 0, width: 2304, height: 1296)
        let builtIn = CGRect(x: 2304, y: -37, width: 1728, height: 1117)
        let windows = [
            window(1, pid: 50, layer: 0, CGRect(x: 100, y: 100, width: 800, height: 600)),
            window(2, pid: 60, layer: 0, CGRect(x: 2500, y: 100, width: 800, height: 600)),
            window(3, pid: 70, layer: 0, CGRect(x: 2600, y: 200, width: 800, height: 600)),
            window(4, pid: 99, layer: 3, CGRect(x: 2400, y: 0, width: 800, height: 600)),
        ]
        #expect(AppMenuExtents.frontmostWindowOwner(displayBounds: builtIn, windows: windows, excluding: []) == 60)
        #expect(AppMenuExtents.frontmostWindowOwner(displayBounds: builtIn, windows: windows, excluding: [60]) == 70)
        #expect(AppMenuExtents.frontmostWindowOwner(displayBounds: main, windows: windows, excluding: []) == 50)
        #expect(AppMenuExtents.frontmostWindowOwner(displayBounds: main, windows: [], excluding: []) == nil)
    }
}
