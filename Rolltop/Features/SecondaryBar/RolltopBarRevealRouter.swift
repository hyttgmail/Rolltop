import AppKit
import RolltopCore

/// `RevealRouting` for the Rolltop Bar: with "Show hidden items in the Rolltop Bar" on, the
/// reveal commands open and close the panel with the hidden owners instead of changing the
/// presentation level; with it off they behave exactly like the inline default. Each reveal
/// decides for its own display (`RevealRoutePlanner.usesRolltopBar`): "only on displays with a
/// notch" and "when the menu bar is full" refine the main switch. "When full" also catches
/// the chevron that only the inline reveal itself brings up (`watchForOverflow`).
final class RolltopBarRevealRouter: RevealRouting {
    private unowned let context: AppContext
    private let presenter: RolltopBarPresenter
    private let log = Log.logger("secondary-bar")
    #if DEBUG
    /// Live tests: every display reports macOS's overflow chevron (true), none does (false),
    /// or the catalog decides (nil).
    var debugOverflow: Bool?
    #endif

    /// What a remembered overflow was learned under; any change forgets it.
    struct OverflowKey: Equatable {
        var layout: Layout
        var presentOwners: Set<OwnerID>
        var screens: [CGRect]
    }

    /// Displays where an inline reveal overflowed ("when full"), in memory only: a reveal
    /// there goes straight to the Rolltop Bar.
    private var remembered: [UInt32: OverflowKey] = [:]
    private var overflowWatch: Task<Void, Never>?
    private var switchObserver: ChangeObserver?

    init(context: AppContext, presenter: RolltopBarPresenter) {
        self.context = context
        self.presenter = presenter
        switchObserver = ChangeObserver(track: { [weak context] in _ = context?.settings[RolltopBarSettings.whenFull] }) { [weak self] in
            guard let self, !self.context.settings[RolltopBarSettings.whenFull], !self.remembered.isEmpty else { return }
            self.remembered = [:]
            self.log.info("overflow: switch off, forgot every display")
        }
    }

    private static let opener = ItemPanelRequest.revealOpener

    /// The panel shows hidden items (not a group's members).
    private var panelShowsHidden: Bool { presenter.isPanelVisible && presenter.currentOpener == Self.opener }

    var isHiddenPresented: Bool {
        context.visibility.level >= .hiddenRevealed || panelShowsHidden
    }

    /// The main switch: wording elsewhere ("hidden items open in the Rolltop Bar"). A single
    /// reveal may still go inline (notch-only) or to the panel (menu bar full).
    var presentsHiddenInPanel: Bool { context.settings[RolltopBarSettings.enabled] }

    func toggleHidden(anchor: PanelAnchor, gesture: RevealGesture?, source: CommandSource) {
        route(.toggle, anchor: anchor, gesture: gesture, source: source)
    }
    func showHidden(anchor: PanelAnchor, gesture: RevealGesture?, source: CommandSource) {
        route(.show, anchor: anchor, gesture: gesture, source: source)
    }
    func collapse() { route(.collapse, anchor: .statusItem, gesture: nil, source: .internal) }

    /// The display a reveal belongs to: the pointer's for click, hover and scroll (and a
    /// click on Rolltop's item), the active display for shortcuts, links and commands.
    static func revealScreen(anchor: PanelAnchor, gesture: RevealGesture?, source: CommandSource) -> NSScreen? {
        if gesture != nil || source == .statusMenu {
            if case .point(let point) = anchor,
               let screen = NSScreen.screens.first(where: { $0.frame.insetBy(dx: 0, dy: -1).contains(point) }) {
                return screen
            }
            return RolltopBarPresenter.pointerScreen()
        }
        return NSScreen.main ?? RolltopBarPresenter.pointerScreen()
    }

    /// macOS shows its overflow chevron in `screen`'s menu bar (last catalog read; an
    /// unreadable bar counts as not full).
    private func overflows(_ screen: NSScreen?) -> Bool {
        #if DEBUG
        if let debugOverflow { return debugOverflow }
        #endif
        let drawn = context.catalog.drawn
        guard drawn.isReadable, let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return false
        }
        return drawn.displays.first { $0.displayID == number.uint32Value }?.chevronFrame != nil
    }

    private static func displayID(_ screen: NSScreen?) -> UInt32? {
        (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private func overflowKey() -> OverflowKey {
        OverflowKey(layout: context.layout.layout, presentOwners: context.catalog.presentOwners,
                    screens: NSScreen.screens.map(\.frame))
    }

    func route(_ request: RevealRoutePlanner.Request, anchor: PanelAnchor, gesture: RevealGesture?, source: CommandSource) {
        let visibility = context.visibility
        let settings = context.settings
        let screen = Self.revealScreen(anchor: anchor, gesture: gesture, source: source)
        let whenFull = settings[RolltopBarSettings.whenFull]
        overflowWatch?.cancel()
        overflowWatch = nil
        let key = overflowKey()
        let kept = remembered.compactMapValues { RevealRoutePlanner.remembered($0, whenFull: whenFull, current: key) }
        if kept.count != remembered.count {
            log.info("overflow: forgot \(self.remembered.count - kept.count) display(s) (switch off, or layout, present owners or screens changed)")
            remembered = kept
        }
        let displayID = Self.displayID(screen)
        let wasRemembered = displayID.map { remembered[$0] != nil } ?? false
        let decided = RevealRoutePlanner.usesRolltopBar(enabled: settings[RolltopBarSettings.enabled],
                                                     onlyWithNotch: settings[RolltopBarSettings.onlyWithNotch],
                                                     whenFull: whenFull,
                                                     hasNotch: (screen?.safeAreaInsets.top ?? 0) > 0,
                                                     overflows: overflows(screen) || wasRemembered)
        if wasRemembered, request != .collapse { log.info("overflow: display \(displayID ?? 0) remembered, reveal goes to the Rolltop Bar") }
        // The gesture Reveal reports decides how the panel closes; without one, infer it now.
        let trigger = gesture.map(RolltopBarPresenter.trigger(for:)) ?? presenter.inferTrigger(anchor: anchor, source: source)
        // A toggle while the panel shows hidden items closes it, whichever display it came
        // from; the click that just closed it reveals nothing inline either.
        let justDismissed = presenter.justDismissedByClick(opener: Self.opener)
        let useRolltopBar = decided || (request == .toggle && (panelShowsHidden || justDismissed))
        // Another opener's panel (a group) is not "hidden items shown": showing takes it over.
        let steps = RevealRoutePlanner.plan(request, useRolltopBar: useRolltopBar, panelVisible: panelShowsHidden,
                                            level: visibility.level, justDismissedByClick: justDismissed)
        for step in steps {
            switch step {
            case .presentPanel:
                presentHidden(anchor: Self.anchor(anchor, on: screen), trigger: trigger)
            case .dismissPanel:
                if panelShowsHidden { presenter.dismiss(request == .collapse ? .collapse : .toggled) }
            case .engineToggle:
                visibility.toggle(.hiddenRevealed)
            case .engineShow:
                visibility.show(.hiddenRevealed)
            case .engineCollapse:
                visibility.collapse()
            }
        }
        if steps.isEmpty { log.debug("toggle consumed by the click that closed the panel") }
        if let displayID, RevealRoutePlanner.watchesForOverflow(whenFull: whenFull, request: request, usedRolltopBar: useRolltopBar,
                                                                level: visibility.level) {
            watchForOverflow(on: displayID, key: key, anchor: Self.anchor(anchor, on: screen), trigger: trigger)
        }
    }

    /// Live: a profile switch or a rule that starts or ends while the panel is up changes
    /// what it lists.
    private func presentHidden(anchor: PanelAnchor, trigger: RolltopBarPresenter.Trigger) {
        presenter.present(hiddenContent(), anchor: anchor, trigger: trigger,
                          request: ItemPanelRequest(opener: Self.opener),
                          updating: { [weak self] in self?.hiddenContent() })
    }

    /// "When full", second case: the chevron appears only because the inline reveal does not
    /// fit (PLATFORM §1–§2). Re-reads list B for about a second after the reveal; if the
    /// chevron shows up on the reveal's display, the reveal moves to the Rolltop Bar once and the
    /// display is remembered. Never re-enters `route`, so it cannot loop.
    private func watchForOverflow(on displayID: UInt32, key: OverflowKey, anchor: PanelAnchor, trigger: RolltopBarPresenter.Trigger) {
        let started = ContinuousClock.now
        overflowWatch = Task { [weak self] in
            for _ in 0..<8 {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, let catalog = self?.context.catalog else { return }
                let drawn = await catalog.refreshDrawn()
                guard !Task.isCancelled, let self else { return }
                let whenFull = self.context.settings[RolltopBarSettings.whenFull]
                let level = self.context.visibility.level
                // The reveal ended, became "Show All Items", or the switch went off.
                guard whenFull, level == .hiddenRevealed else { return }
                let chevron = drawn.isReadable && drawn.displays.first { $0.displayID == displayID }?.chevronFrame != nil
                guard RevealRoutePlanner.switchesAfterOverflow(whenFull: whenFull, level: level, chevron: chevron) else { continue }
                self.overflowWatch = nil
                self.remembered[displayID] = key
                let elapsed = ContinuousClock.now - started
                self.log.info("overflow: chevron on display \(displayID) \(Int(elapsed / .milliseconds(1))) ms after the inline reveal, switching to the Rolltop Bar")
                self.context.visibility.collapse()
                self.presentHidden(anchor: anchor, trigger: trigger)
                return
            }
        }
    }

    /// A point anchor on another display than the one the reveal belongs to (a shortcut
    /// with the pointer elsewhere) moves to the top-right of that display's menu bar.
    private static func anchor(_ anchor: PanelAnchor, on screen: NSScreen?) -> PanelAnchor {
        guard case .point(let point) = anchor, let screen, !screen.frame.insetBy(dx: 0, dy: -1).contains(point) else { return anchor }
        return .point(CGPoint(x: screen.frame.maxX - 1, y: screen.frame.maxY - 1))
    }

    /// Hidden owners, plus always-hidden ones behind the disclosure (expanded when the
    /// setting says so or Option is held; clicks on status items arrive without modifier
    /// flags on 27, so read the live state).
    private func hiddenContent() -> RolltopBarPresenter.Content {
        let entries = context.catalog.entries
        let forced = context.visibility.forcedVisible.values.reduce(into: Set<OwnerID>()) { $0.formUnion($1) }
        let alwaysMode = AlwaysHiddenPresentation(setting: context.settings[RolltopBarSettings.alwaysHidden])
        return RolltopBarPresenter.Content(primary: RevealRoutePlanner.owners(in: .hidden, entries: entries, excluding: forced),
                                        secondary: RevealRoutePlanner.owners(in: .alwaysHidden, entries: entries, excluding: forced),
                                        expanded: alwaysMode == .always || NSEvent.modifierFlags.contains(.option))
    }
}
