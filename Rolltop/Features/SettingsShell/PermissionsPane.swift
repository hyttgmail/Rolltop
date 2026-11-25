import SwiftUI

/// Settings › Permissions: live permission state, whether hiding works on this Mac, and
/// where Rolltop runs from.
struct PermissionsPane: View {
    let context: AppContext

    var body: some View {
        Form {
            if !context.permissions.accessibility {
                SwiftUI.Section {
                    LimitationNote(Text("Rolltop can’t hide or list menu bar items until you allow Device Control and Data Access.",
                                        tableName: "SettingsShell"),
                                   tone: .warning)
                }
            }
            SwiftUI.Section {
                PermissionRow(kind: .accessibility, permissions: context.permissions, isRequired: true,
                              purpose: Text("Lets Rolltop see which items are in the menu bar, and open hidden ones.",
                                            tableName: "SettingsShell"))
                PermissionRow(kind: .screenRecording, permissions: context.permissions, isRequired: false,
                              purpose: Text("Shows the real icons of hidden items. Without it, Rolltop shows app icons instead.",
                                            tableName: "SettingsShell"))
            }
            SettingsShellConsentsSection(context: context)
            hidingSection
            if !context.launchInfo.runsFromApplications {
                SwiftUI.Section {
                    LimitationNote(Text("Rolltop is running from \(context.launchInfo.bundlePath). macOS hides the menu bar items of apps outside the Applications folder, Rolltop’s own included. Move Rolltop to Applications and open it again.",
                                        tableName: "SettingsShell"),
                                   tone: .warning)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { context.permissions.refresh() }
        .task { await SettingsShellConsentsSection.pollStatuses(context.services[.consents]) }
    }

    private var hidingSection: some View {
        let visibility = context.visibility
        return SwiftUI.Section {
            LabeledContent {
                if visibility.isAvailable {
                    Label {
                        Text("Available", tableName: "SettingsShell")
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                } else {
                    Label {
                        Text("Unavailable", tableName: "SettingsShell")
                    } icon: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    }
                }
            } label: {
                Text("Hiding menu bar items", tableName: "SettingsShell")
                if visibility.isAvailable {
                    Text("macOS lets Rolltop hide items on this Mac.", tableName: "SettingsShell")
                } else {
                    Text("This version of macOS doesn’t offer what Rolltop uses to hide items, so every item stays visible.",
                         tableName: "SettingsShell")
                }
            }
            if let error = visibility.lastError {
                LabeledContent {
                    if let date = visibility.lastErrorDate {
                        Text(date, style: .relative)
                            .foregroundStyle(.secondary)
                    }
                } label: {
                    Text("Last problem", tableName: "SettingsShell")
                    Text(verbatim: error)
                }
            }
        }
    }
}
