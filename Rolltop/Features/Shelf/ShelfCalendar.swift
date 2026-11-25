import AppKit
import EventKit

/// Calendar access as the shelf needs it (full read access).
nonisolated enum ShelfCalendarAccess: String, Sendable, CaseIterable {
    case notDetermined = "not-determined"
    case denied
    case restricted
    /// Rolltop may add events but not read them: not enough for Up next.
    case writeOnly = "write-only"
    case granted

    init(_ status: EKAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .restricted: self = .restricted
        case .denied: self = .denied
        case .fullAccess: self = .granted
        case .writeOnly: self = .writeOnly
        @unknown default: self = .denied
        }
    }
}

/// One event row of Up next.
nonisolated struct ShelfEvent: Identifiable, Sendable, Equatable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var calendarTitle: String
    /// sRGB components of the calendar colour.
    var color: [Double]?
    var meetingLink: ShelfMeetingLink?
}

/// What Up next shows: all-day events per day in one compact line, then the next timed
/// events that have not ended. Pure, testable.
nonisolated struct ShelfUpNext: Sendable, Equatable {
    var allDayToday: [ShelfEvent] = []
    var allDayTomorrow: [ShelfEvent] = []
    var timed: [ShelfEvent] = []

    var isEmpty: Bool { allDayToday.isEmpty && allDayTomorrow.isEmpty && timed.isEmpty }

    /// The window Up next reads: from the start of today to the end of tomorrow.
    static func window(now: Date, calendar: Calendar = .current) -> DateInterval {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 2, to: start) ?? now.addingTimeInterval(2 * 86_400)
        return DateInterval(start: start, end: end)
    }

    static func select(_ events: [ShelfEvent], now: Date, count: Int, calendar: Calendar = .current) -> ShelfUpNext {
        let window = window(now: now, calendar: calendar)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: window.start) ?? window.end
        var result = ShelfUpNext()
        let inWindow = events.filter { $0.end > window.start && $0.start < window.end }
        for event in inWindow where event.isAllDay {
            // An all-day event spanning both days shows on each.
            if event.start < tomorrow, event.end > now { result.allDayToday.append(event) }
            if event.end > tomorrow, event.start < window.end { result.allDayTomorrow.append(event) }
        }
        result.timed = Array(inWindow.filter { !$0.isAllDay && $0.end > now }
            .sorted { ($0.start, $0.title) < ($1.start, $1.title) }
            .prefix(max(0, count)))
        return result
    }
}

/// Where events come from: EventKit, or (Debug) injected samples.
protocol ShelfEventSource: AnyObject {
    var access: ShelfCalendarAccess { get }
    /// Asks macOS for full access. Only call from a user's click on the Up next switch or
    /// the section's button: it shows the system's Calendar dialog.
    func requestAccess() async -> ShelfCalendarAccess
    func events(in interval: DateInterval) -> [ShelfEvent]
}

/// EventKit. The store is created only once access is granted or the user asked for it, so
/// merely running Rolltop never touches the Calendar database.
final class ShelfEventKitSource: ShelfEventSource {
    private var store: EKEventStore?
    private let log = Log.logger("shelf")

    var access: ShelfCalendarAccess { ShelfCalendarAccess(EKEventStore.authorizationStatus(for: .event)) }

    func requestAccess() async -> ShelfCalendarAccess {
        guard access == .notDetermined else { return access }
        let store = store ?? EKEventStore()
        self.store = store
        log.info("requesting Calendar access (user action)")
        do { _ = try await store.requestFullAccessToEvents() } catch {
            log.error("Calendar access request failed: \(error.localizedDescription)")
        }
        return access
    }

    func events(in interval: DateInterval) -> [ShelfEvent] {
        guard access == .granted else { return [] }
        let store = store ?? EKEventStore()
        self.store = store
        let predicate = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: nil)
        return store.events(matching: predicate).map(Self.event)
    }

    private static func event(_ event: EKEvent) -> ShelfEvent {
        var color: [Double]?
        if let rgb = event.calendar?.color?.usingColorSpace(.sRGB) {
            color = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map(Double.init)
        }
        let link = ShelfMeetingLinks.detect(in: [event.url?.absoluteString, event.location, event.notes])
        return ShelfEvent(id: event.calendarItemIdentifier + "@" + String(event.startDate.timeIntervalSince1970),
                          title: event.title ?? "", start: event.startDate, end: event.endDate, isAllDay: event.isAllDay,
                          calendarTitle: event.calendar?.title ?? "", color: color, meetingLink: link)
    }
}

#if DEBUG
/// Debug: a fixed access state and sample events instead of EventKit (live tests never
/// trigger the real Calendar dialog).
final class ShelfSampleEventSource: ShelfEventSource {
    var access: ShelfCalendarAccess
    var samples: [ShelfEvent]

    init(access: ShelfCalendarAccess, samples: [ShelfEvent]) {
        self.access = access
        self.samples = samples
    }

    func requestAccess() async -> ShelfCalendarAccess { access }

    func events(in interval: DateInterval) -> [ShelfEvent] {
        access == .granted ? samples.filter { $0.end > interval.start && $0.start < interval.end } : []
    }

    static func sampleEvents(now: Date, calendar: Calendar = .current) -> [ShelfEvent] {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400)
        func at(_ minutes: Double) -> Date {
            // Round to the next 5 minutes so the times read naturally.
            let base = now.addingTimeInterval(minutes * 60)
            let seconds = (base.timeIntervalSinceReferenceDate / 300).rounded(.up) * 300
            return Date(timeIntervalSinceReferenceDate: seconds)
        }
        let zoom = ShelfMeetingLinks.detect(in: ["Agenda attached. Join: https://us02web.zoom.us/j/81234567890?pwd=abc123"])
        let meet = ShelfMeetingLinks.detect(in: ["https://meet.google.com/abc-defg-hij"])
        return [
            ShelfEvent(id: "sample-allday", title: "Release week", start: today, end: tomorrow.addingTimeInterval(86_400), isAllDay: true,
                       calendarTitle: "Work", color: [0.35, 0.6, 0.95]),
            ShelfEvent(id: "sample-1", title: "Design review", start: at(20), end: at(50), isAllDay: false,
                       calendarTitle: "Work", color: [0.35, 0.6, 0.95], meetingLink: zoom),
            ShelfEvent(id: "sample-2", title: "Lunch with Sam", start: at(140), end: at(200), isAllDay: false,
                       calendarTitle: "Personal", color: [0.95, 0.55, 0.2]),
            ShelfEvent(id: "sample-3", title: "Planning sync", start: tomorrow.addingTimeInterval(10 * 3600),
                       end: tomorrow.addingTimeInterval(10.5 * 3600), isAllDay: false,
                       calendarTitle: "Work", color: [0.35, 0.6, 0.95], meetingLink: meet),
        ]
    }
}
#endif
