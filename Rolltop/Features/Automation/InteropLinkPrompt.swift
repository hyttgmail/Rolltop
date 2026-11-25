import AppKit
import SwiftUI

/// Asks once, without blocking anything, whether an app may control Rolltop with links.
/// A small floating panel names the app and what its first link asked for; the answer is
/// remembered (Settings › Integrations lists it). No answer within `timeout` drops the
/// waiting links and remembers nothing.
final class InteropLinkPrompter {
    static let timeout: Duration = .seconds(120)

    private var panels: [String: NSPanel] = [:]
    private var timeouts: [String: Task<Void, Never>] = [:]
    private let statusItemFrame: () -> CGRect?

    init(statusItemFrame: @escaping () -> CGRect?) {
        self.statusItemFrame = statusItemFrame
    }

    func ask(sender: LinkSender, firstCommandTitle: String,
             completion: @escaping (InteropLinkAppRecord.Decision?) -> Void) {
        guard let bundleID = sender.bundleID, panels[bundleID] == nil else { return }
        var finished = false
        let finish: (InteropLinkAppRecord.Decision?) -> Void = { [weak self] decision in
            guard !finished else { return }
            finished = true
            self?.close(bundleID)
            completion(decision)
        }
        let panel = Self.makePanel(sender: sender, commandTitle: firstCommandTitle,
                                   onAllow: { finish(.allowed) }, onBlock: { finish(.blocked) })
        panel.onClose = { finish(nil) }
        position(panel)
        panel.orderFrontRegardless()
        panels[bundleID] = panel
        timeouts[bundleID] = Task { @MainActor in
            try? await Task.sleep(for: Self.timeout)
            guard !Task.isCancelled else { return }
            finish(nil)
        }
    }

    /// The panel, sized to its content (not shown).
    static func makePanel(sender: LinkSender, commandTitle: String,
                          onAllow: @escaping () -> Void, onBlock: @escaping () -> Void) -> InteropPromptPanel {
        let view = InteropLinkPromptView(appName: sender.displayName, appPath: sender.path, commandTitle: commandTitle,
                                         onAllow: onAllow, onBlock: onBlock)
        let panel = InteropPromptPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 160),
                                       styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow],
                                       backing: .buffered, defer: false)
        panel.title = String(localized: "Links from Another App", table: "Automation")
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let hosting = NSHostingView(rootView: view)
        panel.contentView = hosting
        // Measured from the content: a hosting view limited to its preferred size reports
        // a zero fitting size, which left the first version of this panel 0 × 0.
        let size = hosting.fittingSize
        panel.setContentSize(NSSize(width: max(size.width, 380), height: max(size.height, 120)))
        return panel
    }

    /// Closes one prompt without reporting an answer (the caller answers itself).
    func dismiss(bundleID: String) { close(bundleID) }

    /// Closes every prompt (quit); waiting links are dropped.
    func closeAll() {
        for bundleID in Array(panels.keys) { panels[bundleID]?.close() }
    }

    private func close(_ bundleID: String) {
        timeouts.removeValue(forKey: bundleID)?.cancel()
        if let panel = panels.removeValue(forKey: bundleID) as? InteropPromptPanel {
            panel.onClose = nil
            panel.orderOut(nil)
        }
    }

    /// Below Rolltop's item when it is drawn, else near the top right of the main screen.
    private func position(_ panel: NSPanel) {
        let size = panel.frame.size
        if let item = statusItemFrame(), let screen = NSScreen.screens.first(where: { $0.frame.intersects(item) }) {
            let x = min(max(item.midX - size.width / 2, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - size.width - 8)
            panel.setFrameTopLeftPoint(NSPoint(x: x, y: screen.visibleFrame.maxY - 8))
        } else if let screen = NSScreen.main ?? NSScreen.screens.first {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.maxX - size.width - 16, y: screen.visibleFrame.maxY - 8))
        }
    }
}

/// Reports a close from the title bar as "no answer".
final class InteropPromptPanel: NSPanel {
    var onClose: (() -> Void)?

    override func close() {
        let handler = onClose
        onClose = nil
        super.close()
        handler?()
    }
}

struct InteropLinkPromptView: View {
    let appName: String
    let appPath: String?
    let commandTitle: String
    let onAllow: () -> Void
    let onBlock: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Group {
                    if let appPath {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: appPath))
                            .resizable()
                    } else {
                        Image(systemName: "link")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 40, height: 40)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Allow “\(appName)” to control Rolltop with links?", tableName: "Automation")
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("It asked to: \(commandTitle). Links can show and hide items, open them, apply profiles and quit Rolltop. Rolltop remembers your answer; change it in Settings › Integrations.",
                         tableName: "Automation")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button(action: onBlock) { Text("Don’t Allow", tableName: "Automation") }
                    .keyboardShortcut(.cancelAction)
                Button(action: onAllow) { Text("Allow", tableName: "Automation") }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}
