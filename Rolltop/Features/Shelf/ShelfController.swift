import AppKit
import Observation
import Quartz
import SwiftUI

/// Runs the shelf: the panel, its sections' data, the clipboard monitor, the hot-zone
/// monitors and the timers. Every background activity follows `ShelfActivityPlan`, so with
/// every section off nothing runs. Nothing starts before `start()`.
@Observable
final class ShelfController {
    // MARK: State the views read

    private(set) var isVisible = false
    /// Drives the grow-down animation (false while the panel is ordered in or closing).
    var isRevealed = false
    var section: ShelfSection = .clipboard
    var searchText = ""
    var selectedClipID: UUID?
    private(set) var history = ShelfClipHistory()
    private(set) var files = ShelfFileList()
    private(set) var filePresence: [UUID: ShelfFilePresence] = [:]
    private(set) var upNext = ShelfUpNext()
    private(set) var calendarAccess: ShelfCalendarAccess = .notDetermined
    private(set) var pausedUntil: Date?
    var isDropTargeted = false
    /// The general pasteboard refused a read (the user chose "Don't Allow" or always deny).
    private(set) var clipboardReadRefused = false

    // MARK: Internals

    @ObservationIgnored private unowned let context: AppContext
    @ObservationIgnored private var machine = ShelfPanelMachine()
    @ObservationIgnored private(set) var trigger: ShelfOpenTrigger?
    @ObservationIgnored private var panel: ShelfPanel?
    @ObservationIgnored private var store: ShelfStore
    @ObservationIgnored private var monitor: ShelfClipboardMonitor?
    @ObservationIgnored private var eventKit = ShelfEventKitSource()
    @ObservationIgnored private var thumbnails: [UUID: NSImage] = [:]
    @ObservationIgnored private var started = false
    @ObservationIgnored private var settingsObserver: ChangeObserver?
    @ObservationIgnored private var screenObserver: NSObjectProtocol?
    @ObservationIgnored private var resumeTimer: Timer?
    @ObservationIgnored private var expiryTimer: Timer?
    @ObservationIgnored private var hoverMonitors: [Any] = []
    @ObservationIgnored private var dwellTimer: Timer?
    @ObservationIgnored private var dragMonitors: [Any] = []
    @ObservationIgnored private var dragBaseline: Int?
    @ObservationIgnored private var dragCarriesFiles: Bool?
    @ObservationIgnored private var visibleMonitors: [Any] = []
    @ObservationIgnored private var pointerTimer: Timer?
    @ObservationIgnored private var keyWindowObserver: NSObjectProtocol?
    /// The search field (window coordinates, top-left origin): the one place a click may
    /// give the panel the keyboard.
    @ObservationIgnored var searchFieldFrame: CGRect?
    @ObservationIgnored private var lastSection: ShelfSection?
    @ObservationIgnored private(set) var lastSkip: ShelfClipSkipReason?
    @ObservationIgnored private(set) var lastClose: ShelfCloseReason?
    @ObservationIgnored private(set) var dropCount = 0
    @ObservationIgnored private var draggingOutIDs: Set<UUID> = []
    @ObservationIgnored let log = Log.logger("shelf")

    #if DEBUG
    /// Debug-only overrides, in memory only: never persisted, gone at quit.
    var debug = ShelfDebugOverrides()
    /// Where rows and tiles are drawn (window coordinates, top-left origin), for live tests.
    @ObservationIgnored var debugRowFrames: [UUID: CGRect] = [:]
    @ObservationIgnored var debugTileFrames: [UUID: CGRect] = [:]
    var debugPanelIsKey: Bool { panel?.isKeyWindow ?? false }
    #endif

    /// `storageRoot`: tests pass a temporary folder; the app uses Application Support.
    init(context: AppContext, storageRoot: URL = ShelfStore.defaultRoot) {
        self.context = context
        userRoot = storageRoot
        store = ShelfStore(root: storageRoot)
        // Two steps: the closures may capture `self` only once every property is set.
        hints = ShelfHintPresenter(isShelfVisible: { false }, screenFrame: { ShelfController.info(nil) })
        hints = ShelfHintPresenter(isShelfVisible: { [weak self] in self?.isVisible ?? false },
                                   screenFrame: { [weak self] in ShelfController.info(self?.targetScreen()) })
    }

    /// Volume, brightness and battery hints, and the shelf's own notices.
    @ObservationIgnored private(set) var hints: ShelfHintPresenter

    /// Posts the paste key. Tests replace it; nothing else may call
    /// `EventSynthesizer.postPaste()`.
    @ObservationIgnored var paster: @MainActor () -> Bool = { EventSynthesizer.postPaste() }
    @ObservationIgnored var frontmostPID: @MainActor () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }

    /// Where the user's own shelf data lives. Debug sessions move the store elsewhere and
    /// may only wipe that other folder, never this one.
    @ObservationIgnored let userRoot: URL

    /// The store points at a Debug folder, not the user's data.
    var usesDebugStorage: Bool { store.root.standardizedFileURL != userRoot.standardizedFileURL }

    // MARK: Configuration

    var config: ShelfConfig {
        let settings = context.settings
        var config = ShelfConfig()
        config.clipboardEnabled = settings[ShelfSettings.clipboardEnabled]
        config.clipboardLimit = max(1, settings[ShelfSettings.clipboardLimit])
        config.clipboardMaxAge = TimeInterval(max(1, settings[ShelfSettings.clipboardMaxAgeDays])) * 86_400
        config.clipboardClearOnQuit = settings[ShelfSettings.clipboardClearOnQuit]
        config.ignoredApps = Set(settings[ShelfSettings.clipboardIgnoredApps])
        config.filesEnabled = settings[ShelfSettings.filesEnabled]
        config.fileLifetime = ShelfFileLifetime.seconds(hours: settings[ShelfSettings.filesLifetimeHours])
        config.removeAfterDrag = settings[ShelfSettings.filesRemoveAfterDrag]
        config.upNextEnabled = settings[ShelfSettings.upNextEnabled]
        config.upNextCount = max(1, settings[ShelfSettings.upNextCount])
        config.openOnHover = settings[ShelfSettings.openOnHover]
        config.hoverDelay = max(0.1, settings[ShelfSettings.hoverDelay])
        config.openOnDrag = settings[ShelfSettings.openOnDrag]
        config.panelSize = ShelfPanelSize(setting: settings[ShelfSettings.panelSize])
        config.hints = ShelfHintConfig(enabled: settings[ShelfSettings.hintsEnabled], volume: settings[ShelfSettings.hintsVolume],
                                       brightness: settings[ShelfSettings.hintsBrightness], battery: settings[ShelfSettings.hintsBattery])
        config.nowPlayingCard = settings[ShelfSettings.nowPlayingCard]
        config.weatherCard = settings[ShelfSettings.weatherCard]
        config.chooseAction = ShelfChooseAction(setting: settings[ShelfSettings.chooseAction])
        #if DEBUG
        debug.apply(to: &config)
        #endif
        return config
    }

    var storageRoot: URL { store.root }

    var eventSource: any ShelfEventSource {
        #if DEBUG
        if let sample = debug.eventSource { return sample }
        #endif
        return eventKit
    }

    /// The pasteboard the history watches and copies back to: the only place the shelf
    /// reads or writes the general pasteboard's content (`generalAccessBehavior` reads its
    /// access setting only). Debug sessions bind a private named one.
    private var boundPasteboard: NSPasteboard {
        #if DEBUG
        if let name = debug.pasteboardName { return NSPasteboard(name: NSPasteboard.Name(name)) }
        #endif
        return .general
    }

    private func activityInput(_ config: ShelfConfig) -> ShelfActivityInput {
        ShelfActivityInput(clipboardEnabled: config.clipboardEnabled, clipboardPaused: pausedUntil.map { $0 > Date() } ?? false,
                           filesEnabled: config.filesEnabled, upNextEnabled: config.upNextEnabled,
                           openOnHover: config.openOnHover, openOnDrag: config.openOnDrag,
                           fileLifetime: config.fileLifetime, hasFiles: !files.items.isEmpty)
    }

    /// What actually runs right now (Debug dump, acceptance check).
    var runningActivities: [ShelfActivity] {
        var running: [ShelfActivity] = []
        if monitor?.isRunning == true { running.append(.clipboardMonitor) }
        if resumeTimer != nil { running.append(.clipboardResumeTimer) }
        if !hoverMonitors.isEmpty || dwellTimer != nil { running.append(.hoverMonitor) }
        if !dragMonitors.isEmpty { running.append(.dragMonitor) }
        if expiryTimer != nil { running.append(.fileExpiryTimer) }
        return running.sorted()
    }

    var visibleMonitorCount: Int { visibleMonitors.count + (pointerTimer == nil ? 0 : 1) + (keyWindowObserver == nil ? 0 : 1) }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        loadStoredData()
        settingsObserver = ChangeObserver(track: { [weak self] in _ = self?.config }) { [weak self] in self?.reconcile() }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        reconcile()
    }

    func stop() {
        hints.stop()
        dismiss(.api)
        let config = config
        if config.clipboardEnabled, config.clipboardClearOnQuit {
            let removed = history.clearUnpinned()
            store.deleteImages(removed.compactMap(\.imageFile))
            saveHistory()
            log.info("cleared \(removed.count) clips on quit")
        }
        settingsObserver?.cancel()
        settingsObserver = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        stopAllActivities()
        store.flush()
        started = false
    }

    /// Loads what the enabled sections stored; forgets what disabled sections left behind.
    private func loadStoredData() {
        let config = config
        if config.clipboardEnabled {
            history = ShelfClipHistory(clips: store.loadClips())
            pruneHistory()
        } else {
            history = ShelfClipHistory()
            if FileManager.default.fileExists(atPath: store.clipboardURL.path(percentEncoded: false)) { store.wipeClipboard() }
        }
        if config.filesEnabled {
            files = ShelfFileList(items: store.loadFiles())
            expireFiles()
        } else {
            files = ShelfFileList()
            if FileManager.default.fileExists(atPath: store.filesURL.path(percentEncoded: false)) { store.wipeFiles() }
        }
        thumbnails = [:]
    }

    /// Brings running activities and stored data in line with the configuration.
    func reconcile() {
        guard started else { return }
        let config = config
        if !config.clipboardEnabled, !history.clips.isEmpty || FileManager.default.fileExists(atPath: store.clipboardURL.path(percentEncoded: false)) {
            history.removeAll()
            thumbnails = [:]
            pausedUntil = nil
            store.wipeClipboard()
            log.info("clipboard history off: stored clips deleted")
        }
        if !config.clipboardEnabled { pausedUntil = nil }
        if !config.filesEnabled, !files.items.isEmpty || FileManager.default.fileExists(atPath: store.filesURL.path(percentEncoded: false)) {
            files.removeAll()
            filePresence = [:]
            store.wipeFiles()
            log.info("file shelf off: references forgotten")
        }
        let plan = ShelfActivityPlan.activities(activityInput(config))
        applyClipboardMonitor(plan.contains(.clipboardMonitor), config: config)
        applyResumeTimer(plan.contains(.clipboardResumeTimer))
        applyHoverMonitor(plan.contains(.hoverMonitor))
        applyDragMonitor(plan.contains(.dragMonitor))
        applyExpiryTimer(plan.contains(.fileExpiryTimer), config: config)
        if hints.config != config.hints || !hintsApplied {
            hintsApplied = true
            hints.apply(config.hints)
        }
        if isVisible {
            let sections = config.enabledSections
            if !sections.contains(section), let first = sections.first { section = first }
        }
    }

    @ObservationIgnored private var hintsApplied = false

    private func stopAllActivities() {
        applyClipboardMonitor(false, config: config)
        applyResumeTimer(false)
        applyHoverMonitor(false)
        applyDragMonitor(false)
        applyExpiryTimer(false, config: config)
    }

    #if DEBUG
    /// Debug: points the stores at another folder (reloads) or back to the default.
    func debugSetStorageRoot(_ root: URL?) {
        store.flush()
        store = ShelfStore(root: root ?? userRoot)
        loadStoredData()
        reconcile()
    }

    /// Debug: re-creates the monitor on the bound pasteboard.
    func debugRebindPasteboard() {
        monitor?.stop()
        monitor = nil
        reconcile()
    }

    func debugPollNow() { monitor?.poll() }

    var debugBoundPasteboard: NSPasteboard { boundPasteboard }
    #endif

    // MARK: Clipboard history

    private func applyClipboardMonitor(_ run: Bool, config: ShelfConfig) {
        if run {
            let pasteboard = boundPasteboard
            if monitor == nil || monitor?.pasteboard.name != pasteboard.name {
                monitor?.stop()
                let monitor = ShelfClipboardMonitor(pasteboard: pasteboard)
                monitor.onOutcome = { [weak self] outcome in self?.handle(outcome) }
                self.monitor = monitor
            }
            #if DEBUG
            if let interval = debug.pollInterval { monitor?.interval = interval }
            #endif
            monitor?.ignoredApps = config.ignoredApps
            monitor?.start()
        } else {
            monitor?.stop()
        }
    }

    private func applyResumeTimer(_ run: Bool) {
        guard run, let until = pausedUntil else {
            resumeTimer?.invalidate()
            resumeTimer = nil
            return
        }
        guard resumeTimer == nil else { return }
        let timer = Timer(fire: until, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
        }
        RunLoop.main.add(timer, forMode: .common)
        resumeTimer = timer
    }

    private func handle(_ outcome: ShelfClipboardMonitor.Outcome) {
        switch outcome {
        case .ownWrite:
            break
        case .skipped(let reason):
            lastSkip = reason
        case .read(let read):
            let config = config
            let candidate: ShelfClipCandidate
            switch ShelfClipClassifier.candidate(from: read.content) {
            case .success(let value): candidate = value
            case .failure(let reason):
                lastSkip = reason
                // Types were present but nothing could be read: macOS refused (general only).
                if reason == .empty, monitor?.isGeneral == true { clipboardReadRefused = true }
                return
            }
            clipboardReadRefused = false
            var imageFile: String?
            let id = UUID()
            if candidate.kind == .image, let data = candidate.image {
                if let existing = history.clips.first(where: { $0.fingerprint == candidate.fingerprint })?.imageFile {
                    imageFile = existing
                } else {
                    imageFile = id.uuidString + ".png"
                    store.saveImage(data, name: imageFile!)
                    thumbnails[id] = NSImage(data: data)
                }
            }
            let source = read.content.declaredSource ?? read.frontmostBundleID
            history.record(candidate, source: source, imageFile: imageFile, now: Date(), id: id)
            pruneHistory(limit: config.clipboardLimit, maxAge: config.clipboardMaxAge)
            saveHistory()
            log.info("recorded a \(candidate.kind.rawValue) clip (\(history.clips.count) in history)")
        }
    }

    private func pruneHistory(limit: Int? = nil, maxAge: TimeInterval? = nil) {
        let config = config
        let removed = history.prune(now: Date(), limit: limit ?? config.clipboardLimit, maxAge: maxAge ?? config.clipboardMaxAge)
        guard !removed.isEmpty else { return }
        store.deleteImages(removed.compactMap(\.imageFile))
        for clip in removed { thumbnails[clip.id] = nil }
        saveHistory()
    }

    private func saveHistory() {
        if history.clips.isEmpty {
            store.wipeClipboard()
        } else {
            store.saveClips(history.clips)
        }
    }

    var visibleClips: [ShelfClip] { history.visible(matching: searchText) }

    func thumbnail(for clip: ShelfClip) -> NSImage? {
        if let cached = thumbnails[clip.id] { return cached }
        guard let name = clip.imageFile, let image = NSImage(contentsOf: store.imageURL(name)) else { return nil }
        thumbnails[clip.id] = image
        return image
    }

    /// Copies a clip back to the clipboard and closes the shelf.
    func copy(_ id: UUID) {
        guard writeClip(id) else { return }
        send(.used)
    }

    /// Puts a clip on the clipboard as copying does (the monitor does not record it again).
    private func writeClip(_ id: UUID) -> Bool {
        guard let clip = history.clip(id) else { return false }
        let image = clip.imageFile.flatMap { try? Data(contentsOf: store.imageURL($0)) }
        let writer = monitor ?? {
            let monitor = ShelfClipboardMonitor(pasteboard: boundPasteboard)
            monitor.onOutcome = { [weak self] outcome in self?.handle(outcome) }
            self.monitor = monitor
            return monitor
        }()
        guard writer.write(clip, image: image) else {
            log.error("copying a \(clip.kind.rawValue) clip back failed")
            NSSound.beep()
            return false
        }
        history.touch(id, now: Date())
        saveHistory()
        log.info("copied a \(clip.kind.rawValue) clip back")
        return true
    }

    // MARK: Choosing a clip (copy, or copy and paste)

    /// The app a paste goes to: the one that was frontmost when the shelf or Search opened,
    /// else the frontmost app unless it is Rolltop.
    func pasteTargetPID() -> pid_t? {
        if let previous = context.services[.surfaces].previousApp, !previous.isTerminated { return previous.processIdentifier }
        let own = ProcessInfo.processInfo.processIdentifier
        guard let front = frontmostPID(), front != own else { return nil }
        return front
    }

    /// Choosing a clip: the setting, or the other action for an Option-click / ⌘Return.
    /// `target`: the app to paste into, when the caller captured it earlier (Search).
    func choose(_ id: UUID, alternate: Bool, target: pid_t?? = nil) {
        let action = ShelfChooseAction.resolve(setting: config.chooseAction, alternate: alternate)
        guard action == .paste else { copy(id); return }
        let target = target ?? pasteTargetPID()
        var post = paster
        #if DEBUG
        // A Debug test session (private pasteboard bound) never posts a key, whatever
        // drives it (palette Debug keys, row activation): it reports "not trusted" instead.
        if debug.pasteboardName != nil {
            post = { [log] in log.info("paste suppressed in a Debug test session"); return false }
        }
        #endif
        let flow = ShelfPasteFlow(copy: { [weak self] in self?.writeClip(id) ?? false },
                                  close: { [weak self] in self?.send(.used) },
                                  frontmostPID: frontmostPID, post: post)
        Task { @MainActor [weak self] in
            let outcome = await flow.run(target: target)
            self?.report(outcome)
        }
    }

    private func report(_ outcome: ShelfPasteOutcome) {
        log.info("paste: \(outcome.rawValue)")
        if let text = outcome.notice { hints.post(.notice(text)) }
    }

    // MARK: Cards

    var nowPlaying: any NowPlayingProviding {
        #if DEBUG
        if let sample = debug.nowPlaying { return sample }
        #endif
        return context.services[.nowPlaying]
    }

    var weather: any WeatherProviding {
        #if DEBUG
        if let sample = debug.weather { return sample }
        #endif
        return context.services[.weather]
    }

    func perform(_ command: NowPlayingCommand) {
        let provider = nowPlaying
        Task { @MainActor in _ = await provider.perform(command) }
    }

    /// Opens another settings pane (Permissions, Weather) and closes the shelf.
    func openSettings(pane: String) {
        dismiss(.used)
        context.services[.settingsWindow].showSettings(paneID: pane)
    }

    func setPinned(_ id: UUID, _ pinned: Bool) {
        history.setPinned(id, pinned)
        saveHistory()
    }

    func delete(_ id: UUID) {
        guard let clip = history.delete(id) else { return }
        if let image = clip.imageFile { store.deleteImages([image]) }
        thumbnails[id] = nil
        saveHistory()
    }

    func clearHistory() {
        let removed = history.clearUnpinned()
        store.deleteImages(removed.compactMap(\.imageFile))
        for clip in removed { thumbnails[clip.id] = nil }
        saveHistory()
        log.info("cleared \(removed.count) clips")
    }

    /// Pauses recording for `minutes` (0 resumes). What is copied meanwhile is never read.
    func pause(minutes: Int) {
        guard minutes > 0 else { resume(); return }
        pausedUntil = Date().addingTimeInterval(TimeInterval(minutes) * 60)
        resumeTimer?.invalidate()
        resumeTimer = nil
        log.info("clipboard history paused for \(minutes) min")
        reconcile()
    }

    func resume() {
        pausedUntil = nil
        resumeTimer?.invalidate()
        resumeTimer = nil
        log.info("clipboard history resumed")
        reconcile()
    }

    /// The general pasteboard's access behaviour for Rolltop (Settings shows it).
    var generalAccessBehavior: NSPasteboard.AccessBehavior { NSPasteboard.general.accessBehavior }

    // MARK: File shelf

    func addFiles(_ urls: [URL]) {
        let accepted = ShelfDropPlanner.fileURLs(from: urls)
        guard config.filesEnabled, !accepted.isEmpty else { return }
        let drops = accepted.map { url -> ShelfFileDrop in
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            return ShelfFileDrop(path: url.path(percentEncoded: false), bookmark: bookmark, isDirectory: isDirectory)
        }
        files.add(drops, now: Date())
        store.saveFiles(files.items)
        refreshPresence()
        reconcile()
        log.info("added \(drops.count) files to the shelf (\(files.items.count) held)")
    }

    func removeFile(_ id: UUID) {
        files.remove(id)
        filePresence[id] = nil
        saveFiles()
        reconcile()
    }

    func clearFiles() {
        files.removeAll()
        filePresence = [:]
        saveFiles()
        reconcile()
    }

    private func saveFiles() {
        if files.items.isEmpty { store.wipeFiles() } else { store.saveFiles(files.items) }
    }

    /// Resolves bookmarks (follows moves) and marks files that are gone.
    func refreshPresence() {
        var presence: [UUID: ShelfFilePresence] = [:]
        var moved = false
        for item in files.items {
            let url = resolve(item)
            if let url, url.path(percentEncoded: false) != item.path {
                files.updatePath(item.id, to: url.path(percentEncoded: false))
                moved = true
            }
            presence[item.id] = url == nil ? .missing : .present
        }
        filePresence = presence
        if moved { store.saveFiles(files.items) }
    }

    /// The file's current URL, nil when it is gone.
    func resolve(_ item: ShelfFileItem) -> URL? {
        if let bookmark = item.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                  relativeTo: nil, bookmarkDataIsStale: &stale),
               FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                return url
            }
        }
        return FileManager.default.fileExists(atPath: item.path) ? URL(filePath: item.path) : nil
    }

    func url(for id: UUID) -> URL? { files.items.first { $0.id == id }.flatMap(resolve) }

    func openFile(_ id: UUID) {
        guard let url = url(for: id) else { NSSound.beep(); return }
        NSWorkspace.shared.open(url)
        send(.used)
    }

    func revealFile(_ id: UUID) {
        guard let url = url(for: id) else { NSSound.beep(); return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        send(.used)
    }

    func quickLook(_ id: UUID) {
        guard let url = url(for: id), let panel else { NSSound.beep(); return }
        send(.interacted)
        panel.quickLookURLs = [url]
        panel.makeKey()
        panel.allowKeyOnce()
        let preview = QLPreviewPanel.shared()
        if preview?.isVisible == true { preview?.reloadData() } else { preview?.makeKeyAndOrderFront(nil) }
    }

    func dragOutBegan(_ id: UUID) {
        draggingOutIDs.insert(id)
        send(.interacted)
    }

    func dragOutEnded(_ id: UUID, accepted: Bool) {
        draggingOutIDs.remove(id)
        if accepted, config.removeAfterDrag {
            removeFile(id)
            log.info("file dragged out and removed")
        }
    }

    /// Whether a drag over the panel comes from one of the shelf's own tiles.
    var isDraggingOut: Bool { !draggingOutIDs.isEmpty }

    /// A drop on the panel completed.
    func dropped(_ urls: [URL]) {
        addFiles(urls)
        dropCount += 1
        isDropTargeted = false
        // Let the new tiles show for a moment, then close.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            self?.send(.dropCompleted)
        }
    }

    private func expireFiles() {
        let removed = files.expire(now: Date(), lifetime: config.fileLifetime)
        guard !removed.isEmpty else { return }
        for item in removed { filePresence[item.id] = nil }
        saveFiles()
        log.info("\(removed.count) shelf files expired")
    }

    private func applyExpiryTimer(_ run: Bool, config: ShelfConfig) {
        expiryTimer?.invalidate()
        expiryTimer = nil
        guard run, let next = files.nextExpiry(lifetime: config.fileLifetime) else { return }
        let timer = Timer(fire: max(next, Date().addingTimeInterval(0.2)), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.expiryTimer = nil
                self.expireFiles()
                self.reconcile()
            }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        expiryTimer = timer
    }

    // MARK: Up next

    func refreshEvents() {
        let config = config
        guard config.upNextEnabled else { upNext = ShelfUpNext(); return }
        let source = eventSource
        calendarAccess = source.access
        guard calendarAccess == .granted else { upNext = ShelfUpNext(); return }
        let now = Date()
        upNext = ShelfUpNext.select(source.events(in: ShelfUpNext.window(now: now)), now: now, count: config.upNextCount)
    }

    /// From a user's click only (the Up next switch or the section's button).
    func requestCalendarAccess() {
        let source = eventSource
        switch source.access {
        case .notDetermined:
            Task { [weak self] in
                _ = await source.requestAccess()
                self?.refreshEvents()
            }
        case .denied, .restricted, .writeOnly:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                NSWorkspace.shared.open(url)
            }
        case .granted:
            refreshEvents()
        }
    }

    var currentCalendarAccess: ShelfCalendarAccess { eventSource.access }

    /// Reads the status only (never asks macOS).
    func refreshCalendarAccess() { calendarAccess = eventSource.access }

    func join(_ link: ShelfMeetingLink) {
        NSWorkspace.shared.open(link.url)
        send(.used)
    }

    // MARK: Opening and closing

    /// Id of this surface in `services[.surfaces]`.
    static let surfaceID = "shelf"

    func toggle() { send(.toggle) }

    func show(section requested: ShelfSection?) {
        if let requested { lastSection = requested }
        send(.show)
        if let requested, isVisible, config.enabledSections.contains(requested) { select(requested) }
    }

    func dismiss(_ reason: ShelfCloseReason) {
        guard isVisible else { machine.reset(); return }
        machine.reset()
        perform(.close(reason))
    }

    func select(_ section: ShelfSection) {
        self.section = section
        lastSection = section
        if section == .upNext { refreshEvents() }
        if section == .files { refreshPresence() }
    }

    func send(_ event: ShelfPanelMachine.Event) {
        perform(machine.handle(event))
    }

    private func perform(_ effect: ShelfPanelMachine.Effect) {
        switch effect {
        case .none: break
        case .open(let trigger): present(trigger: trigger)
        case .refresh: break
        case .close(let reason): close(reason)
        }
    }

    private func present(trigger: ShelfOpenTrigger) {
        // One transient surface at a time: the Rolltop Bar, the palette or a group yields; when
        // one of them opens later, the shelf yields to it.
        context.services[.surfaces].willPresent(Self.surfaceID) { [weak self] _ in self?.send(.otherPanelOpened) }
        self.trigger = trigger
        let config = config
        let sections = config.enabledSections
        if trigger == .drag, sections.contains(.files) {
            section = .files
        } else if let lastSection, sections.contains(lastSection) {
            section = lastSection
        } else if let first = sections.first {
            section = first
        }
        searchText = ""
        selectedClipID = nil
        if config.clipboardEnabled { pruneHistory() }
        if config.filesEnabled { expireFiles(); refreshPresence() }
        if config.upNextEnabled { refreshEvents() } else { calendarAccess = eventSource.access }

        let screen = targetScreen()
        let frame = ShelfGeometry.panelFrame(size: config.panelSize.size, screen: Self.info(screen))
        let panel = panel ?? makePanel()
        #if DEBUG
        panel.appearance = debug.appearance.flatMap(NSAppearance.init(named:))
        #endif
        panel.setFrame(frame, display: false)
        isVisible = true
        isRevealed = false
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        Task { @MainActor [weak self] in
            await Task.yield()
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.32, bounce: 0.12)) {
                self?.isRevealed = true
            }
        }
        startVisibleMonitors()
        log.info("shelf opened (\(trigger.rawValue)) on \(screen.map { "\(Int($0.frame.width))×\(Int($0.frame.height))" } ?? "?") showing \(sections.map(\.rawValue))")
    }

    private func close(_ reason: ShelfCloseReason) {
        guard isVisible, let panel else { return }
        isVisible = false
        lastClose = reason
        trigger = nil
        isDropTargeted = false
        stopVisibleMonitors()
        panel.revokeKey()
        // Closed by the user's choice: the app that was frontmost gets the keyboard back if a
        // Rolltop surface (the search field, the palette before it) took it. A click elsewhere
        // keeps the app the user chose; a surface that takes over keeps it too.
        context.services[.surfaces].didDismiss(Self.surfaceID, restoreFocus: [.escape, .toggled, .used].contains(reason))
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared()?.isVisible == true {
            QLPreviewPanel.shared()?.orderOut(nil)
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(reduceMotion ? .easeIn(duration: 0.1) : .easeIn(duration: 0.16)) { isRevealed = false }
        Task { @MainActor [weak self, weak panel] in
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 120 : 190))
            guard let self, !self.isVisible else { return }
            panel?.orderOut(nil)
        }
        log.info("shelf closed: \(reason.rawValue)")
    }

    private func makePanel() -> ShelfPanel {
        let panel = ShelfPanel(controller: self)
        panel.onEscape = { [weak self] in self?.send(.escape) }
        panel.keyRegion = { [weak self] in
            guard let self, self.section == .clipboard else { return nil }
            return self.searchFieldFrame
        }
        self.panel = panel
        return panel
    }

    var panelFrame: CGRect? { isVisible ? panel?.frame : nil }

    // MARK: Screens

    private func targetScreen() -> NSScreen? {
        #if DEBUG
        if let selector = debug.display {
            let screens = NSScreen.screens
            switch selector {
            case "notched": if let notched = screens.first(where: { $0.auxiliaryTopLeftArea != nil }) { return notched }
            case "plain": if let plain = screens.first(where: { $0.auxiliaryTopLeftArea == nil }) { return plain }
            case "main": return screens.first
            default: if let index = Int(selector), screens.indices.contains(index) { return screens[index] }
            }
        }
        #endif
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.insetBy(dx: 0, dy: -1).contains(mouse) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    static func info(_ screen: NSScreen?) -> ShelfScreen {
        guard let screen else {
            return ShelfScreen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 876))
        }
        var notch: ClosedRange<CGFloat>?
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea, right.minX > left.maxX {
            notch = left.maxX...right.minX
        }
        return ShelfScreen(frame: screen.frame, visibleFrame: screen.visibleFrame, safeAreaTop: screen.safeAreaInsets.top, notch: notch)
    }

    @ObservationIgnored private var screenCache: [ShelfScreen]?
    private var screens: [ShelfScreen] {
        if let screenCache { return screenCache }
        let infos = NSScreen.screens.map(Self.info)
        screenCache = infos
        return infos
    }

    private func screensChanged() {
        screenCache = nil
        if isVisible { dismiss(.api) }
    }

    // MARK: Hot zone: hover

    private func applyHoverMonitor(_ run: Bool) {
        if run {
            guard hoverMonitors.isEmpty else { return }
            if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] _ in
                self?.pointerMoved()
            }) { hoverMonitors.append(monitor) }
            if let monitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] event in
                self?.pointerMoved()
                return event
            }) { hoverMonitors.append(monitor) }
            log.info("hover hot zone armed")
        } else {
            for monitor in hoverMonitors { NSEvent.removeMonitor(monitor) }
            hoverMonitors.removeAll()
            dwellTimer?.invalidate()
            dwellTimer = nil
        }
    }

    private func pointerInHoverZone() -> Bool {
        let mouse = NSEvent.mouseLocation
        return screens.contains { ShelfGeometry.hoverZone($0).insetBy(dx: 0, dy: -1).contains(mouse) }
    }

    private func pointerMoved() {
        guard !isVisible else { dwellTimer?.invalidate(); dwellTimer = nil; return }
        guard pointerInHoverZone(), NSEvent.pressedMouseButtons == 0 else {
            dwellTimer?.invalidate()
            dwellTimer = nil
            return
        }
        guard dwellTimer == nil else { return }
        let timer = Timer(timeInterval: config.hoverDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.dwellTimer = nil
                if self.pointerInHoverZone(), NSEvent.pressedMouseButtons == 0 { self.send(.hoverDwelled) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        dwellTimer = timer
    }

    // MARK: Hot zone: dragging files

    private func applyDragMonitor(_ run: Bool) {
        if run {
            guard dragMonitors.isEmpty else { return }
            if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
                self?.dragBaseline = NSPasteboard(name: .drag).changeCount
                self?.dragCarriesFiles = nil
            }) { dragMonitors.append(monitor) }
            if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged, handler: { [weak self] _ in
                self?.dragMoved()
            }) { dragMonitors.append(monitor) }
            log.info("drag hot zone armed")
        } else {
            for monitor in dragMonitors { NSEvent.removeMonitor(monitor) }
            dragMonitors.removeAll()
        }
    }

    private func dragMoved() {
        guard !isVisible else { return }
        let mouse = NSEvent.mouseLocation
        guard screens.contains(where: { ShelfGeometry.dragZone($0).insetBy(dx: 0, dy: -1).contains(mouse) }) else { return }
        if dragCarriesFiles == nil {
            // The drag pasteboard is not the general one: reading its types asks nobody.
            let pasteboard = NSPasteboard(name: .drag)
            let fresh = dragBaseline.map { pasteboard.changeCount != $0 } ?? true
            dragCarriesFiles = fresh && ShelfDropPlanner.carriesFiles(types: (pasteboard.types ?? []).map(\.rawValue))
        }
        if dragCarriesFiles == true { send(.dragEnteredZone) }
    }

    // MARK: While visible

    private func startVisibleMonitors() {
        stopVisibleMonitors()
        let mouseDowns: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mouseDowns, handler: { [weak self] event in
            // Rolltop's own synthetic clicks (the item activator's) are not the user clicking away.
            if let cgEvent = event.cgEvent, EventSynthesizer.isSynthesized(cgEvent) { return }
            self?.send(.clickOutside)
        }) { visibleMonitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mouseDowns, handler: { [weak self] event in
            guard let self else { return event }
            if event.window === self.panel || event.window is QLPreviewPanel {
                self.send(.interacted)
            } else {
                self.send(.clickOutside)
            }
            return event
        }) { visibleMonitors.append(monitor) }
        // Escape while another app has the keyboard (needs Accessibility; the key still
        // reaches that app, the shelf never takes the keyboard unless the search field is used).
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.keyCode == 53 { self?.send(.escape) }
        }) { visibleMonitors.append(monitor) }
        if trigger == .hover || trigger == .drag {
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pointerTick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            pointerTimer = timer
        }
        // Another Rolltop panel or window taking the keyboard (the Search panel, Settings):
        // one transient panel at a time, the shelf yields.
        // Helper windows of the text system (input menus, suggestions) are small or attached
        // to the panel and do not count.
        keyWindowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil,
                                                                   queue: .main) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let self, let window, window !== self.panel, !(window is QLPreviewPanel) else { return }
                let attached = window.parent === self.panel || window.sheetParent === self.panel
                guard !attached, window.frame.width >= 240, window.frame.height >= 120 else {
                    self.log.debug("ignored key window \(NSStringFromClass(type(of: window)))")
                    return
                }
                self.log.info("another Rolltop window took the keyboard: \(NSStringFromClass(type(of: window)))")
                self.send(.otherPanelOpened)
            }
        }
    }

    private func stopVisibleMonitors() {
        for monitor in visibleMonitors { NSEvent.removeMonitor(monitor) }
        visibleMonitors.removeAll()
        pointerTimer?.invalidate()
        pointerTimer = nil
        if let keyWindowObserver { NotificationCenter.default.removeObserver(keyWindowObserver) }
        keyWindowObserver = nil
    }

    private func pointerTick() {
        guard isVisible, let panel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = Self.info(NSScreen.screens.first { $0.frame.intersects(panel.frame) })
        let inRegion = isDropTargeted || isDraggingOut
            || ShelfGeometry.keepOpenRegion(screen: screen, panel: panel.frame).contains { $0.contains(mouse) }
        send(.pointer(inRegion: inRegion, now: Date()))
    }

    // MARK: Keyboard (only once the search field has the keyboard)

    func moveSelection(_ delta: Int) {
        let clips = visibleClips
        guard !clips.isEmpty else { selectedClipID = nil; return }
        let index = selectedClipID.flatMap { id in clips.firstIndex { $0.id == id } }
        let next = index.map { min(max($0 + delta, 0), clips.count - 1) } ?? (delta > 0 ? 0 : clips.count - 1)
        selectedClipID = clips[next].id
    }

    func copySelectionOrFirst() {
        if let id = selectedClipID ?? visibleClips.first?.id { choose(id, alternate: false) }
    }

    func openSettings() {
        dismiss(.used)
        context.services[.settingsWindow].showSettings(paneID: "shelf")
    }

    // MARK: Palette

    /// Clipboard rows for the command palette (seam; see `ShelfPaletteRows`).
    func paletteClips(matching query: String, limit: Int) -> [ShelfClip] {
        guard config.clipboardEnabled else { return [] }
        return Array(history.visible(matching: query).prefix(limit))
    }
}
