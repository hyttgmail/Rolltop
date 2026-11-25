import Foundation

// Pure decisions of the Media feature: parsing the players' distributed notifications,
// choosing which player's track to show, mapping the Apple Events permission result to a
// consent status, and the order of guards before any Apple event is sent.

/// A player's playback state, from a notification or an Apple event.
nonisolated enum MediaPlaybackState: Equatable, Sendable {
    case playing
    case paused
    /// Stopped, or nothing to show (an ad, an empty track).
    case stopped
}

/// What one player reported. `title` is nil when the notification carried no track
/// (state change only) or the item must not be shown (Spotify ads).
nonisolated struct MediaTrackReport: Equatable, Sendable {
    var player: NowPlayingPlayer
    var playback: MediaPlaybackState
    var title: String?
    var artist: String?
    var album: String?
    /// The player's id for the track (Music's PersistentID, Spotify's Track ID), used as
    /// the artwork cache key; nil when the notification has none.
    var trackID: String?
}

/// Parses `com.apple.Music.playerInfo` and `com.spotify.client.PlaybackStateChanged`.
/// Both carry "Player State" ("Playing", "Paused", "Stopped"), "Name", "Artist", "Album".
/// Missing or odd values never fail: unknown states count as paused, empty strings as nil.
nonisolated enum MediaNotificationParser {
    static let musicName = "com.apple.Music.playerInfo"
    static let spotifyName = "com.spotify.client.PlaybackStateChanged"

    static func player(forNotification name: String) -> NowPlayingPlayer? {
        switch name {
        case musicName: .music
        case spotifyName: .spotify
        default: nil
        }
    }

    static func parse(_ userInfo: [AnyHashable: Any]?, player: NowPlayingPlayer) -> MediaTrackReport {
        let info = userInfo ?? [:]
        func text(_ key: String) -> String? {
            guard let value = info[key] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let playback: MediaPlaybackState = switch text("Player State")?.lowercased() {
        case "playing": .playing
        case "stopped": .stopped
        case nil where info.isEmpty: .stopped
        default: .paused
        }
        var trackID: String?
        switch player {
        case .music:
            trackID = text("PersistentID") ?? (info["PersistentID"] as? NSNumber)?.stringValue
        case .spotify:
            trackID = text("Track ID")
        }
        // Spotify ads ("spotify:ad:…") are not tracks: show nothing while one plays.
        if player == .spotify, let id = trackID, id.hasPrefix("spotify:ad:") {
            return MediaTrackReport(player: player, playback: .stopped, title: nil, artist: nil, album: nil, trackID: nil)
        }
        let title = playback == .stopped ? nil : text("Name")
        return MediaTrackReport(player: player, playback: playback, title: title,
                                artist: title == nil ? nil : text("Artist"),
                                album: title == nil ? nil : text("Album"),
                                trackID: title == nil ? nil : trackID)
    }

    /// The new state of `report.player` given what was known: stopped clears it; a report
    /// without a title keeps the known track and takes only the playing state.
    static func merge(_ report: MediaTrackReport, into known: NowPlayingState?) -> NowPlayingState? {
        if report.playback == .stopped { return nil }
        let isPlaying = report.playback == .playing
        guard let title = report.title else {
            guard var known, known.player == report.player else { return nil }
            known.isPlaying = isPlaying
            return known
        }
        return NowPlayingState(player: report.player, title: title, artist: report.artist,
                               album: report.album, isPlaying: isPlaying)
    }
}

/// One player's last known track and when it last changed.
nonisolated struct MediaPlayerSnapshot: Equatable, Sendable {
    var state: NowPlayingState
    var changedAt: Date
}

nonisolated enum MediaArbiter {
    /// The player whose track is shown: the one playing when exactly one plays; otherwise
    /// (both or neither) the one that changed last.
    static func winner(_ snapshots: [MediaPlayerSnapshot]) -> MediaPlayerSnapshot? {
        let playing = snapshots.filter(\.state.isPlaying)
        if playing.count == 1 { return playing[0] }
        return snapshots.max { $0.changedAt < $1.changedAt }
    }
}

/// `AEDeterminePermissionToAutomateTarget` results.
nonisolated enum MediaPermission: Equatable, Sendable {
    case allowed            // noErr
    case refused            // -1743 errAEEventNotPermitted
    case notAsked           // -1744 errAEEventWouldRequireUserConsent
    case notRunning         // -600 procNotFound
    case failed(Int32)

    init(status: Int32) {
        self = switch status {
        case 0: .allowed
        case -1743: .refused
        case -1744: .notAsked
        case -600: .notRunning
        default: .failed(status)
        }
    }
}

/// An Apple event the feature sends: read a property path, or run a command.
nonisolated enum MediaAERequest: Equatable, Sendable {
    /// Properties and elements from the application down, e.g. current track › name.
    case get([MediaAEStep])
    case command(eventClass: String, eventID: String)
}

nonisolated enum MediaAEStep: Equatable, Sendable {
    case property(String)
    case element(String, index: Int32)
}

/// A reply reduced to the value kinds the feature reads.
nonisolated struct MediaAEReply: Equatable, Sendable {
    var status: Int32
    var string: String?
    var enumCode: String?
    var data: Data?

    static func failure(_ status: Int32) -> MediaAEReply { MediaAEReply(status: status) }
}

/// The side effects the guards sit in front of. The real one is `MediaAppleEventTransport`.
nonisolated protocol MediaAETransporting: Sendable {
    /// The pid of the running player, nil when it does not run.
    func runningPID(of player: NowPlayingPlayer) -> pid_t?
    /// `AEDeterminePermissionToAutomateTarget` for the pid; prompts only when `ask` is true.
    func permission(pid: pid_t, ask: Bool) -> Int32
    /// Sends to the pid in the "do not prompt for user consent" mode, bounded by `timeout`.
    func send(_ request: MediaAERequest, to pid: pid_t, timeout: TimeInterval) -> MediaAEReply
}

/// Why a guarded send did not happen.
nonisolated enum MediaAEOutcome: Equatable, Sendable {
    case sent(MediaAEReply)
    case notRunning
    case notPermitted(MediaPermission)
}

/// Every Apple event goes through here: the player must run (addressed by pid, so an event
/// can never launch it) and the non-prompting permission check must say allowed. Blocking:
/// call it off the main thread.
nonisolated struct MediaAEGuard: Sendable {
    let transport: any MediaAETransporting
    var timeout: TimeInterval = 3

    func send(_ request: MediaAERequest, to player: NowPlayingPlayer) -> MediaAEOutcome {
        guard let pid = transport.runningPID(of: player) else { return .notRunning }
        let permission = MediaPermission(status: transport.permission(pid: pid, ask: false))
        guard permission == .allowed else { return .notPermitted(permission) }
        return .sent(transport.send(request, to: pid, timeout: timeout))
    }

    /// Several requests to one player behind one set of guards.
    func send(_ requests: [MediaAERequest], to player: NowPlayingPlayer) -> (MediaAEOutcome, [MediaAEReply]) {
        guard let pid = transport.runningPID(of: player) else { return (.notRunning, []) }
        let permission = MediaPermission(status: transport.permission(pid: pid, ask: false))
        guard permission == .allowed else { return (.notPermitted(permission), []) }
        let replies = requests.map { transport.send($0, to: pid, timeout: timeout) }
        return (.sent(replies.last ?? .failure(0)), replies)
    }
}

/// Scripting codes. Music's are from its sdef on this Mac; Spotify's are its documented
/// dictionary (unverified here: Spotify is not installed).
nonisolated enum MediaScripting {
    static func stateRequests() -> [MediaAERequest] {
        [.get([.property("pPlS")]),
         .get([.property("pTrk"), .property("pnam")]),
         .get([.property("pTrk"), .property("pArt")]),
         .get([.property("pTrk"), .property("pAlb")])]
    }

    static func command(_ command: NowPlayingCommand, for player: NowPlayingPlayer) -> MediaAERequest {
        let eventClass = player == .music ? "hook" : "spfy"
        let eventID = switch command {
        case .playPause: "PlPs"
        case .next: "Next"
        case .previous: "Prev"
        }
        return .command(eventClass: eventClass, eventID: eventID)
    }

    /// Music: raw data of artwork 1 of current track. Spotify: artwork url of current track.
    static func artworkRequest(for player: NowPlayingPlayer) -> MediaAERequest {
        switch player {
        case .music: .get([.property("pTrk"), .element("cArt", index: 1), .property("pRaw")])
        case .spotify: .get([.property("pTrk"), .property("aUrl")])
        }
    }

    /// Reads the replies of `stateRequests()`.
    static func report(from replies: [MediaAEReply], player: NowPlayingPlayer) -> MediaTrackReport? {
        guard replies.count == 4, replies[0].status == 0 else { return nil }
        let playback: MediaPlaybackState = switch replies[0].enumCode {
        case "kPSP", "kPSF", "kPSR": .playing
        case "kPSp": .paused
        default: .stopped
        }
        func text(_ reply: MediaAEReply) -> String? {
            guard reply.status == 0, let s = reply.string, !s.isEmpty else { return nil }
            return s
        }
        let title = playback == .stopped ? nil : text(replies[1])
        return MediaTrackReport(player: player, playback: title == nil ? .stopped : playback, title: title,
                                artist: text(replies[2]), album: text(replies[3]), trackID: nil)
    }
}

/// Artwork is cached in memory per track; nothing is written to disk.
nonisolated enum MediaArtworkKey {
    static func key(for state: NowPlayingState, trackID: String?) -> String {
        if let trackID { return "\(state.player.rawValue)|\(trackID)" }
        return [state.player.rawValue, state.title, state.artist ?? "", state.album ?? ""].joined(separator: "|")
    }

    /// Spotify artwork comes only from https URLs; responses above this are dropped.
    static let maxBytes = 4 * 1024 * 1024

    static func isAllowedArtworkURL(_ string: String?) -> URL? {
        guard let string, let url = URL(string: string), url.scheme == "https", url.host != nil else { return nil }
        return url
    }
}
