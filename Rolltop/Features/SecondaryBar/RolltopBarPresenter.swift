import AppKit
import Observation
import RolltopCore

/// The Rolltop Bar: a glass panel under the menu bar listing items, one at a time.
/// Implements `ItemPanelPresenting` (groups call `presentPanel(owners:anchor:request:)`); the
/// reveal router uses `present(_:anchor:trigger:request:)` to add the always-hidden
/// disclosure. `isPanelVisible` and `currentOpener` are observable (the reveal router's
/// `isHiddenPresented` depends on them). A transient surface (`services[.surfaces]`).
@Observable
final class RolltopBarPresenter: ItemPanelPresenting {
    /// What opened the panel; decides how it closes and whether it takes the keyboard.
    enum Trigger: String, Sendable {
        /// Rolltop's status item: closes on click outside, Escape, idle timeout.
        case statusItem = "status-item"
        /// A click on the menu bar (pointer anchor, mouse button pressed a moment ago).
        case pointerClick = "pointer-click"
        /// Hover or scroll (pointer anchor, no recent click): closes when the pointer leaves
        /// the menu bar and the panel.
        case pointerHover = "pointer-hover"
        /// A shortcut or the palette: the panel becomes key for arrow keys and Return.
        case keyboard
        case other
    }

    enum DismissReason: String, Sendable {
        case clickOutside = "click-outside"
        case escape
        case pointerLeft = "pointer-left"
        case idle
        case activated
        case toggled
        case collapse
        case api
        /// Another opener or another transient surface took over.
        case yielded
    }

    /// Id of this surface in `services[.surfaces]`.
    static let surfaceID = "secondary-bar"

    struct Content {
        var primary: [OwnerID]
        /// Always-hidden owners, behind the disclosure unless `expanded`.
        var secondary: [OwnerID] = []
        var expanded = true
    }

    let model = RolltopBarModel()
    private(set) var isPanelVisible = false
    /// Who opened the panel on screen (`ItemPanelRequest.opener`).
    private(set) var currentOpener: String?
    @ObservationIgnored private var currentRequest: ItemPanelRequest?
    @ObservationIgnored private(set) var trigger: Trigger = .other
    @ObservationIgnored private(set) var lastDismissal: (date: Date, reason: DismissReason, opener: String?)?
    /// How long the pointer may be outside the menu bar + panel before a hover-opened panel closes.
    @ObservationIgnored var hoverLeaveTolerance: TimeInterval = 0.5
    /// Forces light or dark glass (Debug look checks); nil follows the system.
    @ObservationIgnored var debugAppearance: NSAppearance?
    /// Called after the panel starts closing.
    @ObservationIgnored var onDismiss: (() -> Void)?
    /// Mean luminance under the panel when it was last shown (nil: not sampled).
    @ObservationIgnored private(set) var backdropLuminance: Double?
    /// Where the panel is (global AppKit coordinates) while visible.
    var panelFrame: CGRect? { isPanelVisible ? targetFrame : nil }

    private unowned let context: AppContext
    @ObservationIgnored private var panel: RolltopBarPanel?
    @ObservationIgnored private var content = Content(primary: [])
    @ObservationIgnored private var contentSource: (() -> Content?)?
    @ObservationIgnored private var anchor: PanelAnchor = .statusItem
    @ObservationIgnored private var screenFrame: CGRect?
    @ObservationIgnored private var targetFrame: CGRect = .zero
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var watchTimer: Timer?
    @ObservationIgnored private var lastActivity = Date()
    @ObservationIgnored private var outsideSince: Date?
    @ObservationIgnored private var contentObserver: ChangeObserver?
    @ObservationIgnored private var presentation = 0
    private let log = Log.logger("secondary-bar")

    init(context: AppContext) {
        self.context = context
    }

    // MARK: ItemPanelPresenting

    func presentPanel(owners: [OwnerID], anchor: PanelAnchor, request: ItemPanelRequest) {
        let trigger = request.gesture.map(Self.trigger(for:)) ?? inferTrigger(anchor: anchor, source: nil)
        present(Content(primary: owners), anchor: anchor, trigger: trigger, request: request)
    }

    func dismissPanel() { dismiss(.api) }

    func dismissPanel(opener: String) {
        guard isPanelVisible, currentOpener == opener else { return }
        dismiss(.api)
    }

    // MARK: Presenting

    /// `opener`'s panel was closed by a click outside a moment ago (that click may also run
    /// toggle-hidden, which must not reopen it).
    func justDismissedByClick(opener: String) -> Bool {
        guard let lastDismissal, lastDismissal.reason == .clickOutside, lastDismissal.opener == opener else { return false }
        return Date().timeIntervalSince(lastDismissal.date) < 0.5
    }

    func inferTrigger(anchor: PanelAnchor, source: CommandSource?) -> Trigger {
        let types: [CGEventType] = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        let sinceClick = types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? .infinity
        let info = Self.screenInfo(Self.pointerScreen())
        let strip = CGRect(x: info.frame.minX, y: info.frame.maxY - info.menuBarHeight,
                           width: info.frame.width, height: info.menuBarHeight + 1)
        let anchorIsStatusItem = if case .statusItem = anchor { true } else { false }
        return Self.trigger(source: source, anchorIsStatusItem: anchorIsStatusItem, secondsSinceClick: sinceClick,
                            pointerInMenuBar: strip.contains(NSEvent.mouseLocation))
    }

    /// A gesture reported by the reveal trigger: a click closes like a click-opened panel,
    /// hover and scroll close when the pointer leaves.
    static func trigger(for gesture: RevealGesture) -> Trigger {
        switch gesture {
        case .click: .pointerClick
        case .hover, .scroll: .pointerHover
        }
    }

    /// A gesture an opener reports (`ItemPanelRequest.gesture`).
    static func trigger(for gesture: ItemPanelGesture) -> Trigger {
        switch gesture {
        case .click: .pointerClick
        case .hover: .pointerHover
        case .keyboard: .keyboard
        }
    }

    /// Shortcut/palette → keyboard; Rolltop's item → status item; a pointer anchor right after
    /// a click → click; with the pointer in the menu bar and no click (hover, scroll) →
    /// hover; anything else (Shortcuts, AppleScript, URLs, automations) → other (idle timeout).
    static func trigger(source: CommandSource?, anchorIsStatusItem: Bool, secondsSinceClick: Double,
                        pointerInMenuBar: Bool) -> Trigger {
        if source == .hotkey || source == .palette { return .keyboard }
        if anchorIsStatusItem { return .statusItem }
        if secondsSinceClick < 0.7 { return .pointerClick }
        return pointerInMenuBar ? .pointerHover : .other
    }

    /// - Parameters:
    ///   - request: who opens it; a different opener than the one on screen takes the panel
    ///     over (the previous one hears `.takenOver`), the same opener just updates it.
    ///   - updating: recomputes the content while the panel is visible (catalog, layout or
    ///     forced-visible changes); nil keeps `content` as given.
    func present(_ content: Content, anchor: PanelAnchor, trigger: Trigger,
                 request: ItemPanelRequest = ItemPanelRequest(opener: "secondary-bar"), updating: (() -> Content?)? = nil) {
        let wasVisible = isPanelVisible
        if !wasVisible {
            context.services[.surfaces].willPresent(Self.surfaceID) { [weak self] newSurface in
                self?.dismiss(.yielded, takenOverBy: newSurface)
            }
        }
        let previous = wasVisible ? currentRequest : nil
        currentRequest = request
        currentOpener = request.opener
        if let previous, previous.opener != request.opener {
            log.info("\(request.opener) takes the panel over from \(previous.opener)")
            previous.onDismiss?(.takenOver(by: request.opener))
        }
        self.content = content
        self.contentSource = updating
        self.anchor = anchor
        self.trigger = trigger
        model.isExpanded = content.expanded || content.secondary.isEmpty
        model.isKeyboardMode = trigger == .keyboard
        model.busy = nil
        model.failed = nil
        model.pressed = nil
        model.hovered = nil
        screenFrame = targetScreen(for: anchor)?.frame
        let panel = panel ?? makePanel()
        rebuild()
        model.selected = trigger == .keyboard ? model.selectableIDs.first : nil
        panel.allowsKey = trigger == .keyboard
        panel.apply(size: model.size, cornerRadius: model.cornerRadius)
        presentation += 1
        isPanelVisible = true
        startMonitoring()
        if wasVisible {
            applyStyle(panel, luminance: backdropLuminance)
            panel.setFrame(targetFrame, display: true)
            panel.alphaValue = 1
            focusIfKeyboard(panel)
        } else {
            // Pick light or dark glass for what is behind the panel, then show it.
            let id = presentation
            let sampleRect = ScreenGeometry.topLeftRect(fromAppKit: targetFrame)
            let sample = debugAppearance == nil && style.forcedAppearance == nil && context.services[.itemImages].usesScreenCapture
            Task { [weak self] in
                let luminance = sample ? await BackdropSampler.luminance(of: sampleRect) : nil
                guard let self, self.isPanelVisible, self.presentation == id else { return }
                self.backdropLuminance = luminance
                self.applyStyle(panel, luminance: luminance)
                self.show(panel)
                self.focusIfKeyboard(panel)
            }
        }
        log.info("presented \(model.items.count) items (\(content.secondary.count) always hidden, expanded \(model.isExpanded)), trigger \(trigger.rawValue)")
    }

    func dismiss(_ reason: DismissReason, takenOverBy: String? = nil) {
        guard isPanelVisible, let panel else { return }
        let request = currentRequest
        isPanelVisible = false
        currentRequest = nil
        currentOpener = nil
        lastDismissal = (Date(), reason, request?.opener)
        contentSource = nil
        stopMonitoring()
        model.hovered = nil
        model.pressed = nil
        panel.allowsKey = false
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let frame = panel.frame
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            if !reduceMotion { panel.animator().setFrame(frame.offsetBy(dx: 0, dy: 4), display: true) }
        }, completionHandler: { [weak self, weak panel] in
            Task { @MainActor in
                // Presented again meanwhile: keep it.
                guard let self, !self.isPanelVisible else { return }
                panel?.orderOut(nil)
            }
        })
        log.info("dismissed: \(reason.rawValue)\(takenOverBy.map { " (for \($0))" } ?? "")")
        onDismiss?()
        // Not after a click elsewhere, nor after opening an item (its menu takes over).
        let restoreFocus = [.escape, .toggled, .collapse, .idle, .api].contains(reason)
        context.services[.surfaces].didDismiss(Self.surfaceID, restoreFocus: restoreFocus)
        request?.onDismiss?(reason == .yielded ? .takenOver(by: takenOverBy ?? "?") : .closed)
    }

    private func makePanel() -> RolltopBarPanel {
        let panel = RolltopBarPanel(model: model)
        panel.input.onActivate = { [weak self] item, button in self?.activate(item, button: button) }
        panel.input.onToggleDisclosure = { [weak self] in self?.toggleDisclosure() }
        panel.input.onEscape = { [weak self] in self?.dismiss(.escape) }
        panel.input.onPointerActivity = { [weak self] in self?.lastActivity = Date() }
        self.panel = panel
        // Images, items and size follow the catalog, captures and settings while visible.
        contentObserver = ChangeObserver(track: { [weak self] in
            guard let self else { return }
            _ = self.context.services[.itemImages].revision
            _ = self.context.catalog.entries
            _ = self.context.visibility.forcedVisible
            _ = self.context.settings[RolltopBarSettings.itemSize]
            _ = self.context.settings[RolltopBarSettings.style]
        }) { [weak self] in self?.refreshIfVisible() }
        return panel
    }

    private var style: RolltopBarStyle { RolltopBarStyle(setting: context.settings[RolltopBarSettings.style]) }

    /// The style preset's surface and appearance: forced light or dark, otherwise the one
    /// picked for the backdrop (Debug overrides win). Groups' panels take the same style.
    private func applyStyle(_ panel: RolltopBarPanel, luminance: Double?) {
        let style = self.style
        panel.apply(style: style)
        panel.appearance = debugAppearance
            ?? (style.forcedAppearance ?? BackdropSampler.appearanceName(forLuminance: luminance)).flatMap(NSAppearance.init(named:))
    }

    private func focusIfKeyboard(_ panel: RolltopBarPanel) {
        guard trigger == .keyboard else { return }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(panel.input)
    }

    private func show(_ panel: RolltopBarPanel) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.setFrame(reduceMotion ? targetFrame : targetFrame.offsetBy(dx: 0, dy: 6), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        let target = targetFrame
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.1 : 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            if !reduceMotion { panel.animator().setFrame(target, display: true) }
        }
    }

    private func refreshIfVisible() {
        guard isPanelVisible, let panel else { return }
        if let fresh = contentSource?() {
            let expanded = model.isExpanded
            content = fresh
            content.expanded = expanded
        }
        rebuild()
        panel.apply(size: model.size, cornerRadius: model.cornerRadius)
        applyStyle(panel, luminance: backdropLuminance)
        panel.setFrame(targetFrame, display: true)
    }

    private func toggleDisclosure() {
        guard let panel else { return }
        model.isExpanded.toggle()
        content.expanded = model.isExpanded
        rebuild()
        if model.isKeyboardMode, model.selected.map({ id in !model.selectableIDs.contains(id) }) ?? true {
            model.selected = model.selectableIDs.last
        }
        panel.apply(size: model.size, cornerRadius: model.cornerRadius)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion {
            panel.setFrame(targetFrame, display: true)
        } else {
            let target = targetFrame
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                panel.animator().setFrame(target, display: true)
            }
        }
    }

    // MARK: Layout

    private func rebuild() {
        let metrics = RolltopBarMetrics(size: RolltopBarItemSize(setting: context.settings[RolltopBarSettings.itemSize]))
        model.metrics = metrics
        let screen = screenFrame.flatMap { frame in NSScreen.screens.first { $0.frame == frame } } ?? Self.pointerScreen()
        let info = Self.screenInfo(screen)
        let trailing = trailing(for: anchor, on: screen)
        let range = RolltopBarPlacement.allowedRange(screen: info, anchorX: RolltopBarPlacement.anchorX(trailing, screen: info),
                                                  margin: metrics.screenMargin)

        let images = context.services[.itemImages]
        var kinds: [(id: String, kind: RolltopBarModel.CellKind, width: CGFloat)] = []
        func addItems(_ owners: [OwnerID], alwaysHidden: Bool) {
            for owner in owners {
                let count = min(8, max(1, context.catalog.entry(for: owner)?.itemCount ?? 1))
                let name = context.catalog.displayName(for: owner)
                for index in 0..<count {
                    let image = images.image(for: owner, itemIndex: index, height: metrics.imageHeight)
                    let item = RolltopBarModel.Item(id: "\(owner.stringValue)#\(index)", owner: owner, index: index,
                                                 name: name, isAlwaysHidden: alwaysHidden, image: image)
                    kinds.append((item.id, .item(item), metrics.cellWidth(imageWidth: image?.size.width ?? metrics.imageHeight)))
                }
            }
        }
        addItems(content.primary, alwaysHidden: false)
        if model.isExpanded, !content.secondary.isEmpty {
            if !content.primary.isEmpty { kinds.append(("separator", .separator, 9)) }
            addItems(content.secondary, alwaysHidden: true)
        }
        if kinds.isEmpty {
            let text = String(localized: "No hidden items", table: "SecondaryBar")
            let width = NSAttributedString(string: text, attributes: [.font: NSFont.preferredFont(forTextStyle: .callout)]).size().width
            kinds.append(("empty", .empty, (width + 24).rounded()))
        }
        if !content.secondary.isEmpty { kinds.append(("disclosure", .disclosure, metrics.disclosureWidth)) }
        model.hasDisclosure = !content.secondary.isEmpty

        let layout = RolltopBarLayout.compute(cellWidths: kinds.map(\.width), maxWidth: range.upperBound - range.lowerBound, metrics: metrics)
        model.cells = zip(kinds, layout.cellFrames).map { RolltopBarModel.Cell(id: $0.id, kind: $0.kind, frame: $1) }
        model.size = layout.size
        model.cornerRadius = metrics.cornerRadius(rows: layout.rowCount, height: layout.size.height)
        targetFrame = RolltopBarPlacement.frame(size: layout.size, trailing: trailing, screen: info, metrics: metrics)
    }

    static func pointerScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.insetBy(dx: 0, dy: -1).contains(mouse) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func targetScreen(for anchor: PanelAnchor) -> NSScreen? {
        switch anchor {
        case .statusItem: return Self.pointerScreen()
        case .point(let point): return NSScreen.screens.first { $0.frame.insetBy(dx: 0, dy: -1).contains(point) } ?? Self.pointerScreen()
        case .rect(let rect):
            let center = CGPoint(x: rect.midX, y: rect.midY)
            return NSScreen.screens.first { $0.frame.insetBy(dx: 0, dy: -2).contains(center) } ?? Self.pointerScreen()
        }
    }

    static func screenInfo(_ screen: NSScreen?) -> RolltopBarPlacement.Screen {
        guard let screen else {
            return RolltopBarPlacement.Screen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                           visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 876))
        }
        var notch: ClosedRange<CGFloat>?
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea, right.minX > left.maxX {
            notch = left.maxX...right.minX
        }
        return RolltopBarPlacement.Screen(frame: screen.frame, visibleFrame: screen.visibleFrame,
                                       safeAreaTop: screen.safeAreaInsets.top, notch: notch)
    }

    /// Under Rolltop's item on the target screen (each display's bar shows it at the same
    /// distance from the trailing edge), or the bar's trailing end when it is not drawn.
    private func trailing(for anchor: PanelAnchor, on screen: NSScreen?) -> RolltopBarPlacement.Trailing {
        switch anchor {
        case .point(let point): return .pointer(point.x)
        case .rect(let rect): return .item(rect)
        case .statusItem:
            let ownEntry = context.catalog.entries.first { $0.isOwn }
            guard ownEntry?.isOverflowed != true, let item = context.statusItemFrame(), let screen else { return .screenEdge }
            let itemScreen = NSScreen.screens.first { $0.frame.insetBy(dx: 0, dy: -2).intersects(item) }
            guard let itemScreen, itemScreen != screen else { return .item(item) }
            let fromTrailingEdge = itemScreen.frame.maxX - item.maxX
            return .item(CGRect(x: screen.frame.maxX - fromTrailingEdge - item.width, y: screen.frame.maxY - (itemScreen.frame.maxY - item.minY),
                                width: item.width, height: item.height))
        }
    }

    // MARK: Activation

    private func activate(_ item: RolltopBarModel.Item, button: ItemActivator.Button) {
        guard model.busy == nil else { return }
        model.busy = item.id
        model.failed = nil
        lastActivity = Date()
        log.info("activate \(item.id) (\(button.rawValue))")
        Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await self.context.activator.activate(item.owner, button: button, index: item.index)
                self.model.busy = nil
                switch outcome {
                case .menuOpened, .panelOpened, .notificationCenter:
                    // The item's menu opens under the menu bar: get out of its way.
                    self.dismiss(.activated)
                case .nothingDetected:
                    self.flashFailure(item.id)
                }
            } catch {
                self.model.busy = nil
                self.flashFailure(item.id)
                self.log.error("activate \(item.id) failed: \(error.localizedDescription)")
            }
        }
    }

    private func flashFailure(_ id: String) {
        model.failed = id
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            if self?.model.failed == id { self?.model.failed = nil }
        }
    }

    // MARK: Dismissal monitors

    private func startMonitoring() {
        stopMonitoring()
        lastActivity = Date()
        outsideSince = nil
        let mouseDowns: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mouseDowns, handler: { [weak self] event in
            // Rolltop's own synthetic clicks (the activator's) are not the user clicking away.
            if let cgEvent = event.cgEvent, EventSynthesizer.isSynthesized(cgEvent) { return }
            self?.dismiss(.clickOutside)
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mouseDowns, handler: { [weak self] event in
            if let self, event.window !== self.panel { self.dismiss(.clickOutside) }
            return event
        }) { monitors.append(monitor) }
        // Escape while another app has the keyboard (needs Accessibility; the key still
        // reaches that app: the panel never takes focus outside keyboard mode).
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.keyCode == 53 { self?.dismiss(.escape) }
        }) { monitors.append(monitor) }
        watchTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func stopMonitoring() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        watchTimer?.invalidate()
        watchTimer = nil
    }

    private func tick() {
        guard isPanelVisible, let panel else { return }
        let mouse = NSEvent.mouseLocation
        let now = Date()
        let busy = model.busy != nil
        if panel.frame.insetBy(dx: -2, dy: -2).contains(mouse) { lastActivity = now }
        switch RolltopBarDismissal.decide(trigger: trigger, pointerInRegion: hoverRegion(panelFrame: panel.frame).contains { $0.contains(mouse) },
                                       outsideSince: outsideSince, lastActivity: lastActivity, now: now, busy: busy,
                                       hoverTolerance: hoverLeaveTolerance,
                                       idleTimeout: context.settings[RolltopBarSettings.idleTimeout]) {
        case .keep(let newOutsideSince): outsideSince = newOutsideSince
        case .dismiss(let reason): dismiss(reason)
        }
    }

    /// The menu bar strip of the panel's screen, the panel, and the gap between them.
    private func hoverRegion(panelFrame: CGRect) -> [CGRect] {
        let screen = screenFrame.flatMap { frame in NSScreen.screens.first { $0.frame == frame } } ?? Self.pointerScreen()
        let info = Self.screenInfo(screen)
        let barBottom = info.frame.maxY - info.menuBarHeight
        let strip = CGRect(x: info.frame.minX, y: barBottom, width: info.frame.width, height: info.menuBarHeight + 1)
        let bridge = CGRect(x: panelFrame.minX - 8, y: panelFrame.maxY - 2, width: panelFrame.width + 16, height: barBottom - panelFrame.maxY + 4)
        return [strip, bridge, panelFrame.insetBy(dx: -8, dy: -8)]
    }

    // MARK: Debug

    struct Snapshot: Codable {
        struct Cell: Codable {
            var id: String
            var kind: String
            /// Global top-left points (CGEvent coordinates).
            var frame: CGRect
        }
        var visible: Bool
        var trigger: String
        var expanded: Bool
        var keyboard: Bool
        /// Global top-left points.
        var frame: CGRect?
        var appKitFrame: CGRect?
        var screen: CGRect?
        var notch: [CGFloat]?
        var cornerRadius: CGFloat
        var cells: [Cell]
        var busy: String?
        var opener: String?
        var lastDismissal: String?
        var appearance: String?
        var backdropLuminance: Double?
        var style: String
        var images: [String: String]
    }

    func snapshot() -> Snapshot {
        let frame = isPanelVisible ? panel?.frame : nil
        let topLeft = frame.map(ScreenGeometry.topLeftRect(fromAppKit:))
        let cells = model.cells.map { cell -> Snapshot.Cell in
            let kind: String = switch cell.kind {
            case .item(let item): item.isAlwaysHidden ? "always-hidden-item" : "item"
            case .separator: "separator"
            case .disclosure: "disclosure"
            case .empty: "empty"
            }
            let global = topLeft.map { CGRect(x: $0.minX + cell.frame.minX, y: $0.minY + cell.frame.minY,
                                              width: cell.frame.width, height: cell.frame.height) } ?? cell.frame
            return Snapshot.Cell(id: cell.id, kind: kind, frame: global)
        }
        var images: [String: String] = [:]
        for item in model.items {
            images[item.id] = item.image.map { "\(Int($0.size.width))x\(Int($0.size.height))\($0.isTemplate ? " template" : "")" } ?? "none"
        }
        let screen = screenFrame.flatMap { frame in NSScreen.screens.first { $0.frame == frame } }
        let info = screen.map(Self.screenInfo)
        return Snapshot(visible: isPanelVisible, trigger: trigger.rawValue, expanded: model.isExpanded, keyboard: model.isKeyboardMode,
                        frame: topLeft, appKitFrame: frame, screen: screenFrame, notch: info?.notch.map { [$0.lowerBound, $0.upperBound] },
                        cornerRadius: model.cornerRadius, cells: cells, busy: model.busy, opener: currentOpener,
                        lastDismissal: lastDismissal.map { "\($0.reason.rawValue) of \($0.opener ?? "-") at \($0.date.formatted(.iso8601))" },
                        appearance: panel?.effectiveAppearance.name.rawValue, backdropLuminance: backdropLuminance, style: style.rawValue, images: images)
    }
}

/// When a visible panel closes by itself. Pure, testable.
enum RolltopBarDismissal {
    enum Decision: Equatable {
        case keep(outsideSince: Date?)
        case dismiss(RolltopBarPresenter.DismissReason)
    }

    static func decide(trigger: RolltopBarPresenter.Trigger, pointerInRegion: Bool, outsideSince: Date?, lastActivity: Date,
                       now: Date, busy: Bool, hoverTolerance: TimeInterval, idleTimeout: TimeInterval) -> Decision {
        if busy { return .keep(outsideSince: nil) }
        switch trigger {
        case .pointerHover:
            if pointerInRegion { return .keep(outsideSince: nil) }
            guard let outsideSince else { return .keep(outsideSince: now) }
            return now.timeIntervalSince(outsideSince) > hoverTolerance ? .dismiss(.pointerLeft) : .keep(outsideSince: outsideSince)
        case .statusItem, .pointerClick, .keyboard, .other:
            guard idleTimeout > 0 else { return .keep(outsideSince: nil) }
            return now.timeIntervalSince(lastActivity) > idleTimeout ? .dismiss(.idle) : .keep(outsideSince: nil)
        }
    }
}
