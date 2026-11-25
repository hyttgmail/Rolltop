import AppKit
import Foundation
import RolltopCore

enum MediaSettings {
    /// Bundle ids of the players whose consent row the user clicked (the consent marker).
    static let askedPlayers = SettingsKey<[String]>("rolltop.media.asked-players", default: [])
}

/// Now Playing for Music and Spotify: follows both players' notifications, reads and
/// controls them through Apple Events once allowed; provides `services[.nowPlaying]` and
/// one consent row per installed player.
final class MediaFeature: FeatureModule {
    static let id: FeatureID = "media"

    private unowned let context: AppContext
    private let provider: MediaNowPlayingProvider
    private let transport = MediaAppleEventTransport()
    private let log = Log.logger("media")

    init(context: AppContext) {
        self.context = context
        context.settings.markTransient(MediaSettings.askedPlayers)
        provider = MediaNowPlayingProvider(transport: transport)
        context.services.register(provider as any NowPlayingProviding, for: .nowPlaying)
        registerConsentRows()
    }

    func start() {
        provider.start()
    }

    func stop() {
        provider.stop()
    }

    // MARK: Consent rows

    private func registerConsentRows() {
        let registry = context.services[.consents]
        let purpose = LocalizedStringResource("Shows the artwork and controls playback from the Shelf and widgets.", table: "Media")
        let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
        for player in NowPlayingPlayer.allCases where NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.bundleID) != nil {
            let title: LocalizedStringResource = switch player {
            case .music: LocalizedStringResource("Music", table: "Media", comment: "Apple's Music app, a consent row title")
            case .spotify: LocalizedStringResource("Spotify", table: "Media", comment: "The Spotify app, a consent row title")
            }
            registry.register(ConsentItem(
                id: "media.\(player == .music ? "music" : "spotify")", title: title, purpose: purpose,
                sortOrder: player == .music ? 300 : 310,
                status: { [unowned self] in self.consentStatus(for: player) },
                request: { [unowned self] in await self.askConsent(for: player) },
                settingsURL: settingsURL))
        }
    }

    /// Never prompts: the pid lookup and `AEDeterminePermissionToAutomateTarget(…, false)`.
    private func consentStatus(for player: NowPlayingPlayer) -> ConsentStatus {
        guard let pid = transport.runningPID(of: player) else {
            provider.notePermission(.notRunning, for: player)
            return .cannotAskNow(Self.openFirst(player))
        }
        let permission = MediaPermission(status: transport.permission(pid: pid, ask: false))
        provider.notePermission(permission, for: player)
        switch permission {
        case .allowed: return .allowed
        case .refused: return .notAllowed
        case .notAsked: return .notAsked
        case .notRunning: return .cannotAskNow(Self.openFirst(player))
        case .failed(let status):
            return .unavailable(String(localized: "macOS reported error \(Int(status)).", table: "Media"))
        }
    }

    private static func openFirst(_ player: NowPlayingPlayer) -> String {
        switch player {
        case .music: String(localized: "Open Music first.", table: "Media")
        case .spotify: String(localized: "Open Spotify first.", table: "Media")
        }
    }

    /// The only place that may raise the Apple Events prompt: the row's button. The player
    /// must already run (addressed by pid, never launched).
    private func askConsent(for player: NowPlayingPlayer) async {
        var asked = context.settings[MediaSettings.askedPlayers]
        if !asked.contains(player.bundleID) {
            asked.append(player.bundleID)
            context.settings[MediaSettings.askedPlayers] = asked
        }
        let transport = transport
        let status: Int32? = await Task.detached {
            guard let pid = transport.runningPID(of: player) else { return nil }
            return transport.permission(pid: pid, ask: true)
        }.value
        log.notice("\(player.rawValue) Apple Events consent asked: \(status.map(String.init) ?? "not running")")
        await provider.readPlayer(player)
    }

    // MARK: Debug

    var commands: [Command] {
        #if DEBUG
        let provider = provider
        return [
            // Feeds the service a sample track with a generated artwork image, so the Shelf
            // card and widgets can be seen with data; `clear=1` removes it. Dumps the
            // service's state (field presence only) to debug/media-state.json.
            Command(id: "media.debug-inject", title: LocalizedStringResource("Inject Now Playing Sample", table: "Media"),
                    symbol: "music.note",
                    arguments: ["title", "artist", "album", "player", "playing", "clear", "dump"].map {
                        CommandArgument(name: $0, title: LocalizedStringResource(stringLiteral: $0), isRequired: false)
                    },
                    allowedFromURL: true, effect: .display) { invocation in
                if invocation.string("clear") == "1" {
                    provider.inject(nil, artwork: nil)
                } else if invocation.string("dump") != "1" {
                    var state = NowPlayingState.sample
                    if let title = invocation.string("title") { state.title = title }
                    if let artist = invocation.string("artist") { state.artist = artist }
                    if let album = invocation.string("album") { state.album = album }
                    if let raw = invocation.string("player") {
                        state.player = raw == "spotify" ? .spotify : NowPlayingPlayer(rawValue: raw) ?? .music
                    }
                    if let playing = invocation.string("playing") { state.isPlaying = playing != "0" && playing != "false" }
                    provider.inject(state, artwork: Self.sampleArtwork(for: state.player))
                }
                try DebugFiles.writeJSON(provider.debugDump(), name: "media-state.json")
            },
        ]
        #else
        return []
        #endif
    }

    #if DEBUG
    /// A 300 × 300 gradient with a note symbol, so consumers can be checked with artwork.
    private static func sampleArtwork(for player: NowPlayingPlayer) -> NSImage {
        NSImage(size: NSSize(width: 300, height: 300), flipped: false) { rect in
            let colors: [NSColor] = player == .music ? [.systemPink, .systemPurple] : [.systemGreen, .systemTeal]
            NSGradient(colors: colors)?.draw(in: rect, angle: 45)
            if let symbol = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 120, weight: .regular).applying(.init(paletteColors: [.white]))) {
                let size = symbol.size
                symbol.draw(in: NSRect(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2,
                                       width: size.width, height: size.height))
            }
            return true
        }
    }
    #endif
}
