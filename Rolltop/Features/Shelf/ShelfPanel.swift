import AppKit
import Quartz
import SwiftUI

/// Borderless, non-activating panel (DESIGN.md "Floating panels"). It becomes key only when
/// a view needs the keyboard (the search field), and even then Rolltop does not activate.
final class ShelfPanel: NSPanel, QLPreviewPanelDataSource {
    var onEscape: (() -> Void)?
    /// What Quick Look shows (set right before it opens).
    var quickLookURLs: [URL] = []
    let dropView: ShelfDropView

    init(controller: ShelfController) {
        dropView = ShelfDropView(controller: controller)
        super.init(contentRect: CGRect(x: 0, y: 0, width: 560, height: 400),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        // Above app windows and the menu bar (24), below pop-up menus (101), like the Rolltop Bar.
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false   // the glass draws its own edge; a window shadow would outline the clear area
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        isMovable = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true

        let hosting = ShelfHostingView(rootView: ShelfPanelView(controller: controller))
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        hosting.translatesAutoresizingMaskIntoConstraints = true
        dropView.addSubview(hosting)
        dropView.autoresizesSubviews = true
        contentView = dropView
        hosting.frame = dropView.bounds
    }

    /// Window rect (top-left origin) where a click may make the panel key: the search field.
    var keyRegion: (() -> CGRect?)?
    private var allowsKey = false

    /// Key only after a click in `keyRegion` (or for Quick Look): a click on a row, a tile or
    /// the background leaves the keyboard with the app the user is working in.
    override var canBecomeKey: Bool { allowsKey }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown, !isKeyWindow {
            let point = event.locationInWindow
            let topLeft = CGPoint(x: point.x, y: (contentView?.bounds.height ?? frame.height) - point.y)
            allowsKey = keyRegion?()?.insetBy(dx: -2, dy: -2).contains(topLeft) ?? false
        }
        super.sendEvent(event)
    }

    func allowKeyOnce() { allowsKey = true }

    /// Closing: the next showing starts without the keyboard.
    func revokeKey() {
        allowsKey = false
        if isKeyWindow { resignKey() }
    }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { onEscape?() }

    // MARK: Quick Look (public QLPreviewPanel; the panel takes the keyboard only for it)

    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { !quickLookURLs.isEmpty }
    }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = self }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = nil }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { quickLookURLs.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        quickLookURLs[index] as NSURL
    }
}

/// Lets the first click act although Rolltop is not the active app.
final class ShelfHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The panel's content view: takes file drops anywhere on the shelf.
final class ShelfDropView: NSView {
    private weak var controller: ShelfController?

    init(controller: ShelfController) {
        self.controller = controller
        super.init(frame: CGRect(x: 0, y: 0, width: 560, height: 400))
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func fileURLs(_ sender: any NSDraggingInfo) -> [URL] {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return ShelfDropPlanner.fileURLs(from: urls ?? [])
    }

    private func operation(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let controller, controller.config.filesEnabled, !controller.isDraggingOut, !fileURLs(sender).isEmpty else { return [] }
        // The shelf keeps a reference: never ask the source to move (and delete) the file.
        let mask = sender.draggingSourceOperationMask
        if mask.contains(.link) { return .link }
        if mask.contains(.copy) { return .copy }
        return mask.contains(.generic) ? .generic : []
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let operation = operation(sender)
        if !operation.isEmpty, let controller {
            controller.isDropTargeted = true
            if controller.section != .files { controller.select(.files) }
        }
        return operation
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { operation(sender) }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        controller?.isDropTargeted = false
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { !operation(sender).isEmpty }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        guard let controller, !urls.isEmpty else { return false }
        controller.dropped(urls)
        return true
    }
}

/// One file on the shelf: icon and name, drawn by AppKit so it can be a drag source with a
/// reliable end callback (for "remove after dragging out"). Click opens, right click shows
/// a menu.
final class ShelfFileTileView: NSView, NSDraggingSource {
    var item: ShelfFileItem? { didSet { refresh() } }
    var isMissing = false { didSet { refresh() } }
    weak var controller: ShelfController?

    private let iconView = NSImageView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private var mouseDownPoint: CGPoint?
    private var isHovered = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        iconView.imageScaling = .scaleProportionallyUpOrDown
        label.alignment = .center
        label.font = .preferredFont(forTextStyle: .caption1)
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byWordWrapping
        label.cell?.truncatesLastVisibleLine = true
        status.alignment = .center
        status.font = .preferredFont(forTextStyle: .caption2)
        status.textColor = .secondaryLabelColor
        status.stringValue = String(localized: "Missing", table: "Shelf")
        addSubview(iconView)
        addSubview(label)
        addSubview(status)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        #if DEBUG
        if let item, let contentView = window?.contentView {
            // Window coordinates with a top-left origin, like the SwiftUI rows.
            let rect = convert(bounds, to: nil)
            controller?.debugTileFrames[item.id] = CGRect(x: rect.minX, y: contentView.bounds.height - rect.maxY,
                                                         width: rect.width, height: rect.height)
        }
        #endif
        let icon: CGFloat = 44
        iconView.frame = CGRect(x: (bounds.width - icon) / 2, y: 6, width: icon, height: icon)
        // A missing file keeps one line for its name and one for "Missing".
        let lineHeight = ceil(label.font?.boundingRectForFont.height ?? 15)
        label.maximumNumberOfLines = isMissing ? 1 : 2
        label.lineBreakMode = isMissing ? .byTruncatingMiddle : .byWordWrapping
        label.frame = CGRect(x: 2, y: 53, width: bounds.width - 4, height: isMissing ? lineHeight : bounds.height - 54)
        status.frame = CGRect(x: 2, y: 53 + lineHeight, width: bounds.width - 4, height: lineHeight)
        status.isHidden = !isMissing
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isHovered else { return }
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    private func refresh() {
        guard let item else { return }
        let icon = NSWorkspace.shared.icon(forFile: item.path)
        iconView.image = isMissing ? NSImage(systemSymbolName: "questionmark.folder", accessibilityDescription: nil) : icon
        iconView.alphaValue = isMissing ? 0.45 : 1
        label.stringValue = item.name
        label.textColor = isMissing ? .secondaryLabelColor : .labelColor
        toolTip = item.path
        setAccessibilityLabel(isMissing ? String(localized: "\(item.name), missing", table: "Shelf") : item.name)
        needsLayout = true
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint, let item, !isMissing, let controller,
              let url = controller.url(for: item.id) else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) > 4 else { return }
        mouseDownPoint = nil
        let dragItem = NSDraggingItem(pasteboardWriter: url as NSURL)
        let image = NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false))
        image.size = CGSize(width: 44, height: 44)
        dragItem.setDraggingFrame(iconView.frame, contents: image)
        controller.dragOutBegan(item.id)
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil }
        guard mouseDownPoint != nil, let item else { return }
        if event.modifierFlags.union(NSEvent.modifierFlags).contains(.control) {
            showMenu(with: event)
        } else {
            controller?.openFile(item.id)
        }
    }

    override func rightMouseDown(with event: NSEvent) { showMenu(with: event) }

    private func showMenu(with event: NSEvent) {
        guard let item, let controller else { return }
        let menu = NSMenu()
        func add(_ title: String, enabled: Bool = true, _ action: @escaping () -> Void) {
            let menuItem = ShelfMenuAction.item(title, handler: action)
            menuItem.isEnabled = enabled
            menu.addItem(menuItem)
        }
        let present = !isMissing
        add(String(localized: "Open", table: "Shelf"), enabled: present) { controller.openFile(item.id) }
        add(String(localized: "Quick Look", table: "Shelf"), enabled: present) { controller.quickLook(item.id) }
        add(String(localized: "Show in Finder", table: "Shelf"), enabled: present) { controller.revealFile(item.id) }
        menu.addItem(.separator())
        add(String(localized: "Remove from Shelf", table: "Shelf")) { controller.removeFile(item.id) }
        menu.autoenablesItems = false
        controller.send(.interacted)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Out of the shelf: copy, link or move like a Finder file; inside Rolltop: nothing.
        context == .outsideApplication ? [.copy, .link, .generic, .move] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        guard let item else { return }
        controller?.dragOutEnded(item.id, accepted: !operation.isEmpty)
    }
}

/// Runs a closure from an `NSMenuItem` (held as the item's represented object).
final class ShelfMenuAction: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func run(_ sender: NSMenuItem) { handler() }

    static func item(_ title: String, handler: @escaping () -> Void) -> NSMenuItem {
        let action = ShelfMenuAction(handler)
        let item = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: "")
        item.target = action
        item.representedObject = action   // keeps the target alive with the item
        return item
    }
}

/// Hosts a tile in SwiftUI.
struct ShelfFileTile: NSViewRepresentable {
    let item: ShelfFileItem
    let isMissing: Bool
    let controller: ShelfController

    func makeNSView(context: Context) -> ShelfFileTileView {
        let view = ShelfFileTileView(frame: CGRect(x: 0, y: 0, width: 88, height: 92))
        view.controller = controller
        view.item = item
        view.isMissing = isMissing
        return view
    }

    func updateNSView(_ view: ShelfFileTileView, context: Context) {
        view.controller = controller
        if view.item != item { view.item = item }
        if view.isMissing != isMissing { view.isMissing = isMissing }
    }
}
