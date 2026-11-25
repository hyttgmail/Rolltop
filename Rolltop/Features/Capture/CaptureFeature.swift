import Foundation
import RolltopCore

/// Real images of menu bar items (Screen Recording), cached per owner and item so hidden
/// items keep their look; registers the `ItemImageProviding` service.
final class CaptureFeature: FeatureModule {
    static let id: FeatureID = "capture"

    private unowned let context: AppContext
    private let cache: ItemImageCache
    private let provider: CapturedItemImageProvider
    private var controller: CaptureController?
    private let log = Log.logger("capture")

    init(context: AppContext) {
        self.context = context
        context.settings.markTransient(CaptureSettings.requestedAccess)
        cache = ItemImageCache()
        provider = CapturedItemImageProvider(cache: cache, settings: context.settings, permissions: context.permissions,
                                             ownItems: context.services[.ownStatusItems], ownBundleIDs: context.ownBundleIDs)
        context.services.register(provider as any ItemImageProviding, for: .itemImages)
    }

    func start() {
        let controller = CaptureController(context: context, cache: cache, provider: provider)
        self.controller = controller
        controller.start()
        log.info("capture: \(cache.count) cached images, Screen Recording \(context.permissions.screenRecording ? "granted" : "not granted")")
    }

    func stop() {
        controller?.stop()
        cache.flush()
    }

    /// "Item images" in the Rolltop Bar pane, where the images show.
    var settingsSections: [SettingsPaneSection] {
        let context = context
        return [SettingsPaneSection(id: "capture.item-images", paneID: "secondary-bar", sortOrder: 100,
                                    keywords: [LocalizedStringResource("item images, real icons, screenshots, screen recording, cache", table: "Capture", comment: "Settings search keywords, comma separated")]) {
            CaptureSettingsSection(context: context)
        }]
    }

    var commands: [Command] {
        var commands = [
            Command(id: "capture.clear-cache", title: LocalizedStringResource("Clear Saved Item Images", table: "Capture"),
                    symbol: "trash", allowedFromURL: true,
                    effect: .destructive) { [weak self] _ in
                guard let self else { return }
                self.cache.removeAll()
                self.controller?.resetSignature()
                self.provider.noteChanged()
                self.log.notice("item image cache cleared")
            },
        ]
        #if DEBUG
        commands += [
            // Captures now (skipping the busy checks, never the permission check) and writes
            // the pass report to ~/Library/Application Support/Rolltop/debug/capture-report.json.
            Command(id: "capture.debug-refresh", title: "Capture Item Images Now", symbol: "camera",
                    allowedFromURL: true) { [weak self] _ in
                guard let self, let controller = self.controller else { return }
                let report = await controller.capture(force: true)
                try DebugFiles.writeJSON(report, name: "capture-report.json")
            },
            Command(id: "capture.debug-contact-sheet", title: "Write Item Image Contact Sheet", symbol: "photo.on.rectangle",
                    allowedFromURL: true) { [weak self] _ in
                guard let self else { return }
                try CaptureContactSheet.write(context: self.context, provider: self.provider)
            },
            Command(id: "capture.debug-set", title: "Set Item Image Capture (Debug)", symbol: "ladybug",
                    arguments: [CommandArgument(name: "enabled", title: "Enabled", allowedValues: ["true", "false"])],
                    allowedFromURL: true) { [weak self] invocation in
                self?.context.settings[CaptureSettings.enabled] = try invocation.require("enabled") == "true"
            },
        ]
        #endif
        return commands
    }
}
