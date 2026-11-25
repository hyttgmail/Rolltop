import AppKit
import RolltopCore
import SwiftUI

/// What a shelf and its chips ask the pane to do.
struct LayoutEditorShelfActions {
    var select: (LayoutEditorSelection) -> Void
    /// Drop, context menu, VoiceOver action and the details menu all end here.
    var place: (LayoutEditorPayload, RolltopCore.Section) -> Void
    /// An item dropped on another item of the same shelf: put it left of that item in the
    /// menu bar. False when reordering is not available (the drop then changes section).
    var reorder: (OwnerID, OwnerID) -> Bool = { _, _ in false }
    var showNow: (OwnerID) -> Void
    var canShowNow: (LayoutEditorCluster) -> Bool
    var openShortcuts: () -> Void
}

/// One section drawn as a strip that looks like the menu bar: the owners' items at menu
/// bar size, left to right in menu bar order, wrapping onto more rows. A drop target for
/// chips and for the "New items" marker.
struct LayoutEditorShelf: View {
    let section: RolltopCore.Section
    let clusters: [LayoutEditorCluster]
    let showsMarker: Bool
    let isFiltering: Bool
    let selection: LayoutEditorSelection?
    let services: ServiceLocator
    let actions: LayoutEditorShelfActions

    @State private var isTargeted = false

    static let cornerRadius: CGFloat = 9

    var body: some View {
        LayoutEditorFlowLayout(spacing: 2, rowSpacing: 4) {
            ForEach(clusters) { cluster in
                LayoutEditorChip(cluster: cluster, isSelected: selection == .owner(cluster.owner), services: services,
                                 actions: actions)
            }
            if showsMarker {
                LayoutEditorMarkerChip(section: section, isSelected: selection == .marker, actions: actions)
            }
        }
        .frame(maxWidth: .infinity, minHeight: LayoutEditorChip.height, alignment: .leading)
        .overlay(alignment: .leading) {
            if clusters.isEmpty, !showsMarker {
                Group {
                    if isFiltering {
                        Text("No matching items", tableName: "LayoutEditor")
                    } else {
                        Text("Drag items here", tableName: "LayoutEditor")
                    }
                }
                .font(.callout)
                .foregroundStyle(.tertiary)
                .padding(.leading, 6)
                .accessibilityHidden(true)
            }
        }
        .padding(5)
        .background {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(.quinary)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .opacity(isTargeted ? 1 : 0)
        }
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            guard let payload = items.lazy.compactMap(LayoutEditorPayload.init(stringValue:)).first else { return false }
            actions.place(payload, section)
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
    }
}

// MARK: - Chip

/// One owner on a shelf: all of its items side by side as one draggable cluster, the way
/// they look in the menu bar.
struct LayoutEditorChip: View {
    let cluster: LayoutEditorCluster
    let isSelected: Bool
    let services: ServiceLocator
    let actions: LayoutEditorShelfActions

    static let height: CGFloat = 26
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 6, style: .continuous) }

    var body: some View {
        let base = LayoutEditorItemImages(cluster: cluster, services: services)
            .padding(.horizontal, 2)
            .frame(height: Self.height)
            .background { shape.fill(fill) }
            .overlay {
                if isSelected { shape.strokeBorder(Color.accentColor, lineWidth: 2) }
            }
            .opacity(cluster.drawState == .notDrawn ? 0.45 : 1)
            .overlay(alignment: .topTrailing) { badge }
            .contentShape(shape)
            .onTapGesture { actions.select(.owner(cluster.owner)) }
        draggable(base)
            // Dropped on a chip of the same shelf: reorder (when order access works);
            // otherwise the same as a drop on the shelf.
            .dropDestination(for: String.self) { items, _ in
                guard let payload = items.lazy.compactMap(LayoutEditorPayload.init(stringValue:)).first else { return false }
                if case .owner(let owner) = payload, owner != cluster.owner, actions.reorder(owner, cluster.owner) { return true }
                actions.place(payload, cluster.section)
                return true
            }
            .contextMenu { contextMenu }
            .help(Text(verbatim: cluster.name))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "\(cluster.name), \(OwnerNames.sectionTitle(cluster.section))"))
            .accessibilityValue(Text(verbatim: LayoutEditorText.accessibilityValue(cluster)))
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { actions.select(.owner(cluster.owner)) }
            .accessibilityActions {
                if cluster.isMovable {
                    ForEach(RolltopCore.Section.allCases.filter { $0 != cluster.section }, id: \.self) { target in
                        Button {
                            actions.place(.owner(cluster.owner), target)
                        } label: {
                            Text(verbatim: LayoutEditorText.moveTo(target))
                        }
                    }
                }
            }
            .accessibilityIdentifier("layout-editor.item.\(cluster.id)")
    }

    @ViewBuilder
    private func draggable(_ view: some View) -> some View {
        if cluster.isMovable {
            view.draggable(LayoutEditorPayload.owner(cluster.owner).stringValue) {
                LayoutEditorItemImages(cluster: cluster, services: services)
                    .padding(.horizontal, 4)
                    .frame(height: Self.height)
                    .background(Color(nsColor: .windowBackgroundColor), in: shape)
                    .overlay { shape.strokeBorder(Color.accentColor, lineWidth: 1.5) }
            }
        } else {
            view
        }
    }

    private var fill: Color {
        if isSelected { return Color.accentColor.opacity(0.18) }
        // Several items of one app share a backdrop: they move together.
        return cluster.itemCount > 1 ? Color.primary.opacity(0.07) : .clear
    }

    @ViewBuilder
    private var badge: some View {
        if !cluster.warnings.isEmpty {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.orange)
                .offset(x: 2, y: -1)
        } else if cluster.drawState == .overflowed {
            Image(systemName: "chevron.left.2")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.secondary)
                .offset(x: 2, y: -1)
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        if cluster.isMovable {
            ForEach(RolltopCore.Section.allCases, id: \.self) { target in
                Button {
                    actions.place(.owner(cluster.owner), target)
                } label: {
                    Text(verbatim: LayoutEditorText.moveTo(target))
                }
                .disabled(target == cluster.section)
            }
            Divider()
        }
        Button {
            actions.showNow(cluster.owner)
        } label: {
            Text("Show Now", tableName: "LayoutEditor")
        }
        .disabled(!actions.canShowNow(cluster))
        Button {
            actions.openShortcuts()
        } label: {
            Text("Shortcuts…", tableName: "LayoutEditor")
        }
    }
}

// MARK: - Images

/// The owner's items as the menu bar draws them: real captures when Capture serves them,
/// else one icon (app icons are the same for every item, so the count is written instead).
struct LayoutEditorItemImages: View {
    let cluster: LayoutEditorCluster
    let services: ServiceLocator

    /// Menu bar glyph height (DESIGN.md: 24 pt of content, glyphs a little smaller).
    static let imageHeight: CGFloat = 18
    static let maximumImageWidth: CGFloat = 160
    /// Same cap as the Rolltop Bar.
    static let maximumItems = 8

    var body: some View {
        let provider = services[.itemImages]
        let _ = provider.revision
        // Rolltop's own items always have their own images (never captured, never the app icon).
        let count = provider.usesScreenCapture || cluster.isOwn ? min(Self.maximumItems, cluster.itemCount) : 1
        HStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                itemImage(provider.image(for: cluster.owner, itemIndex: index, height: Self.imageHeight))
                    .padding(.horizontal, 4)
            }
            if count < cluster.itemCount, count == 1 {
                Text(verbatim: "\(cluster.itemCount)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 4)
            }
        }
    }

    @ViewBuilder
    private func itemImage(_ image: NSImage?) -> some View {
        if let image {
            let width = min(Self.maximumImageWidth, image.size.height > 0
                ? Self.imageHeight * image.size.width / image.size.height : Self.imageHeight)
            Image(nsImage: image)
                .renderingMode(image.isTemplate ? .template : .original)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.primary)
                .frame(width: width, height: Self.imageHeight)
        } else {
            Image(systemName: "app.dashed")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.secondary)
                .frame(width: Self.imageHeight, height: Self.imageHeight)
        }
    }
}

// MARK: - Marker

/// "New items appear here": the section for apps Rolltop has not seen yet. Draggable like an
/// item; moving it changes the default section (present items are frozen first).
struct LayoutEditorMarkerChip: View {
    let section: RolltopCore.Section
    let isSelected: Bool
    let actions: LayoutEditorShelfActions

    private var shape: Capsule { Capsule(style: .continuous) }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .semibold))
            Text("New items", tableName: "LayoutEditor")
                .font(.callout)
        }
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 9)
        .frame(height: LayoutEditorChip.height - 4)
        .background { shape.fill(Color.accentColor.opacity(isSelected ? 0.2 : 0.08)) }
        .overlay {
            shape.strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: isSelected ? 2 : 1, dash: isSelected ? [] : [3, 2]))
        }
        .padding(.horizontal, 2)
        .frame(height: LayoutEditorChip.height)
        .contentShape(shape)
        .onTapGesture { actions.select(.marker) }
        .draggable(LayoutEditorPayload.marker.stringValue) {
            Text("New items", tableName: "LayoutEditor")
                .font(.callout)
                .padding(.horizontal, 9)
                .frame(height: LayoutEditorChip.height - 4)
                .background(Color(nsColor: .windowBackgroundColor), in: shape)
                .overlay { shape.strokeBorder(Color.accentColor, lineWidth: 1.5) }
        }
        .contextMenu {
            ForEach(RolltopCore.Section.allCases, id: \.self) { target in
                Button {
                    actions.place(.marker, target)
                } label: {
                    Text(verbatim: LayoutEditorText.newItemsIn(target))
                }
                .disabled(target == section)
            }
        }
        .help(Text("Apps Rolltop hasn’t seen before appear in this section. Drag this to another column to change it; items already in your menu bar stay where they are.",
                   tableName: "LayoutEditor"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: LayoutEditorText.markerLabel(section)))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { actions.select(.marker) }
        .accessibilityActions {
            ForEach(RolltopCore.Section.allCases.filter { $0 != section }, id: \.self) { target in
                Button {
                    actions.place(.marker, target)
                } label: {
                    Text(verbatim: LayoutEditorText.newItemsIn(target))
                }
            }
        }
        .accessibilityIdentifier("layout-editor.marker")
    }
}

// MARK: - Text

/// Strings built from parts (section names come from the shared UI table).
enum LayoutEditorText {
    /// Menu items and VoiceOver actions: Title Case (DESIGN.md, Writing).
    static func moveTo(_ section: RolltopCore.Section) -> String {
        switch section {
        case .shown: String(localized: "Move to Shown", table: "LayoutEditor")
        case .hidden: String(localized: "Move to Hidden", table: "LayoutEditor")
        case .alwaysHidden: String(localized: "Move to Always Hidden", table: "LayoutEditor")
        }
    }

    static func newItemsIn(_ section: RolltopCore.Section) -> String {
        switch section {
        case .shown: String(localized: "Put New Items in Shown", table: "LayoutEditor")
        case .hidden: String(localized: "Put New Items in Hidden", table: "LayoutEditor")
        case .alwaysHidden: String(localized: "Put New Items in Always Hidden", table: "LayoutEditor")
        }
    }

    static func markerLabel(_ section: RolltopCore.Section) -> String {
        String(localized: "New items appear here, \(OwnerNames.sectionTitle(section))", table: "LayoutEditor")
    }

    static func kind(_ cluster: LayoutEditorCluster) -> String {
        if cluster.isOwn { return String(localized: "Rolltop", table: "LayoutEditor") }
        return cluster.isSystem ? String(localized: "System item", table: "LayoutEditor")
            : String(localized: "App", table: "LayoutEditor")
    }

    static func drawState(_ state: LayoutEditorCluster.DrawState) -> String {
        switch state {
        case .drawn: String(localized: "Visible in the menu bar", table: "LayoutEditor")
        case .overflowed: String(localized: "In the menu bar’s overflow menu (no room)", table: "LayoutEditor")
        case .notDrawn: String(localized: "Not in the menu bar", table: "LayoutEditor")
        case .unknown: String(localized: "Unknown", table: "LayoutEditor")
        }
    }

    /// "App · 1 item", "System item · 3 items, which always move together".
    static func kindAndCount(_ cluster: LayoutEditorCluster) -> String {
        kind(cluster) + " · " + itemCount(cluster.itemCount)
    }

    static func itemCount(_ count: Int) -> String {
        String(localized: "\(count) items, which always move together", table: "LayoutEditor")
    }

    static func accessibilityValue(_ cluster: LayoutEditorCluster) -> String {
        var parts = [drawState(cluster.drawState)]
        if cluster.itemCount > 1 { parts.append(itemCount(cluster.itemCount)) }
        parts += cluster.warnings.map { note(for: $0).text }
        return parts.joined(separator: ", ")
    }

    static func shelfDescription(_ section: RolltopCore.Section, inPanel: Bool) -> String {
        switch section {
        case .shown:
            String(localized: "Stays in the menu bar.", table: "LayoutEditor")
        case .hidden:
            inPanel ? String(localized: "Shown in the Rolltop Bar when you click Rolltop’s icon in the menu bar.", table: "LayoutEditor")
                : String(localized: "Shown when you click Rolltop’s icon in the menu bar.", table: "LayoutEditor")
        case .alwaysHidden:
            inPanel ? String(localized: "Shown when you Option-click Rolltop’s icon, and behind the disclosure in the Rolltop Bar.", table: "LayoutEditor")
                : String(localized: "Shown only when you Option-click Rolltop’s icon.", table: "LayoutEditor")
        }
    }

    static func shelfCount(_ count: Int) -> String {
        String(localized: "\(count) items", table: "LayoutEditor")
    }

    /// The system rules behind everything this pane cannot do, in plain words.
    static var limits: [String] {
        [
            String(localized: "Hiding works per app: all of an app’s icons share one section and move together.", table: "LayoutEditor"),
            String(localized: "While Rolltop hides anything, macOS also hides the items it manages itself, such as AirDrop, Focus and Now Playing. They come back when nothing is hidden.",
                   table: "LayoutEditor"),
            String(localized: "macOS hides apps that run from outside the Applications folder whenever Rolltop hides anything, whatever their section.",
                   table: "LayoutEditor"),
            String(localized: "The order of icons is set in the menu bar itself: hold ⌘ and drag an icon. Rolltop can’t change it.", table: "LayoutEditor"),
            String(localized: "Icons that don’t fit in the menu bar go into its overflow menu; Rolltop can’t open items from there.", table: "LayoutEditor"),
            String(localized: "An app started while its section is hidden only shows up here after it has been in the menu bar once.", table: "LayoutEditor"),
        ]
    }

    static func activationError(_ error: any Error) -> String {
        switch error {
        case ItemActivator.ActivationError.accessibilityDenied:
            String(localized: "Rolltop needs Device Control and Data Access to open menu bar items.", table: "LayoutEditor")
        case ItemActivator.ActivationError.notRunning:
            String(localized: "The app isn’t running.", table: "LayoutEditor")
        case ItemActivator.ActivationError.notDrawn:
            String(localized: "The item didn’t appear in the menu bar in time. If it’s in the overflow menu, make room for it first.",
                   table: "LayoutEditor")
        default:
            String(localized: "Couldn’t open the item: \(error.localizedDescription)", table: "LayoutEditor")
        }
    }

    static func note(for note: LayoutEditorNote) -> OwnerNote {
        switch note {
        case .outsideApplications:
            OwnerNote(text: String(localized: "Runs outside the Applications folder, so macOS hides it whenever Rolltop hides anything, whatever its section.",
                                   table: "LayoutEditor"), kind: .warning)
        case .unreadable:
            OwnerNote(text: String(localized: "Rolltop can’t read this app’s items right now.", table: "LayoutEditor"), kind: .warning)
        case .unverifiedModule:
            OwnerNote(text: String(localized: "macOS’s id for this system item wasn’t confirmed on a real Mac, so hiding it may not work.",
                                   table: "LayoutEditor"), kind: .warning)
        case .overflowed:
            OwnerNote(text: String(localized: "Doesn’t fit in the menu bar right now.", table: "LayoutEditor"))
        case .hiddenNow:
            OwnerNote(text: String(localized: "Hidden now", table: "LayoutEditor"))
        case .itemCount(let count):
            OwnerNote(text: String(localized: "\(count) items, which always move together", table: "LayoutEditor"))
        }
    }
}
