import Foundation
import RolltopCore

/// The shelf: a glass panel at the top centre of the screen (under the notch) holding
/// clipboard history, a temporary file shelf and the next calendar events. Every section is
/// opt-in and local. Docs: docs/CONTRACTS.md; decisions in the report of milestone W3-A.
///
/// Round 2 adds hints (volume, brightness, battery), the Now Playing and weather cards
/// (from `.nowPlaying` and `.weather`), pasting a clip into the frontmost app, the
/// `.upNext` service and the `shelf.calendar` consent row.
final class ShelfFeature: FeatureModule {
    static let id: FeatureID = "shelf"

    private unowned let context: AppContext
    /// Created here, started in `start()`: nothing runs, reads or writes before that.
    let controller: ShelfController
    let upNext: ShelfUpNextProvider

    init(context: AppContext) {
        self.context = context
        let controller = ShelfController(context: context)
        self.controller = controller
        upNext = ShelfUpNextProvider { [unowned controller] in controller.eventSource }
        context.services.register(upNext as any UpNextProviding, for: .upNext)
        context.services[.consents].register(ConsentItem(
            id: "shelf.calendar",
            title: LocalizedStringResource("Calendars", table: "Shelf"),
            purpose: LocalizedStringResource("Shows your next events in the shelf and in widgets.", table: "Shelf"),
            sortOrder: 400,
            status: { [unowned controller] in ShelfUpNextProvider.consentStatus(controller.currentCalendarAccess) },
            request: { [unowned controller, upNext] in
                // Only from the row's button: the one existing full-access request.
                _ = await controller.eventSource.requestAccess()
                controller.refreshEvents()
                upNext.refresh()
            },
            settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"),
            secondaryAction: nil))
    }

    func start() {
        controller.start()
        upNext.start()
        ShelfPaletteRows.register(controller: controller, context: context)
    }

    func stop() {
        upNext.stop()
        controller.stop()
    }

    var settingsPanes: [SettingsPane] {
        let context = context
        let controller = controller
        return [SettingsPane(id: "shelf", title: LocalizedStringResource("Shelf", table: "Shelf"), symbol: "tray.full", sortOrder: 240,
                             keywords: [LocalizedStringResource("shelf, notch, clipboard, history, copy, paste, files, drop, drag, calendar, events, up next, meeting, join, privacy, hints, volume, brightness, battery, now playing, music, weather",
                                                                table: "Shelf", comment: "Settings search keywords, comma separated")]) {
            ShelfSettingsView(context: context, controller: controller)
        }]
    }

    var commands: [Command] {
        let controller = controller
        var commands: [Command] = [
            Command(id: "shelf.toggle", title: LocalizedStringResource("Shelf", table: "Shelf"), symbol: "tray.full",
                    showInStatusMenu: true, allowedFromURL: true,
                    effect: .display) { _ in
                controller.toggle()
            },
            Command(id: "shelf.show", title: LocalizedStringResource("Show Shelf", table: "Shelf"), symbol: "tray.full",
                    arguments: [CommandArgument(name: "section", title: LocalizedStringResource("Section", table: "Shelf"), isRequired: false,
                                                allowedValues: ShelfSection.allCases.map(\.rawValue))],
                    allowedFromURL: true,
                    effect: .display) { invocation in
                var section: ShelfSection?
                if let raw = invocation.string("section") {
                    guard let value = ShelfSection(rawValue: raw) else { throw CommandError.invalidArgument("section", raw) }
                    section = value
                }
                controller.show(section: section)
            },
            // Destructive: not from URLs (a web page could open one).
            Command(id: "shelf.clear-clipboard", title: LocalizedStringResource("Clear Clipboard History", table: "Shelf"), symbol: "trash",
                    effect: .destructive,
                    isAvailable: { controller.config.clipboardEnabled }) { _ in
                controller.clearHistory()
            },
            Command(id: "shelf.pause-clipboard", title: LocalizedStringResource("Pause Clipboard History", table: "Shelf"), symbol: "pause.circle",
                    arguments: [CommandArgument(name: "minutes", title: LocalizedStringResource("Minutes (0 resumes)", table: "Shelf"), isRequired: false)],
                    allowedFromURL: true,
                    effect: .changesSettings,
                    isOn: { controller.pausedUntil != nil },
                    isAvailable: { controller.config.clipboardEnabled }) { invocation in
                var minutes = 15
                if let raw = invocation.string("minutes") {
                    guard let value = Int(raw), (0...1440).contains(value) else { throw CommandError.invalidArgument("minutes", raw) }
                    minutes = value
                }
                controller.pause(minutes: minutes)
            },
        ]
        #if DEBUG
        commands += ShelfDebugCommands.make(controller: controller)
        #endif
        return commands
    }
}
