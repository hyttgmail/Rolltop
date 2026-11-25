import AppKit
import Foundation
import Testing
@testable import Rolltop

@Suite struct ShelfFileListTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func drop(_ path: String) -> ShelfFileDrop { ShelfFileDrop(path: path, bookmark: nil, isDirectory: false) }

    @Test func addsNewestFirstAndRefreshesRepeats() {
        var list = ShelfFileList()
        list.add([drop("/a"), drop("/b")], now: t0)
        #expect(list.items.map(\.path) == ["/a", "/b"])
        let id = list.items[1].id
        list.add([drop("/b")], now: t0 + 60)
        #expect(list.items.map(\.path) == ["/b", "/a"])
        #expect(list.items[0].id == id)
        #expect(list.items[0].addedAt == t0 + 60)
    }

    @Test func capDropsTheOldest() {
        var list = ShelfFileList()
        for index in 0..<5 { list.add([drop("/f\(index)")], now: t0 + Double(index)) }
        list.add([drop("/new")], now: t0 + 10, cap: 3)
        #expect(list.items.map(\.path) == ["/new", "/f4", "/f3"])
    }

    @Test func expiryAndNextExpiry() {
        var list = ShelfFileList()
        list.add([drop("/old")], now: t0)
        list.add([drop("/new")], now: t0 + 3000)
        #expect(list.nextExpiry(lifetime: 3600) == t0 + 3600)
        #expect(list.nextExpiry(lifetime: nil) == nil)
        #expect(list.expire(now: t0 + 3600, lifetime: nil).isEmpty)
        #expect(list.expire(now: t0 + 3600, lifetime: 3600).map(\.path) == ["/old"])
        #expect(list.items.map(\.path) == ["/new"])
    }

    @Test func dropsKeepFileURLsOnly() {
        let urls = [URL(string: "https://example.com/a.txt")!, URL(filePath: "/tmp/a.txt"), URL(filePath: "/tmp/./a.txt"),
                    URL(filePath: "/tmp/b"), URL(filePath: "/")]
        #expect(ShelfDropPlanner.fileURLs(from: urls).map { $0.path(percentEncoded: false) } == ["/tmp/a.txt", "/tmp/b"])
        #expect(ShelfDropPlanner.carriesFiles(types: ["public.file-url", "public.utf8-plain-text"]))
        #expect(!ShelfDropPlanner.carriesFiles(types: ["public.utf8-plain-text"]))
    }

    @Test func lifetimeChoices() {
        #expect(ShelfFileLifetime.seconds(hours: 24) == 86_400)
        #expect(ShelfFileLifetime.seconds(hours: 0) == nil)
    }
}

@Suite struct ShelfMeetingLinkTests {
    @Test func recognisesTheServices() {
        let cases: [(String, ShelfMeetingLink.Service)] = [
            ("https://us02web.zoom.us/j/81234567890?pwd=abc", .zoom),
            ("https://zoom.us/my/someroom", .zoom),
            ("zoommtg://zoom.us/join?confno=123", .zoom),
            ("https://meet.google.com/abc-defg-hij", .meet),
            ("https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc/0?context=x", .teams),
            ("https://teams.live.com/meet/9876", .teams),
            ("https://acme.webex.com/acme/j.php?MTID=m123", .webex),
            ("https://acme.webex.com/meet/someone", .webex),
            ("https://facetime.apple.com/join#v=1&p=abc", .faceTime),
        ]
        for (raw, service) in cases {
            #expect(ShelfMeetingLinks.detect(in: [raw])?.service == service, "\(raw)")
        }
    }

    @Test func ignoresOtherLinks() {
        for raw in ["https://zoom.us/pricing", "https://meet.google.com/", "https://example.com/j/123", "https://www.webex.com/",
                    "https://teams.microsoft.com/", "https://facetime.apple.com/"] {
            #expect(ShelfMeetingLinks.detect(in: [raw]) == nil, "\(raw)")
        }
        #expect(ShelfMeetingLinks.detect(in: [nil, "", "Room 4"]) == nil)
    }

    @Test func findsTheLinkInsideNotesAndTrimsPunctuation() {
        let notes = "Agenda below.\nJoin Zoom Meeting: https://zoom.us/j/123456789.\nPasscode: 1"
        let link = ShelfMeetingLinks.detect(in: [nil, "Room 4", notes])
        #expect(link?.service == .zoom)
        #expect(link?.url.absoluteString == "https://zoom.us/j/123456789")
    }

    @Test func earlierFieldsWin() {
        let link = ShelfMeetingLinks.detect(in: ["https://meet.google.com/abc-defg-hij", nil, "https://zoom.us/j/1"])
        #expect(link?.service == .meet)
    }
}

/// The two screens of this machine (PLATFORM §11), global AppKit coordinates.
private let plainScreen = ShelfScreen(frame: CGRect(x: 0, y: 0, width: 2304, height: 1296),
                                      visibleFrame: CGRect(x: 0, y: 75, width: 2304, height: 1191))
private let notchedScreen = ShelfScreen(frame: CGRect(x: 2304, y: 216, width: 1728, height: 1117),
                                        visibleFrame: CGRect(x: 2304, y: 216, width: 1728, height: 1085),
                                        safeAreaTop: 32, notch: 3075.5...3260.5)

@Suite struct ShelfGeometryTests {
    @Test func plainDisplayHangsFromTheMenuBarAtTheCentre() {
        let frame = ShelfGeometry.panelFrame(size: CGSize(width: 560, height: 400), screen: plainScreen)
        #expect(frame.midX == 1152)
        #expect(frame.maxY == 1266)   // 1296 − 30 pt menu bar
        #expect(frame.size == CGSize(width: 560, height: 400))
    }

    @Test func notchedDisplayHangsUnderTheNotch() {
        let frame = ShelfGeometry.panelFrame(size: CGSize(width: 560, height: 400), screen: notchedScreen)
        #expect(frame.midX == 3168)   // notch centre: (3075.5 + 3260.5) / 2
        #expect(frame.maxY == 1301)   // 1333 − 32 pt (notch / menu bar)
    }

    @Test func autoHiddenMenuBarStillClearsTheNotch() {
        var notched = notchedScreen
        notched.visibleFrame = notched.frame
        #expect(ShelfGeometry.panelFrame(size: CGSize(width: 400, height: 300), screen: notched).maxY == 1301)
        var plain = plainScreen
        plain.visibleFrame = plain.frame
        #expect(ShelfGeometry.panelFrame(size: CGSize(width: 400, height: 300), screen: plain).maxY == 1296)
    }

    @Test func staysInsideSmallScreens() {
        let small = ShelfScreen(frame: CGRect(x: 0, y: 0, width: 500, height: 300), visibleFrame: CGRect(x: 0, y: 0, width: 500, height: 276))
        let frame = ShelfGeometry.panelFrame(size: CGSize(width: 680, height: 500), screen: small)
        #expect(frame.minX >= 8)
        #expect(frame.maxX <= 492)
        #expect(frame.minY >= 8)
    }

    @Test func hoverZoneIsTheNotchOrTheTopCentre() {
        let notch = ShelfGeometry.hoverZone(notchedScreen)
        #expect(notch == CGRect(x: 3069.5, y: 1301, width: 197, height: 32))
        #expect(notch.contains(CGPoint(x: 3168, y: 1332)))
        #expect(!notch.contains(CGPoint(x: 3000, y: 1332)))   // menu bar beside the notch
        let plain = ShelfGeometry.hoverZone(plainScreen)
        #expect(plain == CGRect(x: 1062, y: 1266, width: 180, height: 30))
    }

    @Test func dragZoneIsWiderAndReachesBelowTheBar() {
        let zone = ShelfGeometry.dragZone(notchedScreen)
        #expect(zone.width == 320)
        #expect(zone.midX == 3168)
        #expect(zone.minY == CGFloat(1261))
        #expect(zone.maxY == CGFloat(1333))
        #expect(zone.contains(CGPoint(x: 3168, y: 1290)))
    }

    @Test func keepOpenRegionBridgesZoneAndPanel() {
        let panel = ShelfGeometry.panelFrame(size: CGSize(width: 560, height: 400), screen: plainScreen)
        let region = ShelfGeometry.keepOpenRegion(screen: plainScreen, panel: panel)
        let inside = [CGPoint(x: 1152, y: 1280), CGPoint(x: 1152, y: 1267), CGPoint(x: 1152, y: 1000), CGPoint(x: panel.minX - 5, y: 1000)]
        for point in inside { #expect(region.contains { $0.contains(point) }, "\(point)") }
        #expect(!region.contains { $0.contains(CGPoint(x: 200, y: 600)) })
    }

    @Test func picksTheScreenUnderThePointer() {
        let screens = [plainScreen, notchedScreen]
        #expect(ShelfGeometry.screen(containing: CGPoint(x: 3000, y: 900), in: screens) == notchedScreen)
        #expect(ShelfGeometry.screen(containing: CGPoint(x: 10, y: 1296), in: screens) == plainScreen)
    }
}

@Suite struct ShelfPanelMachineTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func commandOpensStickyAndToggleCloses() {
        var machine = ShelfPanelMachine()
        #expect(machine.handle(.toggle) == .open(.command))
        #expect(machine.handle(.pointer(inRegion: false, now: t0)) == .none)
        #expect(machine.handle(.pointer(inRegion: false, now: t0 + 5)) == .none)   // sticky: pointer may leave
        #expect(machine.handle(.toggle) == .close(.toggled))
        #expect(!machine.isOpen)
    }

    @Test func hoverOpenClosesWhenThePointerLeaves() {
        var machine = ShelfPanelMachine()
        #expect(machine.handle(.hoverDwelled) == .open(.hover))
        #expect(machine.handle(.pointer(inRegion: false, now: t0)) == .none)
        #expect(machine.handle(.pointer(inRegion: true, now: t0 + 0.2)) == .none)   // came back: timer resets
        #expect(machine.handle(.pointer(inRegion: false, now: t0 + 0.3)) == .none)
        #expect(machine.handle(.pointer(inRegion: false, now: t0 + 0.5)) == .none)
        #expect(machine.handle(.pointer(inRegion: false, now: t0 + 0.8)) == .close(.pointerLeft))
    }

    @Test func interactingMakesAHoverOpenSticky() {
        var machine = ShelfPanelMachine()
        _ = machine.handle(.dragEnteredZone)
        #expect(machine.state == .open(trigger: .drag, sticky: false))
        _ = machine.handle(.interacted)
        #expect(machine.handle(.pointer(inRegion: false, now: t0)) == .none)
        #expect(machine.handle(.pointer(inRegion: false, now: t0 + 10)) == .none)
    }

    @Test func everyCloseReason() {
        let cases: [(ShelfPanelMachine.Event, ShelfCloseReason)] = [
            (.clickOutside, .clickOutside), (.escape, .escape), (.dropCompleted, .dropCompleted),
            (.otherPanelOpened, .otherPanel), (.used, .used), (.sectionsOff, .sectionsOff),
        ]
        for (event, reason) in cases {
            var machine = ShelfPanelMachine()
            _ = machine.handle(.toggle)
            #expect(machine.handle(event) == .close(reason))
            #expect(machine.handle(event) == .none)   // closed: nothing more happens
        }
    }

    @Test func showWhileOpenRefreshesAndHoverWhileOpenIsIgnored() {
        var machine = ShelfPanelMachine()
        _ = machine.handle(.hoverDwelled)
        #expect(machine.handle(.hoverDwelled) == .none)
        #expect(machine.handle(.show) == .refresh)
        #expect(machine.state == .open(trigger: .hover, sticky: true))
        #expect(machine.handle(.dragEnteredZone) == .none)
    }

    @Test func closedIgnoresEverythingButOpeners() {
        var machine = ShelfPanelMachine()
        for event: ShelfPanelMachine.Event in [.clickOutside, .escape, .dropCompleted, .interacted, .pointer(inRegion: false, now: t0)] {
            #expect(machine.handle(event) == .none)
        }
        #expect(machine.handle(.show) == .open(.command))
    }
}

@Suite struct ShelfActivityPlanTests {
    @Test func everySectionOffRunsNothing() {
        var input = ShelfActivityInput()
        input.openOnHover = true
        input.openOnDrag = true
        input.fileLifetime = 3600
        input.hasFiles = true
        #expect(ShelfActivityPlan.activities(input).isEmpty)
    }

    @Test func eachSectionStartsOnlyWhatItNeeds() {
        #expect(ShelfActivityPlan.activities(ShelfActivityInput(clipboardEnabled: true)) == [.clipboardMonitor])
        #expect(ShelfActivityPlan.activities(ShelfActivityInput(clipboardEnabled: true, clipboardPaused: true)) == [.clipboardResumeTimer])
        #expect(ShelfActivityPlan.activities(ShelfActivityInput(filesEnabled: true, openOnDrag: true)) == [.dragMonitor])
        #expect(ShelfActivityPlan.activities(ShelfActivityInput(filesEnabled: true, openOnDrag: false, fileLifetime: 60, hasFiles: true))
            == [.fileExpiryTimer])
        #expect(ShelfActivityPlan.activities(ShelfActivityInput(filesEnabled: true, openOnDrag: false, fileLifetime: nil, hasFiles: true)).isEmpty)
        #expect(ShelfActivityPlan.activities(ShelfActivityInput(upNextEnabled: true, openOnHover: true, openOnDrag: true)) == [.hoverMonitor])
        #expect(ShelfActivityPlan.activities(ShelfActivityInput(upNextEnabled: true)).isEmpty)
    }
}

@Suite struct ShelfUpNextTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    private func event(_ id: String, _ start: Date, minutes: Double, allDay: Bool = false) -> ShelfEvent {
        ShelfEvent(id: id, title: id, start: start, end: start.addingTimeInterval(minutes * 60), isAllDay: allDay, calendarTitle: "")
    }

    @Test func nextTimedEventsAndAllDayLines() {
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let now = today.addingTimeInterval(12 * 3600)
        let tomorrow = today.addingTimeInterval(86_400)
        let events = [
            event("past", today.addingTimeInterval(9 * 3600), minutes: 30),
            event("running", today.addingTimeInterval(11.5 * 3600), minutes: 60),
            event("later", today.addingTimeInterval(15 * 3600), minutes: 30),
            event("tomorrow", tomorrow.addingTimeInterval(9 * 3600), minutes: 30),
            event("day-after", tomorrow.addingTimeInterval(86_400 + 9 * 3600), minutes: 30),
            event("holiday", today, minutes: 24 * 60, allDay: true),
            event("trip", today, minutes: 48 * 60, allDay: true),
        ]
        let upNext = ShelfUpNext.select(events, now: now, count: 5, calendar: calendar)
        #expect(upNext.timed.map(\.id) == ["running", "later", "tomorrow"])
        #expect(upNext.allDayToday.map(\.id) == ["holiday", "trip"])
        #expect(upNext.allDayTomorrow.map(\.id) == ["trip"])
        #expect(ShelfUpNext.select(events, now: now, count: 1, calendar: calendar).timed.map(\.id) == ["running"])
    }
}
