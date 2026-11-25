import AppKit
import SwiftUI

/// Shows hints in a small window at the shelf's place (under the notch, or top centre).
///
/// Decision: hints are not a transient surface. They never take focus or mouse events
/// (the window ignores the mouse and never becomes key), so they do not go through the
/// one-surface rule and never close the palette or the Rolltop Bar. While the shelf itself is
/// open, hints are skipped (notices are not: the shelf has closed before one is posted).
@Observable
final class ShelfHintPresenter {
    private(set) var hint: ShelfHint?
    private(set) var isShown = false

    @ObservationIgnored private var schedule = ShelfHintSchedule()
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private let volume = ShelfVolumeWatcher()
    @ObservationIgnored private let brightness = ShelfBrightnessWatcher()
    @ObservationIgnored private let battery = ShelfBatteryWatcher()
    @ObservationIgnored private(set) var config = ShelfHintConfig()
    @ObservationIgnored private let isShelfVisible: () -> Bool
    @ObservationIgnored private let screenFrame: () -> ShelfScreen
    @ObservationIgnored private let log = Log.logger("shelf")

    static let size = CGSize(width: 260, height: 50)

    init(isShelfVisible: @escaping () -> Bool, screenFrame: @escaping () -> ShelfScreen) {
        self.isShelfVisible = isShelfVisible
        self.screenFrame = screenFrame
        volume.onChange = { [weak self] in self?.post(.volume($0)) }
        brightness.onChange = { [weak self] in self?.post(.brightness($0)) }
        battery.onChange = { [weak self] in self?.post(.battery($0)) }
    }

    /// Starts and stops the watchers to match the switches.
    func apply(_ config: ShelfHintConfig) {
        self.config = config
        config.allows(.volume) ? volume.start() : volume.stop()
        config.allows(.brightness) ? brightness.start() : brightness.stop()
        config.allows(.battery) ? battery.start() : battery.stop()
        if !config.enabled, hint?.source != .notice { hide(animated: false) }
    }

    func stop() {
        volume.stop()
        brightness.stop()
        battery.stop()
        hide(animated: false)
    }

    /// Shows `hint` (or updates the one on screen) unless its switch is off or the shelf is open.
    func post(_ hint: ShelfHint) {
        guard config.allows(hint.source) else { return }
        guard hint.source == .notice || !isShelfVisible() else { return }
        let action = schedule.post(hint, now: Date())
        self.hint = hint
        if action == .present || !isShown { present() }
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(ShelfHintSchedule.duration))
            guard let self, !Task.isCancelled, self.schedule.expire(now: Date().addingTimeInterval(0.05)) else { return }
            self.hide(animated: true)
        }
    }

    private func present() {
        let panel = panel ?? makePanel()
        panel.setFrame(ShelfGeometry.panelFrame(size: Self.size, screen: screenFrame()), display: false)
        isShown = true
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        } else {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                panel.animator().alphaValue = 1
            }
        }
    }

    private func hide(animated: Bool) {
        hideTask?.cancel()
        hideTask = nil
        schedule.reset()
        guard isShown, let panel else { hint = nil; return }
        isShown = false
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self, weak panel] in
                MainActor.assumeIsolated {
                    guard let self, !self.isShown else { return }
                    panel?.orderOut(nil)
                    self.hint = nil
                }
            })
        } else {
            panel.orderOut(nil)
            hint = nil
        }
    }

    private func makePanel() -> NSPanel {
        let panel = ShelfHintPanel(contentRect: CGRect(origin: .zero, size: Self.size),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        let hosting = NSHostingView(rootView: ShelfHintView(presenter: self))
        hosting.sizingOptions = []
        panel.contentView = hosting
        self.panel = panel
        return panel
    }

    // MARK: Debug

    var panelFrame: CGRect? { isShown ? panel?.frame : nil }
    var debugState: [String: String] {
        [
            "volumeWatching": "\(volume.isRunning)",
            "volume": volume.last.map { "\($0.level) muted=\($0.isMuted)" } ?? "none",
            "brightnessWatching": "\(brightness.isRunning)",
            "brightnessDisplays": brightness.displays.map { "\($0)=\(DisplayBrightness.brightness(of: $0).map { String($0) } ?? "?") builtin=\(CGDisplayIsBuiltin($0) != 0) asleep=\(CGDisplayIsAsleep($0) != 0)" }.joined(separator: ","),
            "brightnessNotificationsRegistered": brightness.registered.map(String.init).joined(separator: ","),
            "brightnessPolling": "\(brightness.isPolling)",
            "brightnessSymbols": "get=\(DisplayBrightness.isAvailable) register=\(DisplayBrightness.canObserve)",
            "batteryWatching": "\(battery.isRunning)",
            "battery": ShelfPowerSources.read().map { "\($0.percent)% onPower=\($0.onPower) charged=\($0.isCharged)" } ?? "none",
            "hintShown": "\(isShown)",
            "hint": hint?.title ?? "",
        ]
    }
}

/// Never key, never main: a hint must not take the keyboard from the user's app.
private final class ShelfHintPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct ShelfHintView: View {
    let presenter: ShelfHintPresenter

    private static let shape = UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 22,
                                                      bottomTrailingRadius: 22, topTrailingRadius: 10, style: .continuous)

    var body: some View {
        HStack(spacing: 10) {
            if let hint = presenter.hint {
                Image(systemName: hint.symbol)
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 24)
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: hint.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                    if let level = hint.level {
                        ProgressView(value: min(max(level, 0), 1))
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(width: ShelfHintPresenter.size.width, height: ShelfHintPresenter.size.height)
        .glassEffect(.regular, in: Self.shape)
        .accessibilityElement(children: .combine)
    }
}
