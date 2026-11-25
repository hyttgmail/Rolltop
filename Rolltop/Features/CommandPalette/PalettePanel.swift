import AppKit
import SwiftUI

/// Borderless, non-activating panel on interactive glass (DESIGN.md "Floating panels").
/// It becomes key so the search field takes typing while Rolltop stays inactive and the
/// frontmost app keeps its windows.
final class PalettePanel: NSPanel {
    /// Every key down and key equivalent goes here first; true = handled.
    var keyHandler: ((NSEvent) -> Bool)?

    let glass = NSGlassEffectView()
    let content: PaletteContentView

    init(model: PaletteModel) {
        content = PaletteContentView(model: model)
        super.init(contentRect: CGRect(x: 0, y: 0, width: model.metrics.width, height: model.panelHeight),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        // Above app windows and the menu bar, below pop-up menus (101).
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        // A key borderless panel on glass gets a rectangular window shadow on 27.2 (its
        // corners show beyond the rounded glass; measured, not when the panel is not key).
        // The glass's own rim defines the edge.
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
        isMovable = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        title = String(localized: "Search", table: "CommandPalette")
        setAccessibilitySubrole(.floatingWindow)

        glass.style = .regular
        glass.cornerRadius = model.metrics.cornerRadius
        // Hosts a text field and clickable rows (27.0+).
        glass.effectIsInteractive = true
        glass.contentView = content
        contentView = glass
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyHandler?(event) == true { return }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, keyHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    /// Whether an input method is composing in the search field.
    var hasMarkedText: Bool {
        (content.field.currentEditor() as? NSTextView)?.hasMarkedText() ?? false
    }

    /// The search field (or its field editor) has the keyboard focus.
    var isFieldFocused: Bool {
        guard let responder = firstResponder else { return false }
        if responder === content.field { return true }
        return (responder as? NSTextView).map { $0.delegate === content.field } ?? false
    }
}

/// The search field: plain text on glass, Spotlight-sized.
final class PaletteSearchField: NSTextField {
    init() {
        super.init(frame: .zero)
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        font = NSFont.preferredFont(forTextStyle: .title1)
        textColor = .labelColor
        usesSingleLineMode = true
        lineBreakMode = .byTruncatingTail
        cell?.isScrollable = true
        cell?.wraps = false
        let placeholder = String(localized: "Search menu bar items, profiles and commands", table: "CommandPalette")
        placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .font: NSFont.preferredFont(forTextStyle: .title1),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ])
        setAccessibilityLabel(String(localized: "Search", table: "CommandPalette"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// Header (symbol + field), divider, result list with its input overlay, footer.
/// Laid out by hand so the panel can resize smoothly while the top stays put.
final class PaletteContentView: NSView {
    let field = PaletteSearchField()
    let list: PaletteListInputView
    private let symbol = NSImageView()
    private let divider = NSView()
    private let listHost: NSHostingView<PaletteListView>
    private let footerHost: NSHostingView<PaletteFooterView>
    private let model: PaletteModel

    init(model: PaletteModel) {
        self.model = model
        list = PaletteListInputView(model: model)
        listHost = NSHostingView(rootView: PaletteListView(model: model))
        footerHost = NSHostingView(rootView: PaletteFooterView(model: model))
        super.init(frame: .zero)
        listHost.sizingOptions = []
        footerHost.sizingOptions = []
        // Clip to the glass's shape: SwiftUI's vibrant text layers cover their whole hosting
        // view and showed as a rectangle beyond the rounded bottom corners (measured).
        wantsLayer = true
        layer?.cornerRadius = model.metrics.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        let configuration = NSImage.SymbolConfiguration(textStyle: .title2).applying(.init(scale: .medium))
        symbol.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        symbol.contentTintColor = .secondaryLabelColor
        divider.wantsLayer = true
        for view in [symbol, field, divider, listHost, list, footerHost] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// Callback for the footer's "Set a shortcut" link.
    var onSetShortcut: (() -> Void)? {
        get { footerHost.rootView.onSetShortcut }
        set { footerHost.rootView.onSetShortcut = newValue }
    }

    override func layout() {
        super.layout()
        let metrics = model.metrics
        let width = bounds.width
        let header = metrics.headerHeight
        symbol.frame = CGRect(x: 20, y: (header - 24) / 2, width: 24, height: 24)
        let fieldHeight = ceil((field.font?.boundingRectForFont.height ?? 26))
        field.frame = CGRect(x: 54, y: ((header - fieldHeight) / 2).rounded(), width: width - 54 - 20, height: fieldHeight)
        divider.frame = CGRect(x: 0, y: header, width: width, height: 1)
        let footerY = bounds.height - metrics.footerHeight
        let listFrame = CGRect(x: 0, y: header + 1, width: width, height: max(0, footerY - header - 1))
        listHost.frame = listFrame
        list.frame = listFrame
        footerHost.frame = CGRect(x: 0, y: footerY, width: width, height: metrics.footerHeight)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateDivider()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDivider()
    }

    private func updateDivider() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        }
    }
}

/// Transparent view over the result list: hover, clicks and scrolling. The app is never
/// active, so SwiftUI hover would not fire (as in the Rolltop Bar).
final class PaletteListInputView: NSView {
    /// Row index and button.
    var onRun: ((Int, PaletteClick) -> Void)?

    private let model: PaletteModel
    private var trackingArea: NSTrackingArea?

    init(model: PaletteModel) {
        self.model = model
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    private func row(at event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        return model.scroll.row(atListY: point.y, rowCount: model.results.count, metrics: model.metrics)
    }

    override func mouseMoved(with event: NSEvent) { model.hovered = row(at: event) }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseExited(with event: NSEvent) {
        model.hovered = nil
        model.pressed = nil
    }

    override func mouseDown(with event: NSEvent) { model.pressed = row(at: event) }

    override func mouseDragged(with event: NSEvent) {
        if row(at: event) != model.pressed { model.pressed = nil }
    }

    override func mouseUp(with event: NSEvent) {
        defer { model.pressed = nil }
        guard let index = row(at: event), index == model.pressed else { return }
        // Control-click is a right click, as in the menu bar.
        let modifiers = event.modifierFlags.union(NSEvent.modifierFlags)
        onRun?(index, modifiers.contains(.control) ? .right : .left)
    }

    override func rightMouseDown(with event: NSEvent) { model.pressed = row(at: event) }

    override func rightMouseUp(with event: NSEvent) {
        defer { model.pressed = nil }
        guard let index = row(at: event), index == model.pressed else { return }
        onRun?(index, .right)
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * model.metrics.rowHeight
        model.scroll(by: -delta)
        model.hovered = row(at: event)
    }
}
