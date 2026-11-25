import RolltopCore
import SwiftUI

/// The list view: one row per owner with a section menu, grouped by section, in menu bar
/// order. The same board and the same edits as the shelves.
struct LayoutEditorListSections: View {
    let context: AppContext
    let board: LayoutEditorBoard
    let isFiltering: Bool
    let actions: LayoutEditorShelfActions

    var body: some View {
        let inPanel = context.services[.revealRouting].presentsHiddenInPanel
        ForEach(RolltopCore.Section.allCases, id: \.self) { section in
            let clusters = board.clusters(in: section)
            SwiftUI.Section {
                ForEach(clusters) { cluster in
                    row(cluster)
                }
                if clusters.isEmpty {
                    Group {
                        if isFiltering {
                            Text("No matching items", tableName: "LayoutEditor")
                        } else {
                            Text("No items", tableName: "LayoutEditor")
                        }
                    }
                    .foregroundStyle(.secondary)
                }
            } header: {
                Text(verbatim: OwnerNames.sectionTitle(section))
            } footer: {
                Text(verbatim: LayoutEditorText.shelfDescription(section, inPanel: inPanel))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func row(_ cluster: LayoutEditorCluster) -> some View {
        let label = OwnerLabel(owner: cluster.owner, name: cluster.name,
                               notes: cluster.notes.map(LayoutEditorText.note(for:)), services: context.services)
        if cluster.isMovable {
            Picker(selection: Binding {
                cluster.section
            } set: { section in
                actions.place(.owner(cluster.owner), section)
            }) {
                ForEach(RolltopCore.Section.allCases, id: \.self) { section in
                    Text(verbatim: OwnerNames.sectionTitle(section)).tag(section)
                }
            } label: {
                label
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("section.\(cluster.id)")
        } else {
            LabeledContent {
                Text("Always shown", tableName: "LayoutEditor")
                    .foregroundStyle(.secondary)
            } label: {
                label
            }
        }
    }
}

/// Below the shelves or the list: saved apps that are not running, and what macOS
/// manages itself or Rolltop cannot identify (read-only).
struct LayoutEditorGroups: View {
    let context: AppContext
    let board: LayoutEditorBoard
    let actions: LayoutEditorShelfActions

    var body: some View {
        if !board.notRunning.isEmpty {
            SwiftUI.Section {
                ForEach(board.notRunning) { saved in
                    LabeledContent {
                        Button {
                            context.layout.setSection(nil, for: saved.owner)
                        } label: {
                            Text("Forget", tableName: "LayoutEditor")
                        }
                        .controlSize(.small)
                        .accessibilityIdentifier("forget.\(saved.id)")
                    } label: {
                        OwnerLabel(owner: saved.owner, name: saved.name,
                                   notes: [OwnerNote(text: String(localized: "Saved in \(OwnerNames.sectionTitle(saved.section))",
                                                                  table: "LayoutEditor"))],
                                   services: context.services)
                    }
                }
            } header: {
                Text("Not running", tableName: "LayoutEditor")
            } footer: {
                Text("These keep their section for the next time they open. Forget one and it follows the section for new items instead.",
                     tableName: "LayoutEditor")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if !board.managed.isEmpty {
            SwiftUI.Section {
                ForEach(board.managed) { item in
                    OwnerLabel(owner: nil, name: item.name, symbol: AppIconImageProvider.symbol(forManagedID: item.id),
                               services: context.services)
                }
            } header: {
                Text("Managed by macOS", tableName: "LayoutEditor")
            } footer: {
                Text("macOS hides these whenever Rolltop hides any item, and brings them back once nothing is hidden. Rolltop can’t keep them visible.",
                     tableName: "LayoutEditor")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if !board.unidentified.isEmpty {
            SwiftUI.Section {
                ForEach(board.unidentified) { item in
                    OwnerLabel(owner: nil, name: item.name, services: context.services)
                }
            } header: {
                Text("Other items", tableName: "LayoutEditor")
            } footer: {
                Text("These items don’t belong to an app Rolltop can identify, so macOS hides them whenever Rolltop hides any item.",
                     tableName: "LayoutEditor")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
