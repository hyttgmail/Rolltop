import EventKit
import Foundation

/// `.upNext` for other features (widgets): the next timed event from the Shelf's calendar
/// source. Reading the status never prompts; events are read only while full access is
/// granted (the request comes only from a click: the Shelf pane or the `shelf.calendar`
/// consent row). Kept current by EventKit's change notification and a one-minute timer
/// (one status read, and one event query only while authorized).
@Observable
final class ShelfUpNextProvider: UpNextProviding {
    private(set) var isAuthorized = false
    private(set) var nextEvent: UpNextEvent?

    @ObservationIgnored private let source: () -> any ShelfEventSource
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observer: NSObjectProtocol?

    init(source: @escaping () -> any ShelfEventSource) {
        self.source = source
    }

    func start() {
        guard timer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    func refresh(now: Date = Date()) {
        let source = source()
        let authorized = source.access == .granted
        if isAuthorized != authorized { isAuthorized = authorized }
        let next = authorized ? Self.next(in: source.events(in: ShelfUpNext.window(now: now)), now: now) : nil
        if nextEvent != next { nextEvent = next }
    }

    /// The first timed event that has not ended, within today and tomorrow. Pure.
    nonisolated static func next(in events: [ShelfEvent], now: Date) -> UpNextEvent? {
        guard let event = ShelfUpNext.select(events, now: now, count: 1).timed.first else { return nil }
        return UpNextEvent(id: event.id, title: event.title, start: event.start, end: event.end, isAllDay: false,
                           location: nil, calendarColor: event.color)
    }

    /// The consent row's status (never prompts).
    static func consentStatus(_ access: ShelfCalendarAccess) -> ConsentStatus {
        switch access {
        case .granted: .allowed
        case .notDetermined: .notAsked
        case .denied, .writeOnly: .notAllowed
        case .restricted: .unavailable(String(localized: "Calendar access is restricted on this Mac.", table: "Shelf"))
        }
    }
}
