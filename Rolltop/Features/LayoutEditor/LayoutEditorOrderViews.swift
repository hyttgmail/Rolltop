import AppKit
import RolltopCore
import SwiftUI

/// Above the shelves: what happened to the last reorder, or (before order access) one
/// line and a button to the consent row.
struct LayoutEditorOrderNotes: View {
    let context: AppContext
    let order: LayoutEditorOrderModel
    let showsAccess: Bool

    var body: some View {
        if let message = order.message {
            SwiftUI.Section {
                LimitationNote(text: Text(verbatim: message), tone: .warning) {
                    Button {
                        order.clearMessage()
                    } label: {
                        Text("OK", tableName: "LayoutEditor")
                    }
                }
            }
        } else if showsAccess, !order.orderAccess.canRead {
            SwiftUI.Section {
                LimitationNote(text: Text("To reorder items here, allow Rolltop to change the menu bar order.", tableName: "LayoutEditor")) {
                    LayoutEditorPermissionsButton(context: context)
                }
                if let problem = order.orderAccess.chooseProblem {
                    LimitationNote(Text(verbatim: problem), tone: .warning)
                }
            }
        }
    }
}

/// Below the shelves: the apps switched off in System Settings › Menu Bar, read from
/// Control Center's allow list once the user allowed it.
struct LayoutEditorTurnedOffSection: View {
    let context: AppContext
    let order: LayoutEditorOrderModel

    static let menuBarSettingsURL = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension")!

    var body: some View {
        SwiftUI.Section {
            if !order.allowListAccess.canRead {
                LimitationNote(text: Text("Rolltop can list the apps you turned off in System Settings › Menu Bar once you allow it to read that list.",
                                          tableName: "LayoutEditor")) {
                    LayoutEditorPermissionsButton(context: context)
                }
                if let problem = order.allowListAccess.chooseProblem {
                    LimitationNote(Text(verbatim: problem), tone: .warning)
                }
            } else {
                switch order.turnedOff {
                case .notLoaded:
                    Text("Reading…", tableName: "LayoutEditor")
                        .foregroundStyle(.secondary)
                case .unreadable:
                    LimitationNote(Text("Rolltop couldn’t read the list of apps turned off in System Settings.", tableName: "LayoutEditor"),
                                   tone: .warning)
                case .notRecognized:
                    LimitationNote(Text("Rolltop doesn’t recognize how this version of macOS stores that list.", tableName: "LayoutEditor"),
                                   tone: .warning)
                case .apps(let ids):
                    if ids.isEmpty {
                        Text("No apps are turned off.", tableName: "LayoutEditor")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(ids, id: \.self) { id in
                        OwnerLabel(owner: .app(id), name: context.catalog.displayName(for: .app(id)), services: context.services)
                    }
                    LabeledContent {
                        Button {
                            NSWorkspace.shared.open(Self.menuBarSettingsURL)
                        } label: {
                            Text("Open Menu Bar Settings", tableName: "LayoutEditor")
                        }
                    } label: {
                        Text("macOS itself keeps these apps out of the menu bar. Turn them on again in System Settings › Menu Bar.",
                             tableName: "LayoutEditor")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } header: {
            Text("Turned off in System Settings", tableName: "LayoutEditor")
        }
        .accessibilityIdentifier("layout-editor.turned-off")
    }
}

/// Leads to the two consent rows in Settings › Permissions.
struct LayoutEditorPermissionsButton: View {
    let context: AppContext

    var body: some View {
        Button {
            context.services[.settingsWindow].showSettings(paneID: "permissions")
        } label: {
            Text("Open Permissions", tableName: "LayoutEditor")
        }
    }
}
