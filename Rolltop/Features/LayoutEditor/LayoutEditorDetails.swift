import RolltopCore
import SwiftUI

/// The selected item (or the marker), as rows placed right under the shelf that holds it,
/// so they show next to the click even at the window's default height: what it is, where
/// it is, whether it is in the menu bar now, and what can be done with it.
struct LayoutEditorDetails: View {
    let context: AppContext
    let state: LayoutEditorUIState
    let board: LayoutEditorBoard
    let actions: LayoutEditorShelfActions

    var body: some View {
        switch state.selection {
        case .owner(let owner):
            if let cluster = board.cluster(for: owner) {
                clusterDetails(cluster)
            }
        case .marker:
            markerDetails
        case nil:
            EmptyView()
        }
    }

    // MARK: Item

    @ViewBuilder
    private func clusterDetails(_ cluster: LayoutEditorCluster) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                Button {
                    actions.openShortcuts()
                } label: {
                    Text("Shortcuts…", tableName: "LayoutEditor")
                }
                .accessibilityIdentifier("layout-editor.details.shortcuts")
                Button {
                    actions.showNow(cluster.owner)
                } label: {
                    Text("Show Now", tableName: "LayoutEditor")
                }
                .disabled(!actions.canShowNow(cluster))
                .help(Text("Opens the item’s menu, showing it in the menu bar for a moment if it’s hidden.", tableName: "LayoutEditor"))
                .accessibilityIdentifier("layout-editor.details.show-now")
            }
            .controlSize(.small)
        } label: {
            OwnerLabel(owner: cluster.owner, name: cluster.name,
                       notes: [OwnerNote(text: LayoutEditorText.kindAndCount(cluster)),
                               OwnerNote(text: LayoutEditorText.drawState(cluster.drawState))],
                       services: context.services)
                .accessibilityIdentifier("layout-editor.details.name")
        }
        if cluster.isMovable {
            sectionPicker(for: cluster.owner, current: cluster.section)
        } else {
            LabeledContent {
                Text("Always shown", tableName: "LayoutEditor")
            } label: {
                Text("Section", tableName: "LayoutEditor")
            }
        }
        ForEach(cluster.warnings, id: \.self) { note in
            LimitationNote(Text(verbatim: LayoutEditorText.note(for: note).text), tone: .warning)
        }
        if let error = state.activationError {
            LimitationNote(Text(verbatim: error), tone: .warning)
        }
    }

    // MARK: Marker

    @ViewBuilder
    private var markerDetails: some View {
        Picker(selection: Binding {
            board.defaultSection
        } set: { section in
            actions.place(.marker, section)
        }) {
            ForEach(RolltopCore.Section.allCases, id: \.self) { section in
                Text(verbatim: OwnerNames.sectionTitle(section)).tag(section)
            }
        } label: {
            Text("Section for new items", tableName: "LayoutEditor")
            Text("Apps Rolltop hasn’t seen before appear here. Items already in your menu bar keep their section.",
                 tableName: "LayoutEditor")
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("layout-editor.details.default-section")
    }

    // MARK: Helpers

    private func sectionPicker(for owner: OwnerID, current: RolltopCore.Section) -> some View {
        Picker(selection: Binding {
            current
        } set: { section in
            actions.place(.owner(owner), section)
        }) {
            ForEach(RolltopCore.Section.allCases, id: \.self) { section in
                Text(verbatim: OwnerNames.sectionTitle(section)).tag(section)
            }
        } label: {
            Text("Section", tableName: "LayoutEditor")
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("layout-editor.details.section")
    }
}
