import AppKit
import SwiftUI

/// Borderless, non-activating panel on interactive glass (DESIGN.md "Floating panels").
/// It only becomes key in keyboard mode (opened by a shortcut or the palette).
final class RolltopBarPanel: NSPanel {
    var allowsKey = false
    let glass = NSGlassEffectView()
    /// The Frosted preset's surface: a more opaque blurred material.
    private let frost = NSVisualEffectView()
    private let container = NSView()
    private var cornerRadius: CGFloat = 0
    let input: RolltopBarInputView
    private let hosting: NSHostingView<RolltopBarView>

    init(model: RolltopBarModel) {
        input = RolltopBarInputView(model: model)
        hosting = NSHostingView(rootView: RolltopBarView(model: model))
        super.init(contentRect: CGRect(x: 0, y: 0, width: 100, height: 34),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        // Above app windows and the menu bar (24), below pop-up menus (101) so an item's
        // menu always draws over the panel.
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        isMovable = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true

        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = true
        input.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = [.width, .height]
        input.autoresizingMask = [.width, .height]
        // The Frosted preset's material sits under the items inside the glass (hidden otherwise),
        // so the hosting view never moves between superviews.
        frost.isHidden = true
        container.addSubview(frost)
        container.addSubview(hosting)
        container.addSubview(input)
        glass.contentView = container
        glass.style = .regular
        glass.effectIsInteractive = true
        // No tint: legibility comes from the appearance chosen for the backdrop
        // (BackdropSampler); measured, a tint does not darken or lighten the glass enough.
        // The Accent preset tints it for colour, not for legibility.
        contentView = glass
        frost.material = .menu
        frost.blendingMode = .behindWindow
        // The panel is never key: keep the material active.
        frost.state = .active
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    /// Surface and tint of a style preset (the appearance is set by the presenter).
    func apply(style: RolltopBarStyle) {
        frost.isHidden = style != .frosted
        // Tints the background only: the glass tint plus a faint underlay below the items (a
        // half-alpha glass tint alone was invisible on 27.2); items and labels keep the label colour.
        let accent = style == .accent
        glass.tintColor = accent ? NSColor.controlAccentColor : nil
        container.wantsLayer = true
        container.layer?.backgroundColor = accent ? NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor : nil
        apply(size: contentSize, cornerRadius: cornerRadius)
        invalidateShadow()
    }

    private var contentSize: CGSize = .zero

    func apply(size: CGSize, cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        contentSize = size
        glass.cornerRadius = cornerRadius
        frost.maskImage = Self.roundedMask(radius: cornerRadius)
        container.layer?.cornerRadius = cornerRadius
        let bounds = CGRect(origin: .zero, size: size)
        container.frame = bounds
        frost.frame = bounds
        hosting.frame = bounds
        input.frame = bounds
        input.updateToolTips()
    }

    /// Stretchable rounded-rectangle mask for the visual effect view.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = max(1, radius)
        let image = NSImage(size: CGSize(width: edge * 2 + 1, height: edge * 2 + 1), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: edge, left: edge, bottom: edge, right: edge)
        image.resizingMode = .stretch
        return image
    }
}

/// Transparent view over the SwiftUI content: hover (also while Rolltop is inactive), left /
/// right clicks, keyboard navigation in keyboard mode, tooltips.
final class RolltopBarInputView: NSView {
    var onActivate: ((RolltopBarModel.Item, ItemActivator.Button) -> Void)?
    var onToggleDisclosure: (() -> Void)?
    var onEscape: (() -> Void)?
    var onPointerActivity: (() -> Void)?

    private let model: RolltopBarModel
    private var trackingArea: NSTrackingArea?

    init(model: RolltopBarModel) {
        self.model = model
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    func updateToolTips() {
        removeAllToolTips()
        for cell in model.cells {
            if case .item(let item) = cell.kind { addToolTip(cell.frame, owner: item.name as NSString, userData: nil) }
        }
    }

    private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    override func mouseMoved(with event: NSEvent) {
        model.hovered = model.cell(at: point(event))?.id
        onPointerActivity?()
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseExited(with event: NSEvent) {
        model.hovered = nil
        model.pressed = nil
    }

    override func mouseDown(with event: NSEvent) {
        model.pressed = model.cell(at: point(event))?.id
        onPointerActivity?()
    }

    override func mouseDragged(with event: NSEvent) {
        let id = model.cell(at: point(event))?.id
        if id != model.pressed { model.pressed = nil }
    }

    override func mouseUp(with event: NSEvent) {
        defer { model.pressed = nil }
        guard let cell = model.cell(at: point(event)), cell.id == model.pressed else { return }
        // Control-click is a right click, as in the menu bar.
        let modifiers = event.modifierFlags.union(NSEvent.modifierFlags)
        perform(cell, button: modifiers.contains(.control) ? .right : .left)
    }

    override func rightMouseDown(with event: NSEvent) {
        model.pressed = model.cell(at: point(event))?.id
    }

    override func rightMouseUp(with event: NSEvent) {
        defer { model.pressed = nil }
        guard let cell = model.cell(at: point(event)), cell.id == model.pressed else { return }
        perform(cell, button: .right)
    }

    private func perform(_ cell: RolltopBarModel.Cell, button: ItemActivator.Button) {
        switch cell.kind {
        case .item(let item): onActivate?(item, button)
        case .disclosure: onToggleDisclosure?()
        case .separator, .empty: break
        }
    }

    // MARK: Keyboard (keyboard mode: the panel is key)

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch RolltopBarKeys.action(keyCode: event.keyCode, modifiers: modifiers) {
        case .move(let move): model.moveSelection(move)
        case .activate(let button):
            guard let id = model.selected, let cell = model.cells.first(where: { $0.id == id }) else { return }
            perform(cell, button: button)
        case .dismiss: onEscape?()
        case nil: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// Key handling in keyboard mode. Pure, testable.
enum RolltopBarKeys {
    enum Action: Equatable {
        case move(RolltopBarModel.KeyboardMove)
        case activate(ItemActivator.Button)
        case dismiss
    }

    static func action(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Action? {
        switch keyCode {
        case 123: .move(.left)
        case 124: .move(.right)
        case 125: .move(.down)
        case 126: .move(.up)
        case 36, 76:   // Return, keypad Enter
            .activate(modifiers.contains(.shift) || modifiers.contains(.control) ? .right : .left)
        case 49: .activate(.left)   // Space
        case 53: .dismiss           // Escape
        default: nil
        }
    }
}
