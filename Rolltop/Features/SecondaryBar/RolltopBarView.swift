import SwiftUI

/// Draws the Rolltop Bar's cells at the positions the layout computed. Input is handled by
/// `RolltopBarInputView` on top (the app is never active, so SwiftUI hover would not fire).
struct RolltopBarView: View {
    let model: RolltopBarModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(model.cells) { cell in
                cellView(cell)
                    .frame(width: cell.frame.width, height: cell.frame.height)
                    .position(x: cell.frame.midX, y: cell.frame.midY)
            }
        }
        .frame(width: model.size.width, height: model.size.height, alignment: .topLeading)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: model.hovered)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: model.selected)
    }

    @ViewBuilder
    private func cellView(_ cell: RolltopBarModel.Cell) -> some View {
        switch cell.kind {
        case .item(let item):
            ItemCell(item: item, highlight: highlight(cell.id), isSelected: model.isKeyboardMode && model.selected == cell.id,
                     isBusy: model.busy == item.id, isFailed: model.failed == item.id,
                     imageHeight: model.metrics.imageHeight)
        case .separator:
            Capsule()
                .fill(.separator)
                .frame(width: 1, height: model.metrics.rowHeight * 0.6)
        case .disclosure:
            ZStack {
                Capsule().fill(.primary.opacity(highlight(cell.id)))
                if model.isKeyboardMode, model.selected == cell.id {
                    Capsule().strokeBorder(Color.accentColor, lineWidth: 2)
                }
                Image(systemName: model.isExpanded ? "chevron.left" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel(model.isExpanded ? Text("Hide always-hidden items", tableName: "SecondaryBar")
                                : Text("Show always-hidden items", tableName: "SecondaryBar"))
        case .empty:
            Text("No hidden items", tableName: "SecondaryBar")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func highlight(_ id: String) -> Double {
        if model.pressed == id { return 0.18 }
        if model.hovered == id { return 0.10 }
        return 0
    }
}

private struct ItemCell: View {
    let item: RolltopBarModel.Item
    let highlight: Double
    let isSelected: Bool
    let isBusy: Bool
    let isFailed: Bool
    let imageHeight: CGFloat

    var body: some View {
        ZStack {
            Capsule().fill(isFailed ? Color.red.opacity(0.28) : Color.primary.opacity(highlight))
            if isSelected {
                Capsule().strokeBorder(Color.accentColor, lineWidth: 2)
            }
            image
                .opacity(isBusy ? 0.3 : 1)
            if isBusy {
                BusyRing().frame(width: 14, height: 14)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(item.name))
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var image: some View {
        if let nsImage = item.image {
            // Templates (monochrome captures, SF Symbols) take the glass's label colour, so
            // they read on light and dark glass whatever the wallpaper behind the menu bar was.
            Image(nsImage: nsImage)
                .renderingMode(nsImage.isTemplate ? .template : .original)
                .interpolation(.high)
                .foregroundStyle(.primary)
                .frame(width: nsImage.size.width, height: nsImage.size.height)
        } else {
            Image(systemName: "questionmark.app.dashed")
                .font(.system(size: imageHeight * 0.8))
                .foregroundStyle(.secondary)
        }
    }
}

/// Activation in flight. Drawn rather than a `ProgressView`, which does not show in the
/// never-active panel; static under Reduce Motion.
private struct BusyRing: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(reduceMotion ? nil : .linear(duration: 0.8).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = !reduceMotion }
    }
}
