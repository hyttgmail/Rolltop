import SwiftUI

/// A plain inline statement of something macOS imposes (or a state that limits Rolltop),
/// placed where it applies: a form row, a section footer, a banner at the top of a pane.
struct LimitationNote<Accessory: View>: View {
    enum Tone { case info, warning }

    let text: Text
    var tone: Tone = .info
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: tone == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(tone == .warning ? Color.orange : Color.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                text
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                accessory()
            }
            Spacer(minLength: 0)
        }
    }
}

extension LimitationNote where Accessory == EmptyView {
    init(_ text: Text, tone: Tone = .info) {
        self.init(text: text, tone: tone) { EmptyView() }
    }
}
