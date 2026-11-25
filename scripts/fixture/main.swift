// RolltopFixture: a throwaway LSUIElement app with one status item that has a menu.
// Live tests conceal only this app, never the user's real apps. Built by scripts/fixture.sh.
import AppKit

final class FixtureDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let symbol = Bundle.main.object(forInfoDictionaryKey: "RolltopFixtureSymbol") as? String ?? "flask"
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "fixture"
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Rolltop fixture")
        item.button?.image?.isTemplate = true
        let menu = NSMenu()
        menu.addItem(withTitle: "Rolltop fixture \(Bundle.main.bundleIdentifier ?? "")", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        let close = NSMenuItem(title: "Close menu", action: #selector(noop), keyEquivalent: "")
        close.target = self
        menu.addItem(close)
        item.menu = menu
        self.item = item
    }

    @objc private func noop() {}
}

let app = NSApplication.shared
let fixtureDelegate = FixtureDelegate()
app.delegate = fixtureDelegate
app.run()
