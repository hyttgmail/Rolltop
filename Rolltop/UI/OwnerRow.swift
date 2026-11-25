import AppKit
import RolltopCore
import SwiftUI

/// The icon of a menu bar item's owner, resolved through `services[.itemImages]` at use
/// time (the Capture feature may replace the default provider) and refreshed when the
/// provider's `revision` changes.
struct OwnerIcon: View {
    let owner: OwnerID?
    let services: ServiceLocator
    var size: CGFloat = 20
    /// For items without an owner (macOS-managed extras): the symbol to draw instead of the
    /// generic placeholder (`AppIconImageProvider.symbol(forManagedID:)`).
    var symbol: String?

    /// Captures much wider than tall (the clock's date and time, text items) are unreadable
    /// in a square tile: such owners show their default image there instead.
    static let maximumTileAspect: CGFloat = 2.5
    private static let defaults = AppIconImageProvider()

    var body: some View {
        let provider = services[.itemImages]
        let _ = provider.revision
        Group {
            if let image = owner.flatMap({ tileImage(provider, owner: $0) }) {
                Image(nsImage: image)
                    .renderingMode(image.isTemplate ? .template : .original)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.primary)
            } else if owner == nil, let symbol {
                Image(systemName: symbol)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.primary)
                    .padding(size * 0.1)
            } else {
                Image(systemName: owner == nil ? "menubar.rectangle" : "app.dashed")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func tileImage(_ provider: any ItemImageProviding, owner: OwnerID) -> NSImage? {
        let image = provider.image(for: owner, itemIndex: 0, height: size)
        if let image, image.size.width > size * Self.maximumTileAspect {
            return Self.defaults.image(for: owner, itemIndex: 0, height: size) ?? image
        }
        return image
    }
}

/// One line under an owner's name. Warnings are for limitations that change what the
/// user sees (macOS hides the app anyway, Rolltop cannot read it).
struct OwnerNote: Hashable {
    enum Kind { case info, warning }
    let text: String
    var kind: Kind = .info
}

/// Icon, name and secondary lines of a menu bar item's owner, as a row label. Use it as
/// the label of a `Picker`, `LabeledContent` or `Toggle` so the control sits trailing.
struct OwnerLabel: View {
    let owner: OwnerID?
    let name: String
    var notes: [OwnerNote] = []
    /// See `OwnerIcon.symbol`.
    var symbol: String?
    let services: ServiceLocator

    init(owner: OwnerID?, name: String, notes: [OwnerNote] = [], symbol: String? = nil, services: ServiceLocator) {
        self.owner = owner
        self.name = name
        self.notes = notes
        self.symbol = symbol
        self.services = services
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            OwnerIcon(owner: owner, services: services, symbol: symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                ForEach(notes, id: \.self) { note in
                    NoteLine(note: note)
                }
            }
        }
    }

    private struct NoteLine: View {
        let note: OwnerNote

        var body: some View {
            switch note.kind {
            case .info:
                Text(verbatim: note.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .warning:
                Label {
                    Text(verbatim: note.text)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// Display names for owners that may not be running, and for sections.
enum OwnerNames {
    static func sectionTitle(_ section: RolltopCore.Section) -> String {
        switch section {
        case .shown: String(localized: "Shown", table: "UI")
        case .hidden: String(localized: "Hidden", table: "UI")
        case .alwaysHidden: String(localized: "Always hidden", table: "UI")
        }
    }

    /// The owner's fixed name, also while it is not running (see `ItemCatalog.displayName(for:)`).
    static func name(for owner: OwnerID, catalog: ItemCatalog) -> String {
        catalog.displayName(for: owner)
    }
}
