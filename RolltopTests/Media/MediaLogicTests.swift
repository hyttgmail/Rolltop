import Foundation
import Testing
@testable import Rolltop

@Suite struct MediaNotificationParsingTests {
    @Test func musicAndSpotifyNotificationsParseDefensively() {
        let music = MediaNotificationParser.parse(
            ["Player State": "Playing", "Name": "Song", "Artist": "Band", "Album": "", "PersistentID": NSNumber(value: 42)],
            player: .music)
        #expect(music == MediaTrackReport(player: .music, playback: .playing, title: "Song", artist: "Band",
                                          album: nil, trackID: "42"))
        // Paused without a track keeps the known track, stopped clears it.
        let known = NowPlayingState(player: .music, title: "Song", artist: "Band", isPlaying: true)
        let paused = MediaNotificationParser.parse(["Player State": "Paused"], player: .music)
        #expect(MediaNotificationParser.merge(paused, into: known)?.isPlaying == false)
        #expect(MediaNotificationParser.merge(paused, into: known)?.title == "Song")
        let stopped = MediaNotificationParser.parse(["Player State": "Stopped", "Name": "Song"], player: .music)
        #expect(MediaNotificationParser.merge(stopped, into: known) == nil)
        #expect(MediaNotificationParser.parse(nil, player: .music).playback == .stopped)
        // Spotify ads show nothing; podcasts parse like tracks.
        let ad = MediaNotificationParser.parse(["Player State": "Playing", "Name": "Ad", "Track ID": "spotify:ad:1"], player: .spotify)
        #expect(ad.playback == .stopped && ad.title == nil)
        let episode = MediaNotificationParser.parse(["Player State": "Playing", "Name": "Episode",
                                                     "Track ID": "spotify:episode:9"], player: .spotify)
        #expect(episode.title == "Episode" && episode.trackID == "spotify:episode:9")
    }

    @Test func playingPlayerWinsOtherwiseLatestChange() {
        let a = MediaPlayerSnapshot(state: NowPlayingState(player: .music, title: "A", isPlaying: true), changedAt: Date(timeIntervalSince1970: 1))
        let b = MediaPlayerSnapshot(state: NowPlayingState(player: .spotify, title: "B", isPlaying: false), changedAt: Date(timeIntervalSince1970: 2))
        #expect(MediaArbiter.winner([a, b])?.state.player == .music)
        var bPlaying = b
        bPlaying.state.isPlaying = true
        #expect(MediaArbiter.winner([a, bPlaying])?.state.player == .spotify)
    }
}

@Suite struct MediaAEGuardTests {
    private final class FakeTransport: MediaAETransporting, @unchecked Sendable {
        var pid: pid_t?
        var permissionStatus: Int32 = 0
        var calls: [String] = []

        func runningPID(of player: NowPlayingPlayer) -> pid_t? { calls.append("pid"); return pid }
        func permission(pid: pid_t, ask: Bool) -> Int32 { calls.append("permission ask=\(ask)"); return permissionStatus }
        func send(_ request: MediaAERequest, to pid: pid_t, timeout: TimeInterval) -> MediaAEReply {
            calls.append("send"); return MediaAEReply(status: 0)
        }
    }

    @Test func notRunningOrNotPermittedSendsNothing() {
        let fake = FakeTransport()
        let sender = MediaAEGuard(transport: fake)
        let request = MediaScripting.command(.playPause, for: .music)

        #expect(sender.send(request, to: .music) == .notRunning)
        #expect(fake.calls == ["pid"])

        fake.calls = []
        fake.pid = 123
        fake.permissionStatus = -1744
        #expect(sender.send(request, to: .music) == .notPermitted(.notAsked))
        #expect(fake.calls == ["pid", "permission ask=false"])

        fake.calls = []
        fake.permissionStatus = 0
        #expect(sender.send(request, to: .music) == .sent(MediaAEReply(status: 0)))
        #expect(fake.calls == ["pid", "permission ask=false", "send"])
        #expect(MediaPermission(status: -1743) == .refused && MediaPermission(status: -600) == .notRunning)
    }
}
