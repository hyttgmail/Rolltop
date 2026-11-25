import Foundation
import Observation
import RolltopCore

extension HotkeyProblem {
    /// One line for the settings row; `title` names the other action of a conflict.
    func message(title: (HotkeyAction) -> String) -> String {
        switch self {
        case .conflict(let other):
            String(localized: "Also used by “\(title(other))”, which takes precedence.", table: "Hotkeys")
        case .reservedBySystem:
            String(localized: "macOS uses this shortcut. Change it here or turn it off in System Settings › Keyboard › Keyboard Shortcuts.",
                   table: "Hotkeys")
        case .registrationFailed(let status):
            String(localized: "macOS refused this shortcut (error \(status)); another app may use it.", table: "Hotkeys")
        }
    }
}
