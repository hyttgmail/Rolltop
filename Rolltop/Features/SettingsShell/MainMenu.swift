import AppKit

/// Rolltop's main menu (App, Edit, Window). Rolltop is an agent app, so macOS never shows this
/// menu bar, but its key equivalents still work while one of Rolltop's windows is key:
/// ⌘, for Settings, ⌘W, ⌘Q, and the standard editing shortcuts in text fields.
final class MainMenu: NSObject {
    private let showSettings: (String?) -> Void

    init(showSettings: @escaping (String?) -> Void) {
        self.showSettings = showSettings
        super.init()
    }

    func install() {
        let main = NSMenu()
        main.addItem(submenuItem(appMenu()))
        main.addItem(submenuItem(editMenu()))
        let window = windowMenu()
        main.addItem(submenuItem(window))
        NSApp.mainMenu = main
        NSApp.windowsMenu = window
    }

    private func submenuItem(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private func appMenu() -> NSMenu {
        let menu = NSMenu(title: "Rolltop")
        let about = NSMenuItem(title: String(localized: "About Rolltop", table: "SettingsShell"),
                               action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: String(localized: "Settings…", table: "SettingsShell"),
                                  action: #selector(showSettingsWindow), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: String(localized: "Quit Rolltop", table: "SettingsShell"),
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    private func editMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Edit", table: "SettingsShell"))
        menu.addItem(NSMenuItem(title: String(localized: "Undo", table: "SettingsShell"),
                                action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: String(localized: "Redo", table: "SettingsShell"),
                              action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: String(localized: "Cut", table: "SettingsShell"),
                                action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        menu.addItem(NSMenuItem(title: String(localized: "Copy", table: "SettingsShell"),
                                action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        menu.addItem(NSMenuItem(title: String(localized: "Paste", table: "SettingsShell"),
                                action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        menu.addItem(NSMenuItem(title: String(localized: "Delete", table: "SettingsShell"),
                                action: #selector(NSText.delete(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: String(localized: "Select All", table: "SettingsShell"),
                                action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        return menu
    }

    private func windowMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Window", table: "SettingsShell"))
        menu.addItem(NSMenuItem(title: String(localized: "Close", table: "SettingsShell"),
                                action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        menu.addItem(NSMenuItem(title: String(localized: "Minimize", table: "SettingsShell"),
                                action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        return menu
    }

    @objc private func showAbout() { showSettings("about") }
    @objc private func showSettingsWindow() { showSettings(nil) }
}
