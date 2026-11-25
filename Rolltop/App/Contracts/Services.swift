import AppKit
import Observation
import RolltopCore

/// A typed key into `ServiceLocator`. Identity is `name`. Declare keys as computed static
/// properties in an extension (generic types cannot have stored statics):
///
///     extension ServiceKey where Service == any ClipboardHistory {
///         static var clipboard: Self { .init("shelf.clipboard") { _ in EmptyClipboardHistory() } }
///     }
struct ServiceKey<Service> {
    let name: String
    let makeDefault: (AppContext) -> Service

    init(_ name: String, makeDefault: @escaping (AppContext) -> Service) {
        self.name = name
        self.makeDefault = makeDefault
    }
}

/// Small typed service locator. Features register replacements in `init(context:)`
/// (all features are created before any is started) and resolve at use time; do not keep
/// a resolved service across calls, a later registration may replace it.
final class ServiceLocator {
    private var storage: [String: Any] = [:]
    private weak var context: AppContext?

    func attach(_ context: AppContext) { self.context = context }

    subscript<Service>(key: ServiceKey<Service>) -> Service {
        get {
            if let service = storage[key.name] as? Service { return service }
            guard let context else { preconditionFailure("ServiceLocator used before the context exists") }
            let service = key.makeDefault(context)
            storage[key.name] = service
            return service
        }
        set { storage[key.name] = newValue }
    }

    func register<Service>(_ service: Service, for key: ServiceKey<Service>) {
        storage[key.name] = service
    }

    /// Whether something other than the default was registered or resolved.
    func isRegistered<Service>(_ key: ServiceKey<Service>) -> Bool { storage[key.name] != nil }
}

// MARK: - Item images

/// Images for menu bar items. Default: app icons and SF Symbols for system modules.
/// The Capture feature registers a capture-backed provider.
///
/// Every image is exactly `height` points tall; its width follows the content (app icons are
/// square, symbols and captures keep their aspect ratio), so callers lay images out at their
/// `size` instead of forcing a square. Monochrome images (SF Symbols, monochrome captures)
/// are templates (`isTemplate == true`): draw them with the surface's label colour. Coloured
/// images (app icons, coloured captures) are drawn as they are.
protocol ItemImageProviding: AnyObject {
    /// An image exactly `height` points tall for the owner's `itemIndex`-th item, or nil.
    func image(for owner: OwnerID, itemIndex: Int, height: CGFloat) -> NSImage?
    /// Bumps whenever images may have changed. Implementations are `@Observable`, so
    /// SwiftUI views and `ChangeObserver` that read it refresh.
    var revision: Int { get }
    /// Images come from screen captures: the user turned real item images on and Screen
    /// Recording is granted. Other screen reads that serve the same look (the Rolltop Bar's
    /// backdrop sampling) run only while this is true.
    var usesScreenCapture: Bool { get }
}

@Observable
final class AppIconImageProvider: ItemImageProviding {
    private(set) var revision = 0
    var usesScreenCapture: Bool { false }
    @ObservationIgnored private var cache: [String: NSImage] = [:]
    /// Rolltop's own items are drawn from their own images (`OwnStatusItemRegistry`).
    @ObservationIgnored private let ownItems: OwnStatusItemRegistry?
    @ObservationIgnored private let ownBundleIDs: Set<String>

    init(ownItems: OwnStatusItemRegistry? = nil, ownBundleIDs: Set<String> = []) {
        self.ownItems = ownItems
        self.ownBundleIDs = ownBundleIDs
    }

    /// Symbol point size relative to the image height: menu bar glyphs leave room above
    /// and below (18 pt image → 13 pt symbol, like the bar's own items).
    static let glyphScale: CGFloat = 0.72

    func image(for owner: OwnerID, itemIndex: Int, height: CGFloat) -> NSImage? {
        if isOwn(owner) { return ownImage(for: owner, itemIndex: itemIndex, height: height) }
        let key = "\(owner.stringValue)@\(height)"
        if let cached = cache[key] { return cached }
        let image: NSImage?
        if let symbol = Self.symbol(for: owner) {
            image = Self.symbolImage(symbol, height: height)
        } else if case .app(let bundleID) = owner {
            image = Self.appIcon(bundleID: bundleID, height: height)
        } else {
            image = nil
        }
        if let image { cache[key] = image }
        return image
    }

    /// Rolltop's own owner: its items' own images (index 0 is the main icon), never a capture
    /// or the app icon. Not cached: widgets redraw.
    func ownImage(for owner: OwnerID, itemIndex: Int, height: CGFloat) -> NSImage? {
        guard isOwn(owner), let ownItems else { return nil }
        return ownItems.image(at: itemIndex, height: height) ?? ownItems.image(at: 0, height: height)
    }

    func isOwn(_ owner: OwnerID) -> Bool {
        if case .app(let bundleID) = owner { ownBundleIDs.contains(bundleID) } else { false }
    }

    /// The symbol drawn for an owner without its own icon: system modules and the Apple
    /// agents addressed by bundle id. Every name is checked by a unit test.
    static func symbol(for owner: OwnerID) -> String? {
        switch owner {
        case .system(let module): symbol(for: module)
        case .app(let bundleID): agentSymbols[bundleID]
        }
    }

    static func symbol(for module: SystemModule) -> String {
        switch module {
        case .battery: "battery.100percent"
        // SF Symbols has no Bluetooth glyph.
        case .bluetooth: "dot.radiowaves.left.and.right"
        case .clock: "clock"
        case .displays: "display"
        case .keyboard: "light.max"
        case .sound: "speaker.wave.2"
        case .wifi: "wifi"
        case .screenMirroring: "rectangle.on.rectangle"
        case .controlCenter: "switch.2"
        }
    }

    /// macOS-managed extras (`CatalogEntry.kind == .macOSManaged`, id `managed:<AXIdentifier>`)
    /// have no owner: a recognisable symbol by a keyword of their identifier. Only
    /// `com.apple.menuextra.airdrop` was seen on the integration Mac; the other keywords
    /// follow the names macOS uses for its extras and fall back to a gear.
    static let managedSymbols: [(keyword: String, symbol: String)] = [
        ("airdrop", "dot.radiowaves.up.forward"),
        ("focus", "moon.fill"),
        ("nowplaying", "play.circle"),
        ("siri", "siri"),
        ("user", "person.crop.circle"),
        ("stagemanager", "squares.leading.rectangle"),
        ("screenmirroring", "rectangle.on.rectangle"),
        ("audiovideo", "record.circle"),
        ("camera", "video.fill"),
        ("microphone", "mic.fill"),
        ("accessibility", "accessibility"),
        ("liveactivit", "app.badge"),
    ]
    static let managedFallbackSymbol = "gearshape"

    static func symbol(forManagedID id: String) -> String {
        let identifier = id.lowercased().replacingOccurrences(of: "-", with: "")
        return managedSymbols.first { identifier.contains($0.keyword) }?.symbol ?? managedFallbackSymbol
    }

    /// System owners addressed by bundle id (docs/PLATFORM.md §2).
    static let agentSymbols: [String: String] = [
        "com.apple.systemuiserver": "clock.arrow.circlepath",   // Time Machine and other system items
        "com.apple.TextInputMenuAgent": "keyboard",             // input menu
        "com.apple.campo": "magnifyingglass",                   // Spotlight
        "com.apple.Spotlight": "magnifyingglass",
    ]

    /// A template image `height` tall with the symbol centred at its own aspect ratio.
    static func symbolImage(_ name: String, height: CGFloat) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: (height * glyphScale).rounded(), weight: .regular)
        guard height > 0, let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return nil }
        var glyph = symbol.size
        if glyph.height > height {
            glyph = NSSize(width: glyph.width * height / glyph.height, height: height)
        }
        let image = NSImage(size: NSSize(width: glyph.width.rounded(.up), height: height), flipped: false) { rect in
            symbol.draw(in: NSRect(x: (rect.width - glyph.width) / 2, y: (rect.height - glyph.height) / 2,
                                   width: glyph.width, height: glyph.height))
            return true
        }
        image.isTemplate = true
        return image
    }

    /// The app's icon, `height` × `height`.
    static func appIcon(bundleID: String, height: CGFloat) -> NSImage? {
        let icon: NSImage
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.icon {
            icon = running
        } else {
            return nil
        }
        let sized = icon.copy() as! NSImage
        sized.size = NSSize(width: height, height: height)
        return sized
    }
}

// MARK: - Item panel

/// Where a panel of items should appear.
enum PanelAnchor {
    /// Below Rolltop's own status item.
    case statusItem
    /// A point in global AppKit coordinates (bottom-left origin).
    case point(CGPoint)
    /// Below a rect in global AppKit coordinates.
    case rect(CGRect)
}

/// What made an item panel open; decides how it closes (docs/CONTRACTS.md, "Item panel").
enum ItemPanelGesture: String, Sendable {
    /// A click (on a status item or the menu bar): closes on a click outside, Escape, or
    /// when idle.
    case click
    /// Hover or scroll: closes when the pointer leaves the menu bar and the panel.
    case hover
    /// A shortcut or the palette: the panel takes the keyboard (arrows, Return, Escape).
    case keyboard
}

/// Why a presented panel went away, told to its opener exactly once.
enum ItemPanelDismissal: Equatable, Sendable {
    /// The user or the panel closed it (click outside, Escape, idle, an item was opened,
    /// the opener's own `dismissPanel(opener:)`).
    case closed
    /// Another opener presented the panel, or another transient surface (the palette, the
    /// Shelf) took the screen; the id names it.
    case takenOver(by: String)
}

/// Who opens an item panel and how, and who learns when it goes away.
struct ItemPanelRequest {
    /// Hidden items presented by the reveal commands (`visibility.toggle-hidden`…).
    static let revealOpener = "reveal"

    /// `<feature-id>[.<name>]` of the opener (`reveal`, `custom-items.group.<id>`).
    var opener: String
    /// Nil: inferred from the event state, which cannot see synthetic clicks (a click
    /// Rolltop forwards or a test posts counts as hover). Openers that know the gesture pass it.
    var gesture: ItemPanelGesture?
    /// Called once when this request's panel goes away, on the main actor.
    var onDismiss: ((ItemPanelDismissal) -> Void)?

    init(opener: String, gesture: ItemPanelGesture? = nil, onDismiss: ((ItemPanelDismissal) -> Void)? = nil) {
        self.opener = opener
        self.gesture = gesture
        self.onDismiss = onDismiss
    }
}

/// Shows a floating panel listing the given owners (the Rolltop Bar: hidden items, groups).
/// One panel at a time: presenting for another opener takes it over (the previous opener
/// hears `.takenOver`). Default: does nothing. The SecondaryBar feature registers the real one.
protocol ItemPanelPresenting: AnyObject {
    /// Observable in the real presenter.
    var isPanelVisible: Bool { get }
    /// The opener of the panel on screen, nil when none. Observable in the real presenter.
    var currentOpener: String? { get }
    func presentPanel(owners: [OwnerID], anchor: PanelAnchor, request: ItemPanelRequest)
    /// Closes the panel whoever opened it.
    func dismissPanel()
    /// Closes the panel only while `opener` owns it (a displaced opener never closes its
    /// successor's panel).
    func dismissPanel(opener: String)
}

extension ItemPanelPresenting {
    /// Before openers existed: an anonymous opener, gesture inferred, no callback.
    func presentPanel(owners: [OwnerID], anchor: PanelAnchor) {
        presentPanel(owners: owners, anchor: anchor, request: ItemPanelRequest(opener: "unknown"))
    }
}

final class NoItemPanelPresenter: ItemPanelPresenting {
    var isPanelVisible: Bool { false }
    var currentOpener: String? { nil }
    func presentPanel(owners: [OwnerID], anchor: PanelAnchor, request: ItemPanelRequest) {
        Log.logger("services").info("no item panel presenter registered; ignoring \(owners.count) owners from \(request.opener)")
    }
    func dismissPanel() {}
    func dismissPanel(opener: String) {}
}

// MARK: - Profiles

struct ProfileSummary: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    var symbol: String?
}

/// Named layouts. Default: none. The Profiles feature registers the real one.
protocol ProfileApplying: AnyObject {
    var profiles: [ProfileSummary] { get }
    var activeProfileID: String? { get }
    func applyProfile(id: String) throws
}

final class NoProfiles: ProfileApplying {
    var profiles: [ProfileSummary] { [] }
    var activeProfileID: String? { nil }
    func applyProfile(id: String) throws { throw CommandError.failed(String(localized: "There is no profile “\(id)”.")) }
}

// MARK: - Settings window

/// Opens the settings window. Default: does nothing. The SettingsShell feature registers it.
protocol SettingsWindowPresenting: AnyObject {
    func showSettings(paneID: String?)
}

final class NoSettingsWindow: SettingsWindowPresenting {
    func showSettings(paneID: String?) {
        Log.logger("services").info("no settings window registered (pane \(paneID ?? "nil"))")
    }
}

// MARK: - Keys

extension ServiceKey where Service == any ItemImageProviding {
    static var itemImages: Self {
        .init("itemImages") { AppIconImageProvider(ownItems: $0.services[.ownStatusItems], ownBundleIDs: $0.ownBundleIDs) }
    }
}

extension ServiceKey where Service == any ItemPanelPresenting {
    static var itemPanel: Self { .init("itemPanel") { _ in NoItemPanelPresenter() } }
}

extension ServiceKey where Service == any ProfileApplying {
    static var profiles: Self { .init("profiles") { _ in NoProfiles() } }
}

extension ServiceKey where Service == any SettingsWindowPresenting {
    static var settingsWindow: Self { .init("settingsWindow") { _ in NoSettingsWindow() } }
}

// MARK: - Reveal routing

/// What made a pointer-anchored reveal happen (the `gesture` argument of the reveal
/// commands). A panel opened by a click closes on click outside or when idle; one opened
/// by hover or scroll closes when the pointer leaves the menu bar and the panel.
enum RevealGesture: String, Sendable, CaseIterable {
    case click
    case hover
    case scroll
}

/// Decides how the core commands `visibility.toggle-hidden`, `visibility.show-hidden` and
/// `visibility.collapse` present hidden items. Default: inline (the engine reveals them in
/// the menu bar). The SecondaryBar feature registers a router that can show them in the
/// Rolltop Bar instead. `visibility.toggle-all` / `show-all` always stay inline.
protocol RevealRouting: AnyObject {
    /// Whether hidden items are presented right now, inline or in a panel (checkmark of
    /// `visibility.toggle-hidden`, Rolltop's icon). Must be observable: it may only read
    /// observable state, so a `ChangeObserver` or SwiftUI view that reads it follows it.
    var isHiddenPresented: Bool { get }
    /// The reveal commands present hidden items in a panel instead of the menu bar. The
    /// presentation level then stays `.collapsed` while the panel shows them, so level-based
    /// behaviour (rehide timers, make room) does not apply to the panel. Observable.
    var presentsHiddenInPanel: Bool { get }
    /// `anchor`: `.statusItem` or `.point(pointer location)`; `gesture`: set by pointer
    /// triggers (Reveal), nil otherwise; `source`: who ran the command.
    func toggleHidden(anchor: PanelAnchor, gesture: RevealGesture?, source: CommandSource)
    func showHidden(anchor: PanelAnchor, gesture: RevealGesture?, source: CommandSource)
    func collapse()
}

/// The behaviour before routing existed: drive the engine directly.
final class InlineRevealRouter: RevealRouting {
    private unowned let visibility: VisibilityEngine

    init(visibility: VisibilityEngine) { self.visibility = visibility }

    var isHiddenPresented: Bool { visibility.level >= .hiddenRevealed }
    var presentsHiddenInPanel: Bool { false }
    func toggleHidden(anchor: PanelAnchor, gesture: RevealGesture?, source: CommandSource) { visibility.toggle(.hiddenRevealed) }
    func showHidden(anchor: PanelAnchor, gesture: RevealGesture?, source: CommandSource) { visibility.show(.hiddenRevealed) }
    func collapse() { visibility.collapse() }
}

extension ServiceKey where Service == any RevealRouting {
    static var revealRouting: Self { .init("revealRouting") { InlineRevealRouter(visibility: $0.visibility) } }
}
