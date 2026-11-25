import AppKit
import RolltopCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Backup: export, import (with a preview and a choice of parts), automatic
/// local backups with Restore and Show in Finder, and reset.
struct InteropBackupPane: View {
    let context: AppContext
    let backups: InteropBackupController

    @State private var importing: InteropPendingImport?
    @State private var restoring: InteropLocalBackup?
    @State private var resetting: InteropBackupController.ResetScope?
    @State private var errorMessage: String?
    @State private var doneMessage: String?

    static var contentType: UTType { UTType(filenameExtension: InteropBackupFile.fileExtension, conformingTo: .json) ?? .json }

    var body: some View {
        Form {
            SwiftUI.Section {
                LabeledContent {
                    Button { export() } label: { Text("Export…", tableName: "Automation") }
                        .accessibilityIdentifier("backup.export")
                } label: {
                    Text("Export a backup", tableName: "Automation")
                    Text("Saves settings, the menu bar layout, profiles and automations in one file. Script approvals and link permissions stay on this Mac.",
                         tableName: "Automation")
                }
                LabeledContent {
                    Button { chooseImport() } label: { Text("Import…", tableName: "Automation") }
                        .accessibilityIdentifier("backup.import")
                } label: {
                    Text("Import a backup", tableName: "Automation")
                    Text("Shows what the file holds and lets you choose what to bring in. Your current setup is saved first.",
                         tableName: "Automation")
                }
                if let doneMessage {
                    LimitationNote(Text(verbatim: doneMessage))
                }
            }

            SwiftUI.Section {
                if backups.localBackups.isEmpty {
                    Text("None yet. Rolltop saves one before every import, restore and reset.", tableName: "Automation")
                        .foregroundStyle(.secondary)
                }
                ForEach(backups.localBackups) { backup in
                    LabeledContent {
                        HStack {
                            Button { restoring = backup } label: { Text("Restore…", tableName: "Automation") }
                            Button { backups.showInFinder(backup) } label: { Text("Show in Finder", tableName: "Automation") }
                        }
                    } label: {
                        Text(verbatim: backup.createdAt.formatted(date: .abbreviated, time: .shortened))
                        Text(InteropBackupText.reason(backup.reason))
                    }
                }
            } header: {
                Text("Automatic backups", tableName: "Automation")
            } footer: {
                Text("The ten newest are kept in ~/Library/Application Support/Rolltop/Backups.", tableName: "Automation")
            }

            SwiftUI.Section {
                LabeledContent {
                    Button(role: .destructive) { resetting = .layout } label: { Text("Reset Layout…", tableName: "Automation") }
                } label: {
                    Text("Reset the menu bar layout", tableName: "Automation")
                    Text("Every item goes back to Shown. Settings, profiles and automations stay.", tableName: "Automation")
                }
                LabeledContent {
                    Button(role: .destructive) { resetting = .everything } label: { Text("Reset Everything…", tableName: "Automation") }
                } label: {
                    Text("Reset everything", tableName: "Automation")
                    Text("Removes profiles and automations, puts every item back in Shown and every setting back to its default, and forgets link permissions. Open at login and macOS permissions stay.",
                         tableName: "Automation")
                }
            } header: {
                Text("Reset", tableName: "Automation")
            } footer: {
                Text("Rolltop saves an automatic backup first, so a reset can be undone with Restore.", tableName: "Automation")
            }
        }
        .formStyle(.grouped)
        .task { await backups.refreshLocalBackups() }
        .sheet(item: $importing) { pending in
            InteropImportSheet(pending: pending, backups: backups) { result in
                importing = nil
                switch result {
                case .imported: doneMessage = String(localized: "Imported. An automatic backup of the previous setup is listed below.", table: "Automation")
                case .failed(let message): errorMessage = message
                case .cancelled: break
                }
            }
        }
        .alert(Text("Restore this backup?", tableName: "Automation"),
               isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } }), presenting: restoring) { backup in
            Button { restore(backup) } label: { Text("Restore", tableName: "Automation") }
            Button(role: .cancel) {} label: { Text("Cancel", tableName: "Automation") }
        } message: { _ in
            // What a restore does to scripts, said in the confirmation (approvals stay on this
            // Mac but are not given back to restored scripts).
            let restores = String(localized: "Settings, layout, profiles and automations go back to how they were then. Your current setup is saved first.", table: "Automation")
            let scripts = String(localized: "Automations with scripts and script widgets come back turned off; turn them on again in their settings.",
                                 table: "Automation")
            Text(verbatim: String(localized: "\(restores) \(scripts)", table: "Automation",
                                  comment: "Two sentences shown as one paragraph (Chinese joins them without a space)"))
        }
        .alert(resetting == .layout ? Text("Reset the menu bar layout?", tableName: "Automation") : Text("Reset everything?", tableName: "Automation"),
               isPresented: Binding(get: { resetting != nil }, set: { if !$0 { resetting = nil } }), presenting: resetting) { scope in
            Button(role: .destructive) { reset(scope) } label: { Text("Reset", tableName: "Automation") }
            Button(role: .cancel) {} label: { Text("Cancel", tableName: "Automation") }
        } message: { _ in
            Text("An automatic backup is saved first.", tableName: "Automation")
        }
        .alert(Text("Something went wrong", tableName: "Automation"),
               isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(role: .cancel) {} label: { Text("OK", tableName: "Automation") }
        } message: {
            Text(verbatim: errorMessage ?? "")
        }
    }

    // MARK: Actions

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.contentType]
        panel.nameFieldStringValue = String(localized: "Rolltop Backup \(Date().formatted(.iso8601.year().month().day())).\(InteropBackupFile.fileExtension)",
                                            table: "Automation")
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                do {
                    try await backups.export(to: url)
                    doneMessage = String(localized: "Exported to \(url.lastPathComponent).", table: "Automation")
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func chooseImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.contentType, .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                do {
                    let file = try await backups.read(url)
                    importing = InteropPendingImport(url: url, file: file, preview: backups.preview(of: file))
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func restore(_ backup: InteropLocalBackup) {
        Task {
            do {
                try await backups.restore(backup)
                doneMessage = String(localized: "Restored the backup from \(backup.createdAt.formatted(date: .abbreviated, time: .shortened)).",
                                     table: "Automation")
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func reset(_ scope: InteropBackupController.ResetScope) {
        Task {
            do {
                try await backups.reset(scope)
                doneMessage = String(localized: "Reset. The previous setup is listed under Automatic backups.", table: "Automation")
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct InteropPendingImport: Identifiable {
    let id = UUID()
    let url: URL
    let file: InteropBackupFile
    let preview: InteropBackupPreview
}

/// What the file holds and which parts to bring in.
struct InteropImportSheet: View {
    enum Result { case imported, failed(String), cancelled }

    let pending: InteropPendingImport
    let backups: InteropBackupController
    let onFinish: (Result) -> Void

    @State private var selected: Set<InteropBackupPart> = []
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                SwiftUI.Section {
                    LabeledContent {
                        Text(verbatim: pending.preview.createdAt.formatted(date: .abbreviated, time: .shortened))
                    } label: {
                        Text("Created", tableName: "Automation")
                    }
                    LabeledContent {
                        Text(verbatim: pending.preview.appVersion)
                    } label: {
                        Text("Rolltop version", tableName: "Automation")
                    }
                    if pending.preview.isFromNewerVersion || !pending.preview.skippedSettings.isEmpty {
                        LimitationNote(Text("This backup comes from a newer version of Rolltop. Parts this version does not know are skipped.",
                                            tableName: "Automation"), tone: .warning)
                    }
                } header: {
                    Text(verbatim: pending.url.lastPathComponent)
                }
                SwiftUI.Section {
                    ForEach(pending.preview.parts) { part in
                        Toggle(isOn: Binding(get: { selected.contains(part.part) },
                                             set: { if $0 { selected.insert(part.part) } else { selected.remove(part.part) } })) {
                            Text(verbatim: part.title)
                            if part.isAvailable {
                                Text(verbatim: part.summary)
                            } else {
                                Text("Not used by this version of Rolltop; skipped.", tableName: "Automation")
                            }
                        }
                        .disabled(!part.isAvailable)
                    }
                } header: {
                    Text("Bring in", tableName: "Automation")
                } footer: {
                    Text("What you bring in replaces what you have now. Imported automations with scripts arrive turned off.",
                         tableName: "Automation")
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button(role: .cancel) { onFinish(.cancelled) } label: { Text("Cancel", tableName: "Automation") }
                    .keyboardShortcut(.cancelAction)
                Button {
                    run()
                } label: {
                    Text("Import", tableName: "Automation")
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty || working)
            }
            .padding([.horizontal, .bottom], 20)
        }
        // A grouped Form has no height of its own: give the sheet one.
        .frame(width: 460, height: Self.height(parts: pending.preview.parts.count, warning: pending.preview.isFromNewerVersion
                                                    || !pending.preview.skippedSettings.isEmpty))
        .onAppear { selected = Set(pending.preview.parts.filter(\.isAvailable).map(\.part)) }
    }

    static func height(parts: Int, warning: Bool) -> CGFloat {
        CGFloat(300 + 56 * parts + (warning ? 60 : 0))
    }

    private func run() {
        working = true
        Task {
            do {
                try await backups.importBackup(pending.file, parts: selected)
                onFinish(.imported)
            } catch {
                onFinish(.failed(error.localizedDescription))
            }
        }
    }
}

enum InteropBackupText {
    static func reason(_ reason: String) -> String {
        switch reason {
        case "before-import": String(localized: "Before an import", table: "Automation")
        case "before-restore": String(localized: "Before a restore", table: "Automation")
        case "before-reset": String(localized: "Before a reset", table: "Automation")
        case "export": String(localized: "Exported", table: "Automation")
        default: reason
        }
    }
}
