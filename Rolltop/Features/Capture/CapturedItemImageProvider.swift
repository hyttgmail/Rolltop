import AppKit
import Observation
import RolltopCore

/// Settings of item image capture (`rolltop.capture.*`).
enum CaptureSettings {
    /// "Show real item images" (needs Screen Recording).
    static let enabled = SettingsKey<Bool>("rolltop.capture.enabled", default: true)
    /// The user already answered the system's Screen Recording prompt once; the button
    /// opens System Settings from then on.
    static let requestedAccess = SettingsKey<Bool>("rolltop.capture.requested-access", default: false)
}

/// `ItemImageProviding` backed by menu bar captures. Serves the cached capture of an item
/// (also while it is hidden), else the default app icon / SF Symbol. Without the setting or
/// the Screen Recording grant it serves only the defaults.
///
/// Returned images keep the captured pixels. Monochrome captures come back as template
/// images (`NSImage.isTemplate == true`, alpha = foreground strength): draw them with the
/// surface's label colour so they stay legible on light and dark backgrounds. Coloured
/// captures are not templates and are drawn as captured.
@Observable
final class CapturedItemImageProvider: ItemImageProviding {
    enum Source: String, Sendable {
        case captured
        case appIcon = "app-icon"
    }

    private(set) var revision = 0

    @ObservationIgnored let cache: ItemImageCache
    @ObservationIgnored private let fallback: AppIconImageProvider
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let permissions: Permissions

    /// `ownItems`: Rolltop's own items are always drawn from their own images, never captured.
    init(cache: ItemImageCache, settings: SettingsStore, permissions: Permissions,
         ownItems: OwnStatusItemRegistry? = nil, ownBundleIDs: Set<String> = []) {
        self.cache = cache
        self.settings = settings
        self.permissions = permissions
        fallback = AppIconImageProvider(ownItems: ownItems, ownBundleIDs: ownBundleIDs)
    }

    /// Captures are served (setting on and Screen Recording granted).
    var servesCaptures: Bool { settings[CaptureSettings.enabled] && permissions.screenRecording }

    var usesScreenCapture: Bool { servesCaptures }

    func image(for owner: OwnerID, itemIndex: Int, height: CGFloat) -> NSImage? {
        _ = revision
        if fallback.isOwn(owner) { return fallback.ownImage(for: owner, itemIndex: itemIndex, height: height) }
        if servesCaptures, let entry = cache.entry(for: ItemImageKey(owner: owner, index: itemIndex)) {
            return entry.nsImage(height: height)
        }
        return fallback.image(for: owner, itemIndex: itemIndex, height: height)
    }

    func source(for owner: OwnerID, itemIndex: Int) -> Source {
        servesCaptures && cache.entry(for: ItemImageKey(owner: owner, index: itemIndex)) != nil ? .captured : .appIcon
    }

    /// Call when cached images changed.
    func noteChanged() { revision += 1 }
}
