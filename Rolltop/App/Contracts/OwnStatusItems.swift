import AppKit
import RolltopCore

/// Rolltop's own status items: the main icon (registered by the core) and the custom items
/// (spacers, groups, widgets; registered by CustomItems). macOS files them all under
/// Rolltop's bundle id, so the catalog shows one owner, `isOwn`, with several items.
///
/// - `context.statusItemFrame()` is always the main icon's frame, never another own item's,
///   and nil while the user hid the icon (Settings › General, `StatusItemVisibility`).
/// - Item images of Rolltop's owner come from here, never from screen captures: indices count
///   the visible items, the main icon first when it is shown, then the others left to right,
///   each the button's own image (template images stay templates). With nothing visible,
///   index 0 is still the main icon's image, so Rolltop's owner keeps a picture.
/// - `nudgeLayout()` makes MenuBarAgent lay the bar out again (after an order change).
///
///     context.services[.ownStatusItems].register(item, id: "custom-items.w1")   // when created
///     context.services[.ownStatusItems].unregister(id: "custom-items.w1")       // when removed
final class OwnStatusItemRegistry {
    static let mainID = "rolltop.main"

    private struct Entry {
        let id: String
        weak var item: NSStatusItem?
    }

    private var entries: [Entry] = []

    func register(_ item: NSStatusItem, id: String) {
        entries.removeAll { $0.id == id || $0.item == nil }
        entries.append(Entry(id: id, item: item))
    }

    func unregister(id: String) {
        entries.removeAll { $0.id == id || $0.item == nil }
    }

    var mainItem: NSStatusItem? { entries.first { $0.id == Self.mainID }?.item }

    /// Whether the main icon is in the menu bar (false while the user hid it).
    var isMainVisible: Bool { mainItem?.isVisible == true }

    /// Visible items other than the main icon, left to right where their frames are known.
    var otherItems: [NSStatusItem] {
        let others = entries.compactMap { $0.id == Self.mainID ? nil : $0.item }.filter(\.isVisible)
        return others.sorted { (Self.frame(of: $0)?.minX ?? .infinity) < (Self.frame(of: $1)?.minX ?? .infinity) }
    }

    /// AppKit frames of the visible items other than the main icon (drawn in a menu bar).
    var otherItemFrames: [CGRect] { otherItems.compactMap(Self.frame(of:)) }

    /// The items in the menu bar: the main icon when shown, then the others left to right.
    var visibleItems: [NSStatusItem] { (isMainVisible ? mainItem.map { [$0] } ?? [] : []) + otherItems }

    /// How many of Rolltop's items are in the menu bar (the main icon only while shown).
    var itemCount: Int { visibleItems.count }

    /// `index` as described above, exactly `height` points tall.
    func image(at index: Int, height: CGFloat) -> NSImage? {
        let visible = visibleItems
        let source: NSStatusItem? = switch Self.imageSource(index: index, visibleCount: visible.count, hasMain: mainItem != nil) {
        case .visible(let position): visible[position]
        case .hiddenMain: mainItem
        case nil: nil
        }
        guard let image = source?.button?.image else { return nil }
        return Self.scaled(image, height: height)
    }

    enum ImageSource: Equatable {
        /// `visibleItems[position]`.
        case visible(Int)
        /// Nothing of Rolltop's is in the menu bar: the (hidden) main icon stands for the owner.
        case hiddenMain
    }

    /// Which item draws image `index`: indices count the visible items; with none visible,
    /// index 0 is the hidden main icon.
    nonisolated static func imageSource(index: Int, visibleCount: Int, hasMain: Bool) -> ImageSource? {
        if index >= 0, index < visibleCount { return .visible(index) }
        return visibleCount == 0 && index == 0 && hasMain ? .hiddenMain : nil
    }

    // MARK: Layout nudge

    /// How long a nudge keeps the changed length: one frame at 60 Hz.
    static let nudgeDuration: Duration = .milliseconds(17)
    private var pendingNudge: (item: NSStatusItem, original: CGFloat)?

    /// Makes MenuBarAgent lay the menu bar out again: changes the length of one of Rolltop's
    /// visible items (the main icon first) by 0.5 pt for one frame, then restores the
    /// original length (`variableLength` stays variable). The layout editor calls it after
    /// writing a new item order (PLATFORM §5).
    ///
    /// Returns false, and changes nothing, when Rolltop has no visible item: the user hid the
    /// icon and there are no custom items (or none with a content width). Then nothing
    /// nudges the bar; the new order shows the next time macOS lays the bar out (an item
    /// appears, disappears or changes width). A nudge while one is pending reuses it and
    /// returns true. `length` (Debug calibration only) replaces the computed length.
    @discardableResult
    func nudgeLayout(holdingFor hold: Duration = OwnStatusItemRegistry.nudgeDuration, length: CGFloat? = nil) -> Bool {
        if pendingNudge != nil { return true }
        for item in visibleItems {
            let content = item.button?.intrinsicContentSize.width ?? 0
            guard let nudged = length ?? Self.nudgedLength(length: item.length, contentWidth: content) else { continue }
            pendingNudge = (item, item.length)
            item.length = nudged
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: hold)
                guard let self, let pending = self.pendingNudge else { return }
                pending.item.length = pending.original
                self.pendingNudge = nil
            }
            return true
        }
        return false
    }

    /// The length 0.5 pt longer than the item's: a fixed length plus 0.5; for a variable
    /// (or square) item, its button's content width plus 0.5. Not the drawn width: MenuBarAgent
    /// pads a fixed length on both sides (measured on 27.2.1: a fixed 33.5 drew a 50 pt slot
    /// where the variable item drew 33), so the drawn width plus 0.5 would widen the slot by
    /// ~17 pt. Nil when a variable item has no content width.
    nonisolated static func nudgedLength(length: CGFloat, contentWidth: CGFloat) -> CGFloat? {
        if length >= 0 { return length + 0.5 }
        return contentWidth > 0 ? contentWidth + 0.5 : nil
    }

    /// Windows of registered items that are not in the menu bar (the hidden main icon).
    /// AppKit keeps such a window, still `isVisible` and at its last frame, so readers of
    /// the bar's appearance must skip it.
    var hiddenItemWindows: [NSWindow] {
        entries.compactMap { entry in
            guard let item = entry.item, !item.isVisible else { return nil }
            return item.button?.window
        }
    }

    /// Where AppKit draws `item` (global AppKit coordinates), nil when it is not in a menu bar.
    /// On macOS 27 this matches MenuBarAgent's drawn slot within 1 pt (PLATFORM.md §7).
    static func frame(of item: NSStatusItem) -> CGRect? {
        guard item.isVisible, let button = item.button, let window = button.window else { return nil }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        guard frame.width > 0, NSScreen.screens.contains(where: { ScreenGeometry.menuBarFrame(of: $0).intersects(frame) }) else { return nil }
        return frame
    }

    /// The main icon's frame. When AppKit's is not usable, Rolltop's drawn slots (list B) minus
    /// the slots of its other items, if exactly one is left; never another own item. Nil
    /// while the main icon is hidden (a leftover slot would be a custom item's or stale).
    static func mainFrame(appKit: CGRect?, ownSlots: [CGRect], otherFrames: [CGRect], mainVisible: Bool = true) -> CGRect? {
        guard mainVisible else { return nil }
        if let appKit { return appKit }
        let remaining = ownSlots.filter { slot in !otherFrames.contains { abs($0.minX - slot.minX) < 2 && abs($0.width - slot.width) < 2 } }
        return remaining.count == 1 ? remaining[0] : nil
    }

    static func scaled(_ source: NSImage, height: CGFloat) -> NSImage? {
        guard height > 0, source.size.height > 0 else { return nil }
        let width = (source.size.width * height / source.size.height).rounded(.up)
        let image = NSImage(size: NSSize(width: max(1, width), height: height), flipped: false) { rect in
            source.draw(in: rect)
            return true
        }
        image.isTemplate = source.isTemplate
        return image
    }
}

extension ServiceKey where Service == OwnStatusItemRegistry {
    static var ownStatusItems: Self { .init("ownStatusItems") { _ in OwnStatusItemRegistry() } }
}
