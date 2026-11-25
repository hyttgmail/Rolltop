import AppKit
import SwiftUI

/// Settings › Advanced: diagnostics, the debug state file (Debug builds) and reset.
struct AdvancedPane: View {
    let context: AppContext
    let launchAtLogin: LaunchAtLogin
    @State private var confirmingReset = false
    @State private var copied = false

    var body: some View {
        Form {
            SwiftUI.Section {
                LabeledContent {
                    Button {
                        Diagnostics.current(context, launchAtLogin: launchAtLogin).copyToPasteboard()
                        copied = true
                    } label: {
                        Text(copied ? LocalizedStringResource("Copied", table: "SettingsShell")
                                    : LocalizedStringResource("Copy", table: "SettingsShell"))
                    }
                    .accessibilityIdentifier("advanced.copy-diagnostics")
                } label: {
                    Text("Diagnostics", tableName: "SettingsShell")
                    Text("Versions, permissions, where Rolltop runs from and whether it is hiding anything. No item names or settings.",
                         tableName: "SettingsShell")
                }
                #if DEBUG
                LabeledContent {
                    Button {
                        revealDebugState()
                    } label: {
                        Text("Show in Finder", tableName: "SettingsShell")
                    }
                    .accessibilityIdentifier("advanced.reveal-debug-state")
                } label: {
                    Text("Debug state file", tableName: "SettingsShell")
                    Text(verbatim: (DebugState.url.path as NSString).abbreviatingWithTildeInPath)
                }
                #endif
            }
            SwiftUI.Section {
                LabeledContent {
                    Button(role: .destructive) {
                        confirmingReset = true
                    } label: {
                        Text("Reset…", tableName: "SettingsShell")
                    }
                    .accessibilityIdentifier("advanced.reset")
                } label: {
                    Text("Reset all settings", tableName: "SettingsShell")
                    Text("Every item goes back to Shown and every other Rolltop setting to its default. Open at login and permissions stay as they are.",
                         tableName: "SettingsShell")
                }
            }
        }
        .formStyle(.grouped)
        .alert(Text("Reset all settings?", tableName: "SettingsShell"), isPresented: $confirmingReset) {
            Button(role: .destructive) {
                SettingsReset.resetAll(settings: context.settings, layout: context.layout)
            } label: {
                Text("Reset", tableName: "SettingsShell")
            }
            Button(role: .cancel) {} label: {
                Text("Cancel", tableName: "SettingsShell")
            }
        } message: {
            Text("This can’t be undone.", tableName: "SettingsShell")
        }
    }

    #if DEBUG
    private func revealDebugState() {
        // Write a fresh snapshot first so the file exists and is current.
        Task {
            await context.catalog.refresh()
            try? DebugState.write(context)
            NSWorkspace.shared.activateFileViewerSelecting([DebugState.url])
        }
    }
    #endif
}
