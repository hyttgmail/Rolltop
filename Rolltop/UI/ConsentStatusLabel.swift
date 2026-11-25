import SwiftUI

/// A consent's status in the visual language of `PermissionStatus`: a coloured symbol and a
/// short word. Reasons (`cannotAskNow`, `unavailable`) are shown by the row, not here.
/// Used by Settings › Permissions; features may show it next to their own switches.
struct ConsentStatusLabel: View {
    /// Nil while the status has not been read yet.
    let status: ConsentStatus?

    var body: some View {
        Label {
            text
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
    }

    private var text: Text {
        switch status {
        case .allowed: Text("Allowed", tableName: "UI")
        case .notAllowed: Text("Not allowed", tableName: "UI")
        case .notAsked: Text("Not asked yet", tableName: "UI")
        case .cannotAskNow: Text("Can’t ask now", tableName: "UI")
        case .unavailable: Text("Unavailable", tableName: "UI")
        case nil: Text("Checking…", tableName: "UI")
        }
    }

    private var symbol: String {
        switch status {
        case .allowed: "checkmark.circle.fill"
        case .notAllowed: "exclamationmark.circle.fill"
        case .notAsked: "circle.dashed"
        case .cannotAskNow: "clock"
        case .unavailable: "xmark.circle.fill"
        case nil: "ellipsis.circle"
        }
    }

    private var color: Color {
        switch status {
        case .allowed: .green
        case .notAllowed: .orange
        case .unavailable: .red
        case .notAsked, .cannotAskNow, nil: .secondary
        }
    }
}
