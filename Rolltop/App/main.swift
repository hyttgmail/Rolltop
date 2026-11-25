import AppKit

// LSUIElement in Info.plist makes this an agent app; never set the activation policy here
// (docs/PLATFORM.md §7).
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
