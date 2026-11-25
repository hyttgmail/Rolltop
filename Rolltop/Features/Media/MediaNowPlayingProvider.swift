import AppKit
import Foundation
import Observation

/// `.nowPlaying`: follows Music and Spotify through their distributed notifications (no
/// permission needed) and, once a player's Apple Events consent is there, reads its current
/// track at launch, its artwork, and sends the three controls. Never launches a player and
/// never prompts: every Apple event goes through `MediaAEGuard` off the main thread.
@Observable
final class MediaNowPlayingProvider: NowPlayingProviding {
    /// Last known track per player (notifications and reads).
    private(set) var snapshots: [NowPlayingPlayer: MediaPlayerSnapshot] = [:]
    /// Players that run now.
    private(set) var running: Set<NowPlayingPlayer> = []
    /// Last non-prompting permission read per player.
    private(set) var permissions: [NowPlayingPlayer: MediaPermission] = [:]
    private var currentArtwork: (key: String, image: NSImage)?
    #if DEBUG
    private(set) var injected: (state: NowPlayingState, artwork: NSImage?)?
    #endif

    @ObservationIgnored private var trackIDs: [NowPlayingPlayer: String] = [:]
    @ObservationIgnored private var artworkCache: [String: NSImage] = [:]
    @ObservationIgnored private var artworkOrder: [String] = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var relay: MediaNotificationRelay?
    @ObservationIgnored private let aeGuard: MediaAEGuard
    @ObservationIgnored private let log = Log.logger("media")

    nonisolated private static let queue = DispatchQueue(label: "com.alphapengwang.rolltop.media", qos: .utility)

    init(transport: any MediaAETransporting = MediaAppleEventTransport()) {
        aeGuard = MediaAEGuard(transport: transport)
    }

    // MARK: NowPlayingProviding

    var state: NowPlayingState? {
        #if DEBUG
        if let injected { return injected.state }
        #endif
        return MediaArbiter.winner(Array(snapshots.values))?.state
    }

    var artwork: NSImage? {
        #if DEBUG
        if let injected { return injected.artwork }
        #endif
        guard let state, let currentArtwork,
              currentArtwork.key == MediaArtworkKey.key(for: state, trackID: trackIDs[state.player]) else { return nil }
        return currentArtwork.image
    }

    var canControl: Bool {
        #if DEBUG
        if injected != nil { return true }
        #endif
        guard let player = state?.player else { return false }
        return running.contains(player) && permissions[player] == .allowed
    }

    func perform(_ command: NowPlayingCommand) async -> Bool {
        #if DEBUG
        if var sample = injected {
            if command == .playPause { sample.state.isPlaying.toggle() }
            injected = sample
            return true
        }
        #endif
        guard let player = state?.player, running.contains(player) else { return false }
        let request = MediaScripting.command(command, for: player)
        let guardRef = aeGuard
        let outcome = await Self.offMain { guardRef.send(request, to: player) }
        switch outcome {
        case .sent(let reply):
            log.info("\(player.rawValue) \(command.rawValue): status \(reply.status)")
            return reply.status == 0
        case .notRunning:
            running.remove(player)
            return false
        case .notPermitted(let permission):
            permissions[player] = permission
            return false
        }
    }

    // MARK: Lifecycle

    func start() {
        // AppKit suspends distributed notifications while the app is inactive (Rolltop nearly
        // always is), so the observer asks for immediate delivery.
        let relay = MediaNotificationRelay { [weak self] report in self?.apply(report, trackID: report.trackID) }
        self.relay = relay
        for name in [MediaNotificationParser.musicName, MediaNotificationParser.spotifyName] {
            DistributedNotificationCenter.default().addObserver(relay, selector: #selector(MediaNotificationRelay.received(_:)),
                                                                name: Notification.Name(name), object: nil,
                                                                suspensionBehavior: .deliverImmediately)
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard let player = app?.bundleIdentifier.flatMap(NowPlayingPlayer.init(rawValue:)) else { return }
                let launched = note.name == NSWorkspace.didLaunchApplicationNotification
                MainActor.assumeIsolated { self?.playerChanged(player, launched: launched) }
            })
        }
        for player in NowPlayingPlayer.allCases
        where !NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleID).isEmpty {
            playerChanged(player, launched: true)
        }
    }

    func stop() {
        if let relay { DistributedNotificationCenter.default().removeObserver(relay) }
        relay = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
    }

    // MARK: Updates

    private func apply(_ report: MediaTrackReport, trackID: String?) {
        let known = snapshots[report.player]?.state
        let merged = MediaNotificationParser.merge(report, into: known)
        if let trackID { trackIDs[report.player] = trackID } else if report.title != nil { trackIDs[report.player] = nil }
        guard let merged else {
            snapshots[report.player] = nil
            return
        }
        snapshots[report.player] = MediaPlayerSnapshot(state: merged, changedAt: Date())
        if !running.contains(report.player) || permissions[report.player] == nil {
            // First news from this player: learn the permission (never prompts).
            running.insert(report.player)
            Task { await readPlayer(report.player) }
        }
        let trackChanged = known.map { ($0.title, $0.artist, $0.album) != (merged.title, merged.artist, merged.album) } ?? true
        if trackChanged || artwork == nil { loadArtwork(for: merged) }
    }

    private func playerChanged(_ player: NowPlayingPlayer, launched: Bool) {
        guard launched else {
            running.remove(player)
            snapshots[player] = nil
            trackIDs[player] = nil
            permissions[player] = .notRunning
            return
        }
        running.insert(player)
        Task { await readPlayer(player) }
    }

    /// Reads the permission without prompting and, when allowed, the current track (a
    /// notification only arrives on a change).
    func readPlayer(_ player: NowPlayingPlayer) async {
        let guardRef = aeGuard
        let (outcome, replies) = await Self.offMain { guardRef.send(MediaScripting.stateRequests(), to: player) }
        switch outcome {
        case .notRunning:
            running.remove(player)
            permissions[player] = .notRunning
        case .notPermitted(let permission):
            permissions[player] = permission
        case .sent:
            permissions[player] = .allowed
            if let report = MediaScripting.report(from: replies, player: player), snapshots[player] == nil || report.title != nil {
                apply(report, trackID: trackIDs[player])
            }
        }
    }

    /// Called by the consent row's status read (never prompts) so `canControl` follows it.
    func notePermission(_ permission: MediaPermission, for player: NowPlayingPlayer) {
        if permissions[player] != permission { permissions[player] = permission }
    }

    // MARK: Artwork

    private func loadArtwork(for state: NowPlayingState) {
        let key = MediaArtworkKey.key(for: state, trackID: trackIDs[state.player])
        if let cached = artworkCache[key] {
            currentArtwork = (key, cached)
            return
        }
        guard running.contains(state.player), permissions[state.player] == .allowed else { return }
        let player = state.player
        let guardRef = aeGuard
        Task {
            let outcome = await Self.offMain { guardRef.send(MediaScripting.artworkRequest(for: player), to: player) }
            guard case .sent(let reply) = outcome, reply.status == 0 else { return }
            var data: Data?
            switch player {
            case .music:
                data = reply.data
            case .spotify:
                // Only while Spotify's row is allowed: the URL came through a guarded event.
                guard let url = MediaArtworkKey.isAllowedArtworkURL(reply.string) else { return }
                data = await Self.download(url)
            }
            guard let data, data.count <= MediaArtworkKey.maxBytes, let image = NSImage(data: data) else { return }
            storeArtwork(image, key: key)
        }
    }

    private func storeArtwork(_ image: NSImage, key: String) {
        artworkCache[key] = image
        artworkOrder.removeAll { $0 == key }
        artworkOrder.append(key)
        while artworkOrder.count > 8 { artworkCache[artworkOrder.removeFirst()] = nil }
        if let state, MediaArtworkKey.key(for: state, trackID: trackIDs[state.player]) == key {
            currentArtwork = (key, image)
        }
    }

    nonisolated private static func download(_ url: URL) async -> Data? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count <= MediaArtworkKey.maxBytes else { return nil }
        return data
    }

    nonisolated static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    // MARK: Debug

    #if DEBUG
    func inject(_ state: NowPlayingState?, artwork: NSImage?) {
        injected = state.map { ($0, artwork) }
    }

    struct DebugDump: Encodable {
        let injected: Bool
        let player: String?
        let titleLength: Int
        let hasArtist: Bool
        let hasAlbum: Bool
        let isPlaying: Bool?
        let hasArtwork: Bool
        let artworkSize: [Double]?
        let canControl: Bool
        let running: [String]
        let permissions: [String: String]
    }

    /// Field presence only, never titles or artists.
    func debugDump() -> DebugDump {
        DebugDump(injected: injected != nil, player: state?.player.rawValue, titleLength: state?.title.count ?? 0,
                  hasArtist: state?.artist != nil, hasAlbum: state?.album != nil, isPlaying: state?.isPlaying,
                  hasArtwork: artwork != nil, artworkSize: artwork.map { [$0.size.width, $0.size.height] },
                  canControl: canControl, running: running.map(\.rawValue).sorted(),
                  permissions: Dictionary(uniqueKeysWithValues: permissions.map { ($0.key.rawValue, "\($0.value)") }))
    }
    #endif
}

/// Receives the players' distributed notifications (selector API: the only one that takes
/// a suspension behaviour), parses them where they arrive and hands the report to the main
/// actor.
final class MediaNotificationRelay: NSObject {
    private let handler: @MainActor @Sendable (MediaTrackReport) -> Void

    init(handler: @escaping @MainActor @Sendable (MediaTrackReport) -> Void) {
        self.handler = handler
    }

    @objc nonisolated func received(_ note: Notification) {
        guard let player = MediaNotificationParser.player(forNotification: note.name.rawValue) else { return }
        let report = MediaNotificationParser.parse(note.userInfo, player: player)
        let handler = handler
        Task { @MainActor in handler(report) }
    }
}
