import Foundation
import Observation

/// `.focusState`, from Rolltop's Focus filter (`InteropFocusFilter`). macOS runs the filter when
/// a Focus that carries it turns on (or its settings change), and again with the parameters
/// at their defaults when that Focus ends. Nothing else tells Rolltop about Focus without the
/// Communication Notifications entitlement, so the state is "on" while a Focus with the
/// filter (and a profile chosen in it) is on, and unknown otherwise: another Focus without
/// the filter may be on. Starts unknown at launch; the label stays nil (the filter has no
/// name parameter), so consumers show a generic "Focus".
@Observable
final class InteropFocusState: FocusStateProviding {
    private(set) var isFocused: Bool?
    private(set) var label: String?

    var sourceNote: String {
        String(localized: "Rolltop only knows about a Focus that includes Rolltop’s filter with a profile: System Settings › Focus › choose a Focus › Focus Filters › Add Filter › Rolltop.",
               table: "Automation", comment: "Shown next to the Focus state (widgets); the path names System Settings panes and buttons")
    }

    /// The filter ran with this profile (nil: the filter's defaults).
    func filterRan(profileID: String?) {
        isFocused = Self.state(afterFilterWith: profileID)
        label = nil
    }

    /// A profile means a Focus with the filter is on. The defaults mean that Focus ended, or
    /// a filter saved without a profile: Rolltop cannot tell which, so unknown, never "off".
    nonisolated static func state(afterFilterWith profileID: String?) -> Bool? {
        profileID == nil ? nil : true
    }

    #if DEBUG
    /// `interop.debug-focus`: show a state without a Focus.
    func debugSet(isFocused: Bool?, label: String?) {
        self.isFocused = isFocused
        self.label = label
    }
    #endif
}
