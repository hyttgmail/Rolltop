import AppKit
import Foundation
import Observation

// Consent rows: every feature that can raise a system prompt (Location, Apple Events to
// a player, Calendars, another app's files…) registers one row, and Settings › Permissions
// lists them under "Features that need your permission", so the user can walk the pane
// once from top to bottom (docs/CONTRACTS.md, "Consent rows").

/// Where a consent stands right now. Read without prompting (see `ConsentItem.status`).
nonisolated enum ConsentStatus: Equatable, Sendable {
    /// Allowed; the feature works.
    case allowed
    /// The user refused it (or turned it off). It can only be changed in System Settings
    /// (or, without a settings URL, by asking again, e.g. a file pick).
    case notAllowed
    /// Never asked yet: the row's button asks.
    case notAsked
    /// Cannot be asked right now; the reason is short and localized and says what to do
    /// ("Open Music first", "Turn on Location Services…"). No button until it changes.
    case cannotAskNow(String)
    /// The feature cannot get this permission on this Mac; the reason is localized.
    case unavailable(String)
}

/// The row's main button for a status. Pure, so the pane and tests agree.
nonisolated enum ConsentAction: Equatable, Sendable {
    /// Runs the item's `request` (the only place a system prompt may appear).
    case ask
    /// Opens the item's `settingsURL`.
    case openSystemSettings

    /// `notAsked` asks; `notAllowed` opens System Settings when the item has a settings URL,
    /// otherwise asks again; `allowed`, `cannotAskNow` and `unavailable` have no main button.
    static func primary(for status: ConsentStatus, hasSettingsURL: Bool) -> ConsentAction? {
        switch status {
        case .notAsked: .ask
        case .notAllowed: hasSettingsURL ? .openSystemSettings : .ask
        case .allowed, .cannotAskNow, .unavailable: nil
        }
    }

    /// The secondary action shows in every status except `unavailable`.
    static func showsSecondary(for status: ConsentStatus) -> Bool {
        if case .unavailable = status { false } else { true }
    }

    /// Buttons work only in a Rolltop opened through LaunchServices (Applications, Spotlight,
    /// login): macOS records a permission for the responsible process, which is the
    /// terminal for a Rolltop started from a shell.
    static func buttonsEnabled(launchedByLaunchServices: Bool) -> Bool { launchedByLaunchServices }
}

/// A second button on a consent row ("Choose File…"). Runs only from its click.
struct ConsentSecondaryAction {
    var title: LocalizedStringResource
    var action: @MainActor () async -> Void

    init(title: LocalizedStringResource, action: @escaping @MainActor () async -> Void) {
        self.title = title
        self.action = action
    }
}

/// One row of "Features that need your permission".
///
///     context.services[.consents].register(ConsentItem(
///         id: "media.music", title: LocalizedStringResource("Music", table: "Media"),
///         purpose: LocalizedStringResource("Shows what is playing in Music and lets you control it.", table: "Media"),
///         sortOrder: 300,
///         status: { [unowned media] in media.musicConsentStatus() },      // never prompts
///         request: { [unowned media] in await media.askMusicConsent() },   // the only prompt
///         settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")))
struct ConsentItem: Identifiable {
    /// `<feature-id>.<name>` (`location.access` is the one exception: shared Platform state).
    let id: String
    /// The permission's name, after the System Settings pane or the thing it unlocks
    /// ("Location Services", "Music"). Title case like other permission titles.
    var title: LocalizedStringResource
    /// One sentence: what starts working once it is allowed.
    var purpose: LocalizedStringResource
    /// Rows are sorted by `sortOrder`, then `id` (CONTRACTS.md lists the assigned orders).
    var sortOrder: Int
    /// **Contract:** main actor, cheap (no blocking I/O, no waiting on another process
    /// beyond a non-prompting status call), never raises a prompt and never touches the
    /// protected resource itself (no file read, no Apple event, no location fix). Called
    /// only by `ConsentRegistry.refresh()`, i.e. while Settings › Permissions is visible.
    var status: @MainActor () -> ConsentStatus
    /// **Contract:** runs only from the row's button (through `ConsentRegistry.request(id:)`)
    /// and is the only code that may raise this permission's system prompt. Set your
    /// feature's persisted "the user asked" marker here (a transient settings key) before
    /// touching the protected API. May return before the user answers; the pane re-reads
    /// statuses every ~2 s.
    var request: @MainActor () async -> Void
    /// Where the user changes a refused permission (a `x-apple.systempreferences:` link).
    var settingsURL: URL?
    var secondaryAction: ConsentSecondaryAction?

    init(id: String, title: LocalizedStringResource, purpose: LocalizedStringResource, sortOrder: Int,
         status: @escaping @MainActor () -> ConsentStatus, request: @escaping @MainActor () async -> Void,
         settingsURL: URL? = nil, secondaryAction: ConsentSecondaryAction? = nil) {
        self.id = id
        self.title = title
        self.purpose = purpose
        self.sortOrder = sortOrder
        self.status = status
        self.request = request
        self.settingsURL = settingsURL
        self.secondaryAction = secondaryAction
    }
}

/// Every registered consent row and its last-read status. The service's default *is* the
/// registry: resolve it and `register`; never replace the service.
///
/// Registering is inert: statuses are read only by `refresh()`, which Settings › Permissions
/// calls when it appears, about every 2 s while visible, and after each request.
@Observable
final class ConsentRegistry {
    /// Sorted by `sortOrder`, then `id`.
    private(set) var items: [ConsentItem] = []
    /// Last status read by `refresh()`; missing until the first refresh after registration.
    private(set) var statuses: [String: ConsentStatus] = [:]
    /// Ids whose `request` is running.
    private(set) var requesting: Set<String> = []
    /// Bumps when the items change or a refresh finds a different status.
    private(set) var revision = 0

    /// Adds a row or replaces the one with the same id (its last status is dropped).
    func register(_ item: ConsentItem) {
        items.removeAll { $0.id == item.id }
        items.append(item)
        items.sort(by: Self.precedes)
        statuses[item.id] = nil
        revision += 1
    }

    func unregister(id: String) {
        guard items.contains(where: { $0.id == id }) else { return }
        items.removeAll { $0.id == id }
        statuses[id] = nil
        revision += 1
    }

    func item(id: String) -> ConsentItem? { items.first { $0.id == id } }

    func status(for id: String) -> ConsentStatus? { statuses[id] }

    /// Re-reads every item's status; bumps `revision` when any differs from the last read.
    func refresh() {
        var next: [String: ConsentStatus] = [:]
        for item in items { next[item.id] = item.status() }
        if next != statuses {
            statuses = next
            revision += 1
        }
    }

    /// Runs the item's `request` (once at a time per item), then refreshes. Call only from
    /// the user's click on that row.
    func request(id: String) async {
        guard let item = item(id: id), !requesting.contains(id) else { return }
        requesting.insert(id)
        await item.request()
        requesting.remove(id)
        refresh()
    }

    /// Order of rows: `sortOrder`, then `id`.
    static func precedes(_ lhs: ConsentItem, _ rhs: ConsentItem) -> Bool {
        (lhs.sortOrder, lhs.id) < (rhs.sortOrder, rhs.id)
    }
}

extension ServiceKey where Service == ConsentRegistry {
    static var consents: Self { .init("settings-shell.consents") { _ in ConsentRegistry() } }
}
