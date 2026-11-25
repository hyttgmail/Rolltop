import AppKit
import RolltopCore
import SwiftUI

/// The one place groups talk to the shared item panel (`services[.itemPanel]`, the Rolltop
/// Bar). Each group presents as its own opener (`custom-items.group.<id>`) with the gesture
/// that opened it, and learns from the panel's dismissal callback when its members went
/// away, also when hidden items, another group or another transient surface took over. A
/// group whose members cannot be shown gets its own empty-state panel instead, a transient
/// surface of its own (`services[.surfaces]`).
final class CustomItemsPanelAdapter {
    static let surfaceID = "custom-items.group"

    private unowned let context: AppContext
    /// The group whose members (or empty state) are on screen.
    private(set) var visibleGroup: String?
    private(set) var lastClosed: (group: String, at: Date)?
    /// How the last one went away (Debug dump).
    private(set) var lastDismissal: String?
    /// Called once when a group's panel went away, whoever closed it.
    var onClosed: ((String) -> Void)?
    var onEdit: ((String) -> Void)?

    private var emptyPanel: CustomItemsEmptyStatePanel?
    private var clickMonitors: [Any] = []
    private let log = Log.logger("custom-items")

    init(context: AppContext) {
        self.context = context
    }

    static func opener(for group: String) -> String { "custom-items.group.\(group)" }

    var isShowingEmptyState: Bool { emptyPanel?.isVisible == true }

    func present(group: String, owners: [OwnerID], anchor: PanelAnchor, gesture: ItemPanelGesture) {
        // Another group's panel, or this group's empty state, goes first. (A previous group
        // on the Rolltop Bar also hears `.takenOver` from the presenter; it is closed already.)
        if let visibleGroup, visibleGroup != group || isShowingEmptyState { markClosed(visibleGroup, how: "replaced") }
        let request = ItemPanelRequest(opener: Self.opener(for: group), gesture: gesture) { [weak self] dismissal in
            self?.panelWentAway(group, dismissal)
        }
        visibleGroup = group
        context.services[.itemPanel].presentPanel(owners: owners, anchor: anchor, request: request)
        log.info("group \(group): presented \(owners.count) members (\(gesture.rawValue))")
    }

    func presentEmptyState(group: String, message: String, below rect: CGRect?) {
        if let visibleGroup, visibleGroup != group || isShowingEmptyState { markClosed(visibleGroup, how: "replaced") }
        // The Rolltop Bar (another group's members, hidden items) yields through the coordinator.
        context.services[.surfaces].willPresent(Self.surfaceID) { [weak self] newSurface in
            guard let self, let visible = self.visibleGroup else { return }
            self.markClosed(visible, how: "taken over by \(newSurface)")
        }
        let panel = emptyPanel ?? CustomItemsEmptyStatePanel()
        emptyPanel = panel
        panel.show(message: message, editTitle: String(localized: "Edit Group…", table: "CustomItems"), below: rect) { [weak self] in
            self?.dismiss()
            self?.onEdit?(group)
        }
        visibleGroup = group
        log.info("group \(group): empty state")
        // Close on a click anywhere else (also in another app).
        removeClickMonitors()
        let mouseDowns: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mouseDowns, handler: { [weak self] _ in self?.dismiss() }) {
            clickMonitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mouseDowns, handler: { [weak self] event in
            if event.window !== self?.emptyPanel { self?.dismiss() }
            return event
        }) { clickMonitors.append(monitor) }
    }

    /// Closes whatever this adapter put on screen.
    func dismiss() {
        guard let group = visibleGroup else { return }
        if isShowingEmptyState {
            markClosed(group, how: "closed")
        } else {
            // The presenter answers through the request's callback.
            context.services[.itemPanel].dismissPanel(opener: Self.opener(for: group))
            if visibleGroup == group { markClosed(group, how: "closed") }
        }
    }

    private func panelWentAway(_ group: String, _ dismissal: ItemPanelDismissal) {
        guard visibleGroup == group, !isShowingEmptyState else { return }
        switch dismissal {
        case .closed: markClosed(group, how: "closed")
        case .takenOver(let by): markClosed(group, how: "taken over by \(by)")
        }
    }

    private func closeEmptyPanel() {
        let wasShowing = isShowingEmptyState
        emptyPanel?.orderOut(nil)
        removeClickMonitors()
        if wasShowing { context.services[.surfaces].didDismiss(Self.surfaceID, restoreFocus: false) }
    }

    private func removeClickMonitors() {
        clickMonitors.forEach(NSEvent.removeMonitor)
        clickMonitors.removeAll()
    }

    private func markClosed(_ group: String, how: String) {
        guard visibleGroup == group else { return }
        visibleGroup = nil
        lastClosed = (group, Date())
        lastDismissal = how
        closeEmptyPanel()
        log.info("group \(group): panel \(how)")
        onClosed?(group)
    }
}

/// A small glass panel under a group whose members cannot be shown: it explains why
/// instead of opening an empty panel.
final class CustomItemsEmptyStatePanel: NSPanel {
    private let glass = NSGlassEffectView()
    private var hosting: NSHostingView<CustomItemsEmptyStateView>?

    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 260, height: 80), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        isMovable = false
        glass.style = .regular
        glass.cornerRadius = 14
        contentView = glass
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(message: String, editTitle: String, below rect: CGRect?, onEdit: @escaping () -> Void) {
        let view = CustomItemsEmptyStateView(message: message, editTitle: editTitle, onEdit: onEdit)
        let hosting = NSHostingView(rootView: view)
        self.hosting = hosting
        glass.contentView = hosting
        let size = hosting.fittingSize
        let screen = rect.flatMap { anchor in NSScreen.screens.first { $0.frame.insetBy(dx: 0, dy: -2).intersects(anchor) } }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let barBottom = screen.visibleFrame.maxY
        let midX = rect?.midX ?? (screen.frame.maxX - size.width / 2 - 12)
        let x = min(max(midX - size.width / 2, screen.frame.minX + 8), screen.frame.maxX - size.width - 8)
        setFrame(CGRect(x: x, y: barBottom - size.height - 6, width: size.width, height: size.height), display: true)
        orderFrontRegardless()
    }
}

struct CustomItemsEmptyStateView: View {
    let message: String
    let editTitle: String
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Button(editTitle, action: onEdit)
                .buttonStyle(.glass)
                .controlSize(.small)
        }
        .padding(14)
        .frame(width: 260, alignment: .leading)
        // The panel never becomes key; draw its button as active anyway.
        .environment(\.controlActiveState, .key)
    }
}
