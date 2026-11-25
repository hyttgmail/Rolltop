import Foundation
import Testing
@testable import Rolltop

@Suite struct ShelfHintLogicTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func burstCoalescesIntoOneHintThatHidesAfterTheLast() {
        var schedule = ShelfHintSchedule()
        let a = ShelfHint.volume(ShelfVolumeReading(level: 0.4, isMuted: false))
        let b = ShelfHint.volume(ShelfVolumeReading(level: 0.5, isMuted: false))
        let first = schedule.post(a, now: t0)
        let second = schedule.post(b, now: t0 + 0.3)
        #expect(first == .present && second == .update)
        #expect(schedule.current == b)
        let early = schedule.expire(now: t0 + 1.6)      // 1.5 s after the first, not the last
        let due = schedule.expire(now: t0 + 1.8)
        #expect(!early && due)
        #expect(schedule.current == nil)
        let again = schedule.post(a, now: t0 + 2)
        #expect(again == .present)
    }

    @Test func switchesGateEverySourceButNotices() {
        let off = ShelfHintConfig(enabled: false)
        #expect(ShelfHintSource.allCases.filter(off.allows) == [.notice])
        let noBrightness = ShelfHintConfig(brightness: false)
        #expect(ShelfHintSource.allCases.filter(noBrightness.allows) == [.volume, .battery, .notice])
    }

    @Test func batteryTransitionsThatProduceAHint() {
        func r(_ onPower: Bool, _ percent: Int, charged: Bool = false) -> ShelfBatteryReading {
            ShelfBatteryReading(onPower: onPower, percent: percent, isCharged: charged)
        }
        #expect(ShelfBatteryEvent.classify(from: nil, to: r(true, 50)) == nil)
        #expect(ShelfBatteryEvent.classify(from: r(false, 50), to: r(true, 50)) == .pluggedIn(50))
        #expect(ShelfBatteryEvent.classify(from: r(true, 50), to: r(false, 50)) == .unplugged(50))
        #expect(ShelfBatteryEvent.classify(from: r(true, 99), to: r(true, 100, charged: true)) == .charged)
        #expect(ShelfBatteryEvent.classify(from: r(false, 21), to: r(false, 20)) == .low(20))
        #expect(ShelfBatteryEvent.classify(from: r(false, 11), to: r(false, 10)) == .low(10))
        #expect(ShelfBatteryEvent.classify(from: r(false, 20), to: r(false, 19)) == nil)
    }

    @Test func levelFormatting() {
        #expect(ShelfHintFormat.percent(0.4375, locale: Locale(identifier: "en_US")) == "44%")
        #expect(ShelfHintFormat.percent(1.7, locale: Locale(identifier: "en_US")) == "100%")
    }
}

@Suite struct ShelfPasteFlowTests {
    /// A flow whose every step is fake: nothing here can reach `EventSynthesizer.postPaste()`.
    @MainActor private func flow(fronts: [pid_t?], post: Bool = true, copy: Bool = true, log: Box) -> ShelfPasteFlow {
        var fronts = fronts
        return ShelfPasteFlow(copy: { log.steps.append("copy"); return copy },
                              close: { log.steps.append("close") },
                              frontmostPID: { fronts.count > 1 ? fronts.removeFirst() : fronts.first ?? nil },
                              post: { log.steps.append("post"); return post },
                              sleep: { _ in })
    }

    @MainActor final class Box { var steps: [String] = [] }

    @MainActor @Test func pastesOnceTheTargetIsFrontAgain() async {
        let log = Box()
        let outcome = await flow(fronts: [1, 1, 42], log: log).run(target: 42)
        #expect(outcome == .pasted)
        #expect(log.steps == ["copy", "close", "post"])
    }

    @MainActor @Test func givesUpAndLeavesTheClipCopied() async {
        let log = Box()
        #expect(await flow(fronts: [1], log: log).run(target: 42) == .timedOut)
        #expect(log.steps == ["copy", "close"])
        #expect(await flow(fronts: [42], post: false, log: Box()).run(target: 42) == .notTrusted)
        #expect(await flow(fronts: [42], log: Box()).run(target: nil) == .noTarget)
        #expect(ShelfPasteOutcome.notTrusted.notice != nil)
    }

    @Test func alternateDoesTheOtherThing() {
        #expect(ShelfChooseAction.resolve(setting: .copy, alternate: false) == .copy)
        #expect(ShelfChooseAction.resolve(setting: .copy, alternate: true) == .paste)
        #expect(ShelfChooseAction.resolve(setting: .paste, alternate: true) == .copy)
    }
}

@Suite struct ShelfCardTests {
    @Test func nowPlayingWithoutControlSaysSo() {
        #expect(ShelfNowPlayingCard.make(state: nil, canControl: true, isOn: true) == nil)
        #expect(ShelfNowPlayingCard.make(state: .sample, canControl: true, isOn: false) == nil)
        let card = ShelfNowPlayingCard.make(state: .sample, canControl: false, isOn: true)
        #expect(card?.controlsEnabled == false)
        #expect(card?.needsPermission == true)
        #expect(card?.title == NowPlayingState.sample.title)
    }

    @Test func weatherCardExistsOnlyWhileWeatherIsOn() {
        #expect(ShelfWeatherCard.make(isEnabled: false, report: .sample, isOn: true) == nil)
        #expect(ShelfWeatherCard.make(isEnabled: true, report: .sample, isOn: false) == nil)
        #expect(ShelfWeatherCard.make(isEnabled: true, report: nil, isOn: true) == .needsSetup)
        #expect(ShelfWeatherCard.make(isEnabled: true, report: .sample, isOn: true) == .report(.sample))
    }

    @Test func upNextSkipsAllDayAndEndedEvents() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func event(_ id: String, _ start: Double, _ end: Double, allDay: Bool = false) -> ShelfEvent {
            ShelfEvent(id: id, title: id, start: now + start, end: now + end, isAllDay: allDay, calendarTitle: "Work")
        }
        let events = [event("ended", -3600, -60), event("allday", -3600, 80_000, allDay: true),
                      event("later", 7200, 9000), event("now", -600, 600)]
        #expect(ShelfUpNextProvider.next(in: events, now: now)?.id == "now")
        #expect(ShelfUpNextProvider.next(in: [events[0], events[1]], now: now) == nil)
        #expect(ShelfUpNextProvider.consentStatus(.notDetermined) == .notAsked)
        #expect(ShelfUpNextProvider.consentStatus(.granted) == .allowed)
    }
}
