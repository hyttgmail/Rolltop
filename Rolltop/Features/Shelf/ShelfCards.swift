import AppKit
import SwiftUI

// Cards at the top of the shelf: what is playing (`.nowPlaying`, Media) and the weather
// (`.weather`, Weather). The shelf never sends an Apple event or a request itself: only
// the services do.

/// What the Now Playing card shows. Nil (no card) while nothing is playing or the card is off.
nonisolated struct ShelfNowPlayingCard: Equatable, Sendable {
    var title: String
    var subtitle: String
    var isPlaying: Bool
    var controlsEnabled: Bool
    /// Rolltop may not control the player: the card says so and links to Permissions.
    var needsPermission: Bool

    static func make(state: NowPlayingState?, canControl: Bool, isOn: Bool) -> ShelfNowPlayingCard? {
        guard isOn, let state else { return nil }
        let subtitle = [state.artist, state.player.displayName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return ShelfNowPlayingCard(title: state.title, subtitle: subtitle, isPlaying: state.isPlaying,
                                   controlsEnabled: canControl, needsPermission: !canControl)
    }
}

/// What the weather card shows: data, or "needs setup" (weather on, no report yet).
/// Nil (no card) while weather is off or the card is off.
nonisolated enum ShelfWeatherCard: Equatable, Sendable {
    case report(WeatherReport)
    case needsSetup

    static func make(isEnabled: Bool, report: WeatherReport?, isOn: Bool) -> ShelfWeatherCard? {
        guard isOn, isEnabled else { return nil }
        return report.map { .report($0) } ?? .needsSetup
    }
}

struct ShelfCardsRow: View {
    let controller: ShelfController

    var body: some View {
        let config = controller.config
        let player = controller.nowPlaying
        let music = ShelfNowPlayingCard.make(state: player.state, canControl: player.canControl, isOn: config.nowPlayingCard)
        let provider = controller.weather
        let weather = ShelfWeatherCard.make(isEnabled: provider.isEnabled, report: provider.report, isOn: config.weatherCard)
        if music != nil || weather != nil {
            HStack(spacing: 8) {
                if let music { ShelfNowPlayingCardView(controller: controller, card: music, artwork: player.artwork) }
                if let weather { ShelfWeatherCardView(controller: controller, card: weather, attribution: provider.attribution) }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }
}

private struct ShelfCardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct ShelfNowPlayingCardView: View {
    let controller: ShelfController
    let card: ShelfNowPlayingCard
    let artwork: NSImage?

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let artwork {
                    Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "music.note").font(.title3).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.primary.opacity(0.08))
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: card.title).font(.callout.weight(.medium)).lineLimit(1)
                Text(verbatim: card.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if card.needsPermission {
                    HStack(spacing: 6) {
                        Text("Rolltop needs permission to control the player.", tableName: "Shelf")
                            .font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        Button {
                            controller.openSettings(pane: "permissions")
                        } label: {
                            Text("Permissions…", tableName: "Shelf").font(.caption2)
                        }
                        .buttonStyle(.link)
                        .fixedSize()
                        .help(Text("Open Settings › Permissions", tableName: "Shelf"))
                    }
                } else {
                    HStack(spacing: 10) {
                        control("backward.fill", .previous, Text("Previous", tableName: "Shelf"))
                        control(card.isPlaying ? "pause.fill" : "play.fill", .playPause,
                                card.isPlaying ? Text("Pause", tableName: "Shelf") : Text("Play", tableName: "Shelf"))
                        control("forward.fill", .next, Text("Next", tableName: "Shelf"))
                    }
                    .disabled(!card.controlsEnabled)
                }
            }
        }
        .modifier(ShelfCardBackground())
    }

    private func control(_ symbol: String, _ command: NowPlayingCommand, _ label: Text) -> some View {
        Button {
            controller.perform(command)
            controller.send(.interacted)
        } label: {
            Image(systemName: symbol).accessibilityLabel(label)
        }
        .buttonStyle(.borderless)
        .help(label)
    }
}

private struct ShelfWeatherCardView: View {
    let controller: ShelfController
    let card: ShelfWeatherCard
    let attribution: WeatherAttribution

    var body: some View {
        Group {
            switch card {
            case .report(let report):
                HStack(spacing: 8) {
                    Image(systemName: report.symbolName)
                        .symbolRenderingMode(.multicolor)
                        .font(.title2)
                        .frame(width: 36)
                        .accessibilityLabel(Text(verbatim: report.condition.localizedName))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: "\(report.temperature.formatted(.measurement(width: .narrow, usage: .weather, numberFormatStyle: .number.precision(.fractionLength(0))))) · \(report.condition.localizedName)")
                            .font(.callout.weight(.medium)).lineLimit(1)
                        Text("\(report.placeName) · H \(ShelfCardFormat.temperature(report.todayHigh)) L \(ShelfCardFormat.temperature(report.todayLow)) · \(report.fetchedAt.formatted(date: .omitted, time: .shortened))",
                             tableName: "Shelf")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Link(attribution.text, destination: attribution.url).font(.caption2)
                    }
                }
            case .needsSetup:
                VStack(alignment: .leading, spacing: 4) {
                    Label { Text("Choose a place for the weather", tableName: "Shelf") } icon: { Image(systemName: "cloud.sun") }
                        .font(.callout)
                    Button { controller.openSettings(pane: "weather") } label: { Text("Weather Settings…", tableName: "Shelf") }
                        .controlSize(.small)
                }
            }
        }
        .modifier(ShelfCardBackground())
    }
}

enum ShelfCardFormat {
    static func temperature(_ value: Measurement<UnitTemperature>) -> String {
        value.formatted(.measurement(width: .narrow, usage: .weather, numberFormatStyle: .number.precision(.fractionLength(0))))
    }
}

#if DEBUG
/// Debug: a Now Playing provider with injected data (live tests never touch a player).
@Observable
final class ShelfSampleNowPlaying: NowPlayingProviding {
    var state: NowPlayingState?
    var artwork: NSImage?
    var canControl: Bool

    init(state: NowPlayingState?, artwork: NSImage?, canControl: Bool) {
        self.state = state
        self.artwork = artwork
        self.canControl = canControl
    }

    func perform(_ command: NowPlayingCommand) async -> Bool {
        guard canControl, state != nil else { return false }
        if command == .playPause { state?.isPlaying.toggle() }
        return true
    }
}

/// Debug: a weather provider with injected data (no request is made).
@Observable
final class ShelfSampleWeather: WeatherProviding {
    var isEnabled: Bool
    var report: WeatherReport?
    var lastError: String?

    init(isEnabled: Bool, report: WeatherReport?) {
        self.isEnabled = isEnabled
        self.report = report
    }

    func refresh() async {}
}
#endif
