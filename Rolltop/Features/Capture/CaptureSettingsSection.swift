import SwiftUI

/// The "Item images" section: the capture toggle and the Screen Recording row. Hosted by
/// the Rolltop Bar settings pane (the panel is where captured images show).
struct CaptureSettingsSection: View {
    let context: AppContext

    var body: some View {
        let settings = context.settings
        let permissions = context.permissions
        Section {
            Toggle(isOn: Binding(get: { settings[CaptureSettings.enabled] },
                                 set: { settings[CaptureSettings.enabled] = $0 })) {
                Text("Show real item images", tableName: "Capture")
                Text("Shows each item as it looks in the menu bar. Without Screen & System Audio Recording, app icons are shown.",
                     tableName: "Capture")
            }
            LabeledContent {
                if permissions.screenRecording {
                    Label { Text("Allowed", tableName: "Capture") } icon: { Image(systemName: "checkmark.circle.fill") }
                        .foregroundStyle(.secondary)
                } else if settings[CaptureSettings.requestedAccess] {
                    Button { permissions.openSettings(for: .screenRecording) } label: {
                        Text("Open System Settings", tableName: "Capture")
                    }
                } else {
                    Button {
                        // A user click: the only place Rolltop may show the system prompt.
                        settings[CaptureSettings.requestedAccess] = true
                        permissions.requestScreenRecording()
                    } label: {
                        Text("Allow…", tableName: "Capture")
                    }
                }
            } label: {
                Text("Screen & System Audio Recording", tableName: "Capture")
                Text("Used only to capture the menu bar and to match the Rolltop Bar to what is behind it. Nothing leaves this Mac. macOS may ask you to reopen Rolltop after allowing it.",
                     tableName: "Capture")
            }
            LabeledContent {
                Button {
                    context.commands.runDetached("capture.clear-cache", source: .internal)
                } label: {
                    Text("Clear", tableName: "Capture")
                }
            } label: {
                Text("Saved item images", tableName: "Capture")
                Text("Images of hidden items are kept so they can be shown while hidden.", tableName: "Capture")
            }
        } header: {
            Text("Item images", tableName: "Capture")
        }
    }
}
