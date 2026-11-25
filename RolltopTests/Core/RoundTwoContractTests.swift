import AppKit
import CoreGraphics
import CoreLocation
import Foundation
import Testing
@testable import Rolltop

/// Round 2 shared contracts: consent rows, ambient services, location, paste, the palette's
/// alternate action. Docs: CONTRACTS.md.
@MainActor
@Suite struct ConsentRegistryTests {
    private func item(_ id: String, order: Int, status: @escaping @MainActor () -> ConsentStatus = { .notAsked },
                      request: @escaping @MainActor () async -> Void = {}) -> ConsentItem {
        ConsentItem(id: id, title: "Title", purpose: "Purpose", sortOrder: order, status: status, request: request)
    }

    @Test func itemsAreSortedByOrderThenIDAndReplacedByID() {
        let registry = ConsentRegistry()
        registry.register(item("media.spotify", order: 310))
        registry.register(item("media.music", order: 300))
        registry.register(item("b.second", order: 300))
        registry.register(item("location.access", order: 100))
        #expect(registry.items.map(\.id) == ["location.access", "b.second", "media.music", "media.spotify"])

        registry.register(item("media.music", order: 50))
        #expect(registry.items.map(\.id) == ["media.music", "location.access", "b.second", "media.spotify"])
        #expect(registry.items.count == 4)

        registry.unregister(id: "b.second")
        #expect(registry.items.map(\.id) == ["media.music", "location.access", "media.spotify"])
    }

    @Test func registeringIsInertAndRefreshReadsStatuses() {
        let registry = ConsentRegistry()
        var reads = 0
        var current = ConsentStatus.notAsked
        registry.register(item("a.one", order: 1, status: { reads += 1; return current }))
        #expect(reads == 0, "register never reads a status")
        #expect(registry.status(for: "a.one") == nil)

        let before = registry.revision
        registry.refresh()
        #expect(reads == 1)
        #expect(registry.status(for: "a.one") == .notAsked)
        #expect(registry.revision == before + 1)

        registry.refresh()
        #expect(registry.revision == before + 1, "no change, no bump")

        current = .cannotAskNow("Open Music first")
        registry.refresh()
        #expect(registry.status(for: "a.one") == .cannotAskNow("Open Music first"))
        #expect(registry.revision == before + 2)
    }

    @Test func requestRunsOnceThenRefreshes() async {
        let registry = ConsentRegistry()
        var granted = false
        var requests = 0
        registry.register(item("a.one", order: 1, status: { granted ? .allowed : .notAsked },
                               request: { requests += 1; granted = true }))
        registry.refresh()
        await registry.request(id: "a.one")
        #expect(requests == 1)
        #expect(registry.status(for: "a.one") == .allowed)
        #expect(registry.requesting.isEmpty)
        await registry.request(id: "missing")
        #expect(requests == 1)
    }

    @Test func statusDecidesTheButton() {
        #expect(ConsentAction.primary(for: .notAsked, hasSettingsURL: true) == .ask)
        #expect(ConsentAction.primary(for: .notAsked, hasSettingsURL: false) == .ask)
        #expect(ConsentAction.primary(for: .notAllowed, hasSettingsURL: true) == .openSystemSettings)
        #expect(ConsentAction.primary(for: .notAllowed, hasSettingsURL: false) == .ask)
        #expect(ConsentAction.primary(for: .allowed, hasSettingsURL: true) == nil)
        #expect(ConsentAction.primary(for: .cannotAskNow("x"), hasSettingsURL: true) == nil)
        #expect(ConsentAction.primary(for: .unavailable("x"), hasSettingsURL: true) == nil)

        #expect(ConsentAction.showsSecondary(for: .notAsked))
        #expect(ConsentAction.showsSecondary(for: .notAllowed))
        #expect(ConsentAction.showsSecondary(for: .allowed))
        #expect(ConsentAction.showsSecondary(for: .cannotAskNow("x")))
        #expect(!ConsentAction.showsSecondary(for: .unavailable("x")))

        #expect(ConsentAction.buttonsEnabled(launchedByLaunchServices: true))
        #expect(!ConsentAction.buttonsEnabled(launchedByLaunchServices: false))
    }

    @Test func registryIsAServiceThatKeepsItsRows() throws {
        let context = try TestContext.make()
        context.services[.consents].register(item("a.one", order: 1))
        #expect(context.services[.consents].items.map(\.id) == ["a.one"])
    }
}

@MainActor
@Suite struct AmbientServiceTests {
    @Test func defaultsKnowNothing() async throws {
        let context = try TestContext.make()
        let playing = context.services[.nowPlaying]
        #expect(playing.state == nil)
        #expect(playing.artwork == nil)
        #expect(!playing.canControl)
        #expect(await playing.perform(.playPause) == false)

        let weather = context.services[.weather]
        #expect(!weather.isEnabled)
        #expect(weather.report == nil)
        #expect(weather.lastError == nil)
        #expect(weather.attribution.url == URL(string: "https://open-meteo.com/"))
        #expect(!weather.attribution.text.isEmpty)

        #expect(!context.services[.upNext].isAuthorized)
        #expect(context.services[.upNext].nextEvent == nil)

        let focus = context.services[.focusState]
        #expect(focus.isFocused == nil)
        #expect(focus.label == nil)
        #expect(!focus.sourceNote.isEmpty)
    }

    @Test func playersAreMusicAndSpotify() {
        #expect(NowPlayingPlayer.music.bundleID == "com.apple.Music")
        #expect(NowPlayingPlayer.spotify.bundleID == "com.spotify.client")
        #expect(NowPlayingPlayer.allCases.allSatisfy { !$0.displayName.isEmpty })
    }

    @Test func everyDocumentedWMOCodeMaps() {
        let expected: [Int: WeatherCondition] = [
            0: .clear, 1: .mainlyClear, 2: .partlyCloudy, 3: .overcast, 45: .fog, 48: .fog,
            51: .drizzle, 53: .drizzle, 55: .drizzle, 56: .freezingDrizzle, 57: .freezingDrizzle,
            61: .rain, 63: .rain, 65: .rain, 66: .freezingRain, 67: .freezingRain,
            71: .snow, 73: .snow, 75: .snow, 77: .snow, 80: .rainShowers, 81: .rainShowers, 82: .rainShowers,
            85: .snowShowers, 86: .snowShowers, 95: .thunderstorm, 96: .thunderstormWithHail, 99: .thunderstormWithHail,
        ]
        for (code, condition) in expected {
            #expect(WeatherCondition(wmoCode: code) == condition, "code \(code)")
        }
        // Gaps inside documented ranges and codes outside them.
        for code in [-1, 4, 44, 46, 50, 52, 54, 58, 60, 62, 68, 70, 72, 76, 78, 83, 84, 87, 94, 97, 98, 100] {
            #expect(WeatherCondition(wmoCode: code) == .unknown, "code \(code)")
        }
        #expect(Set(expected.values).count == WeatherCondition.allCases.count - 1, "every case but unknown is reachable")
    }

    @Test func everyConditionHasExistingSymbolsAndAName() {
        for condition in WeatherCondition.allCases {
            for daylight in [true, false] {
                let name = condition.symbolName(isDaylight: daylight)
                #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(condition): \(name)")
            }
            #expect(!condition.localizedName.isEmpty)
        }
        #expect(WeatherReport.sample.symbolName == "cloud.sun.fill")
    }

    @Test func upNextColorNeedsThreeComponents() {
        #expect(UpNextEvent.sample.color != nil)
        var event = UpNextEvent.sample
        event.calendarColor = [0.1]
        #expect(event.color == nil)
    }
}

@MainActor
@Suite struct LocationAccessTests {
    @Test func authorizationMapping() {
        #expect(LocationAuthorization(.authorizedAlways) == .authorized)
        #expect(LocationAuthorization(.denied) == .denied)
        #expect(LocationAuthorization(.restricted) == .restricted)
        #expect(LocationAuthorization(.notDetermined) == .notDetermined)
    }

    /// Resolving the service creates no location manager (nothing reaches CoreLocation).
    @Test func resolvingTheServiceStaysInactive() throws {
        let context = try TestContext.make()
        let location = context.services[.location]
        #expect(!location.isActive)
        #expect(location.authorization == .notDetermined)
        #expect(!location.isAuthorized)
    }

    @Test func errorsHaveMessages() {
        for error in [LocationAccessError.notAuthorized, .servicesOff, .timedOut, .failed("x")] {
            #expect(!(error.errorDescription ?? "").isEmpty)
        }
    }
}

/// Only the description of ⌘V and the events built from it; nothing is posted.
@Suite struct PasteSynthesisTests {
    @Test func pasteIsVDownThenUpWithCommandOnly() {
        #expect(EventSynthesizer.pasteKeyCode == 9)
        #expect(EventSynthesizer.pasteKeyStrokes == [
            .init(keyCode: 9, flags: .maskCommand, isKeyDown: true),
            .init(keyCode: 9, flags: .maskCommand, isKeyDown: false),
        ])
    }

    @Test func builtEventsCarryKeyFlagsAndTag() throws {
        let events = try #require(EventSynthesizer.keyEvents(for: EventSynthesizer.pasteKeyStrokes, source: nil))
        #expect(events.count == 2)
        #expect(events.map(\.type) == [.keyDown, .keyUp])
        for event in events {
            #expect(event.getIntegerValueField(.keyboardEventKeycode) == 9)
            #expect(event.flags == .maskCommand)
            #expect(EventSynthesizer.isSynthesized(event))
        }
    }
}

@MainActor
@Suite struct PaletteAlternateActionTests {
    @Test func alternateActionDefaultsToNil() {
        let plain = PaletteProvidedResult(id: "a", title: "A") {}
        #expect(plain.alternateAction == nil)
        let paste = PaletteProvidedResult(id: "b", title: "B", alternateAction: PaletteAlternateAction(title: "Paste") {}) {}
        #expect(paste.alternateAction?.title == "Paste")
    }
}
