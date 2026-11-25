import AppKit
import SwiftUI

/// A short, non-modal message where the palette was, for a run that failed after the panel
/// closed (an item that could not be opened). Never key, ignores the mouse, fades out.
final class PaletteToast {
    private var panel: NSPanel?
    private var hosting: NSHostingView<PaletteToastView>?
    private var generation = 0
    private(set) var message: String?
    /// Forces light or dark (Debug look checks); nil follows the system.
    var appearance: NSAppearance?

    var isVisible: Bool { message != nil }

    /// Shows `message` centred under `topCenter` (AppKit coordinates) for a few seconds.
    func show(_ message: String, topCenter: CGPoint, duration: TimeInterval = 3.5) {
        generation += 1
        let id = generation
        self.message = message
        let panel = panel ?? makePanel()
        hosting?.rootView = PaletteToastView(message: message)
        let size = hosting?.fittingSize ?? CGSize(width: 320, height: 44)
        let width = min(max(size.width, 200), 640)
        let frame = CGRect(x: (topCenter.x - width / 2).rounded(), y: (topCenter.y - size.height).rounded(),
                           width: width, height: size.height)
        panel.appearance = appearance
        panel.setFrame(frame, display: true)
        (panel.contentView as? NSGlassEffectView)?.cornerRadius = size.height / 2
        hosting?.layer?.cornerRadius = size.height / 2
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.05 : 0.18
            panel.animator().alphaValue = 1
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self, self.generation == id else { return }
            self.hide()
        }
    }

    func hide() {
        guard let panel, message != nil else { return }
        message = nil
        let id = generation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self, weak panel] in
            Task { @MainActor in
                guard let self, self.generation == id, self.message == nil else { return }
                panel?.orderOut(nil)
            }
        })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 320, height: 44),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        let glass = NSGlassEffectView()
        glass.style = .regular
        let hosting = NSHostingView(rootView: PaletteToastView(message: ""))
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.wantsLayer = true
        hosting.layer?.cornerCurve = .continuous
        hosting.layer?.masksToBounds = true
        glass.contentView = hosting
        panel.contentView = glass
        self.panel = panel
        self.hosting = hosting
        return panel
    }
}

struct PaletteToastView: View {
    let message: String

    var body: some View {
        Label {
            Text(message)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        } icon: {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        }
        .font(.body)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 600)
    }
}
