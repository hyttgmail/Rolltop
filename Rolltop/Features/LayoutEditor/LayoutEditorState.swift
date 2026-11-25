import Foundation
import Observation
import RolltopCore

/// How the Menu Bar Items pane presents the layout.
nonisolated enum LayoutEditorViewMode: String, CaseIterable, Sendable {
    /// Three strips that look like the menu bar, with drag and drop.
    case shelves
    /// One row per item with a section menu.
    case list
}

enum LayoutEditorSettings {
    /// The view the pane opens in. Runtime state (marked transient): exports, imports and
    /// profiles leave it alone.
    static let viewMode = SettingsKey<String>("rolltop.layout-editor.view-mode", default: LayoutEditorViewMode.shelves.rawValue)
}

/// The pane's UI state. Owned by the feature so it survives switching panes and closing
/// the window, and so Debug commands can drive what a live test cannot type.
@Observable
final class LayoutEditorUIState {
    var selection: LayoutEditorSelection?
    var query = ""
    /// The last "Show Now" failure, shown in the item details until the selection changes.
    var activationError: String?
}
