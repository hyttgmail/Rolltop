import SwiftUI

/// The result rows at the positions the model's scroll offset gives. Input is handled by
/// `PaletteListInputView` on top.
struct PaletteListView: View {
    let model: PaletteModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let metrics = model.metrics
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if model.results.isEmpty {
                    Group {
                        if model.query.isEmpty {
                            Text("Nothing to show yet", tableName: "CommandPalette")
                        } else {
                            Text("No results", tableName: "CommandPalette")
                        }
                    }
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: geometry.size.width, height: metrics.rowHeight)
                        .offset(y: metrics.listInset)
                } else {
                    // Rows are captured with their index: a ForEach over indices would read
                    // stale indices while the results shrink.
                    ForEach(visibleRows(height: geometry.size.height)) { visible in
                        PaletteRowView(row: visible.row, index: visible.index,
                                       highlight: highlight(visible.index), isSelected: model.selected == visible.index,
                                       metrics: metrics)
                            .frame(width: geometry.size.width - 2 * metrics.horizontalInset, height: metrics.rowHeight)
                            .offset(x: metrics.horizontalInset,
                                    y: metrics.listInset + CGFloat(visible.index) * metrics.rowHeight - model.scroll.offset)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .clipped()
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: model.selected)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: model.hovered)
    }

    private struct VisibleRow: Identifiable {
        let index: Int
        let row: PaletteRow
        var id: String { row.id }
    }

    private func visibleRows(height: CGFloat) -> [VisibleRow] {
        let metrics = model.metrics
        let results = model.results
        let first = max(0, Int((model.scroll.offset / metrics.rowHeight).rounded(.down)))
        let count = Int((height / metrics.rowHeight).rounded(.up)) + 1
        guard first < results.count else { return [] }
        return (first..<min(results.count, first + count)).map { VisibleRow(index: $0, row: results[$0]) }
    }

    private func highlight(_ index: Int) -> Double {
        if model.pressed == index { return 0.2 }
        if model.selected == index { return 0.14 }
        if model.hovered == index { return 0.07 }
        return 0
    }
}

struct PaletteRowView: View {
    let row: PaletteRow
    let index: Int
    let highlight: Double
    let isSelected: Bool
    let metrics: PaletteMetrics

    var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(.title3)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let subtitle = row.subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if row.isOn {
                Image(systemName: "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if let tag = row.tag {
                Text(tag)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.primary.opacity(0.07)))
                    .lineLimit(1)
                    .fixedSize()
            }
            if index < 9 {
                Text(verbatim: "⌘\(index + 1)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(minWidth: 24, alignment: .trailing)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: metrics.rowCornerRadius, style: .continuous)
                .fill(.primary.opacity(highlight))
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var icon: some View {
        switch row.icon {
        case .image(let image)?:
            Image(nsImage: image)
                .renderingMode(image.isTemplate ? .template : .original)
                .interpolation(.high)
                .foregroundStyle(.primary)
                .frame(width: min(image.size.width, 28), height: min(image.size.height, 28))
        case .symbol(let name)?:
            Image(systemName: name)
                .font(.title3)
                .foregroundStyle(.secondary)
        case nil:
            EmptyView()
        }
    }
}

/// Compact key hints, or a message after a failed run; the palette's shortcut on the right.
struct PaletteFooterView: View {
    let model: PaletteModel
    var onSetShortcut: (() -> Void)?

    var body: some View {
        HStack(spacing: 14) {
            if let message = model.message {
                Label {
                    Text(message).lineLimit(1)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .foregroundStyle(.secondary)
            } else {
                hint("↩", Text("Open", tableName: "CommandPalette"))
                // The provider's title is already localized ("Paste").
                if let title = model.secondActionTitle { hint("⌘↩", Text(verbatim: title)) }
                hint("⇧↩", Text("Right-click", tableName: "CommandPalette"))
                hint("⌘1–9", Text("Run", tableName: "CommandPalette"))
                hint("esc", Text("Close", tableName: "CommandPalette"))
            }
            Spacer(minLength: 8)
            if let shortcut = model.shortcut {
                HStack(spacing: 4) {
                    Text("Search", tableName: "CommandPalette")
                    Text(verbatim: shortcut).fontWeight(.medium)
                }
                .foregroundStyle(.secondary)
            } else if let onSetShortcut {
                Button(action: onSetShortcut) {
                    Text("Set Shortcut…", tableName: "CommandPalette")
                }
                .buttonStyle(.link)
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func hint(_ keys: String, _ label: Text) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: keys).fontWeight(.medium).foregroundStyle(.secondary)
            label.foregroundStyle(.tertiary)
        }
    }
}
