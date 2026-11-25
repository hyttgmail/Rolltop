import AppKit
import Testing
@testable import Rolltop

/// Every menu bar icon choice must draw something in both states on this system: a
/// missing SF Symbol would leave Rolltop's item empty and unreachable.
@MainActor
@Suite struct StatusItemIconTests {
    @Test(arguments: StatusItemIcon.allCases)
    func everyChoiceHasTwoTemplateImagesOfOneWidth(_ icon: StatusItemIcon) throws {
        let collapsed = try #require(icon.image(revealed: false), "\(icon) has no collapsed image")
        let revealed = try #require(icon.image(revealed: true), "\(icon) has no revealed image")
        #expect(collapsed.isTemplate && revealed.isTemplate)
        #expect(collapsed.size.width == revealed.size.width, "\(icon) changes width when revealed")
        // Sized like the system's own items: content fits the 24 pt bar.
        for image in [collapsed, revealed] {
            #expect(image.size.height > 8 && image.size.height <= 20)
        }
    }

    @Test func unknownOrMissingValuesMeanTheDefault() {
        #expect(StatusItemIcon(settingValue: "") == .slats)
        #expect(StatusItemIcon(settingValue: "rocket") == .slats)
        #expect(StatusItemIcon(settingValue: "stack") == .stack)
        #expect(StatusItemIcon.setting.defaultValue == StatusItemIcon.default.rawValue)
    }

    @Test func theChoiceIsExportedAndTheDefaultLeavesNoKey() throws {
        let context = try TestContext.make()
        context.settings[StatusItemIcon.setting] = StatusItemIcon.eye.rawValue
        #expect(context.settings.exportAll()[StatusItemIcon.setting.name] as? String == "eye")
        context.settings.reset(StatusItemIcon.setting)
        #expect(context.settings.exportAll()[StatusItemIcon.setting.name] == nil)
    }
}
