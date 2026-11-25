#if DEBUG
import AppKit
import RolltopCore

/// Debug-only overrides of the shelf, held in memory only: a crash or a lock takeover leaves
/// nothing behind that would make the next launch record the real clipboard.
struct ShelfDebugOverrides {
    /// A private named pasteboard the history watches and copies back to.
    var pasteboardName: String?
    var clipboardEnabled: Bool?
    var filesEnabled: Bool?
    var upNextEnabled: Bool?
    var openOnHover: Bool?
    var openOnDrag: Bool?
    var removeAfterDrag: Bool?
    var hoverDelay: Double?
    /// Seconds; `.some(nil)` = until removed.
    var fileLifetime: TimeInterval??
    var pollInterval: TimeInterval?
    var panelSize: ShelfPanelSize?
    var eventSource: ShelfSampleEventSource?
    /// `main`, `notched`, `plain` or a screen index.
    var display: String?
    var appearance: NSAppearance.Name?
    var hints: ShelfHintConfig?
    var nowPlaying: ShelfSampleNowPlaying?
    var weather: ShelfSampleWeather?

    var isEmpty: Bool {
        pasteboardName == nil && clipboardEnabled == nil && filesEnabled == nil && upNextEnabled == nil && openOnHover == nil
            && openOnDrag == nil && removeAfterDrag == nil && hoverDelay == nil && fileLifetime == nil && pollInterval == nil && panelSize == nil
            && eventSource == nil && display == nil && appearance == nil && hints == nil && nowPlaying == nil && weather == nil
    }

    func apply(to config: inout ShelfConfig) {
        if let clipboardEnabled { config.clipboardEnabled = clipboardEnabled }
        if let filesEnabled { config.filesEnabled = filesEnabled }
        if let upNextEnabled { config.upNextEnabled = upNextEnabled }
        if let openOnHover { config.openOnHover = openOnHover }
        if let openOnDrag { config.openOnDrag = openOnDrag }
        if let removeAfterDrag { config.removeAfterDrag = removeAfterDrag }
        if let hoverDelay { config.hoverDelay = hoverDelay }
        if let fileLifetime { config.fileLifetime = fileLifetime }
        if let panelSize { config.panelSize = panelSize }
        if let hints { config.hints = hints }
    }
}

/// The Debug commands of the shelf (`shelf.debug-*`), for live tests.
enum ShelfDebugCommands {
    /// A plain coloured square as sample artwork.
    static func debugArtwork() -> NSImage {
        NSImage(size: CGSize(width: 64, height: 64), flipped: false) { rect in
            NSColor.systemIndigo.setFill()
            rect.fill()
            NSColor.systemPink.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 16, dy: 16)).fill()
            return true
        }
    }

    static func make(controller: ShelfController) -> [Command] {
        [
            // In-memory switches. Clipboard history can only be switched on here together
            // with (or after) binding a private pasteboard, never on the general one.
            Command(id: "shelf.debug-configure", title: "Configure Shelf (Debug)", symbol: "slider.horizontal.3",
                    arguments: [
                        CommandArgument(name: "pasteboard", title: "Private pasteboard name", isRequired: false),
                        CommandArgument(name: "storage", title: "Storage folder", isRequired: false),
                        CommandArgument(name: "clipboard", title: "Clipboard", isRequired: false, allowedValues: ["on", "off", "default"]),
                        CommandArgument(name: "files", title: "Files", isRequired: false, allowedValues: ["on", "off", "default"]),
                        CommandArgument(name: "up-next", title: "Up next", isRequired: false, allowedValues: ["on", "off", "default"]),
                        CommandArgument(name: "hover", title: "Hover", isRequired: false, allowedValues: ["on", "off", "default"]),
                        CommandArgument(name: "drag", title: "Drag", isRequired: false, allowedValues: ["on", "off", "default"]),
                        CommandArgument(name: "remove-after-drag", title: "Remove after drag", isRequired: false, allowedValues: ["on", "off", "default"]),
                        CommandArgument(name: "hover-delay", title: "Hover delay", isRequired: false),
                        CommandArgument(name: "file-lifetime", title: "File lifetime (s, 0 = until removed)", isRequired: false),
                        CommandArgument(name: "poll", title: "Poll interval (s)", isRequired: false),
                        CommandArgument(name: "size", title: "Panel size", isRequired: false, allowedValues: ShelfPanelSize.allCases.map(\.rawValue)),
                        CommandArgument(name: "display", title: "Display", isRequired: false),
                        CommandArgument(name: "appearance", title: "Appearance", isRequired: false, allowedValues: ["system", "light", "dark"]),
                    ],
                    allowedFromURL: true) { invocation in
                try configure(controller, invocation)
            },
            // Writes to the bound private pasteboard (refused without one) and polls at once.
            Command(id: "shelf.debug-write-pasteboard", title: "Write Test Pasteboard", symbol: "doc.on.clipboard",
                    arguments: [
                        CommandArgument(name: "text", title: "Text", isRequired: false),
                        CommandArgument(name: "url", title: "URL", isRequired: false),
                        CommandArgument(name: "marker", title: "Marker", isRequired: false, allowedValues: ["concealed", "transient", "auto-generated"]),
                    ],
                    allowedFromURL: true) { invocation in
                guard let name = controller.debug.pasteboardName else { throw CommandError.failed("no private pasteboard bound") }
                let pasteboard = NSPasteboard(name: NSPasteboard.Name(name))
                guard pasteboard.name != .general else { throw CommandError.failed("refusing the general pasteboard") }
                pasteboard.clearContents()
                let item = NSPasteboardItem()
                if let url = invocation.string("url") {
                    item.setString(url, forType: .URL)
                    item.setString(url, forType: .string)
                } else {
                    item.setString(invocation.string("text") ?? "", forType: .string)
                }
                switch invocation.string("marker") {
                case "concealed": item.setString("", forType: NSPasteboard.PasteboardType(ShelfPasteboardTypes.concealed))
                case "transient": item.setString("", forType: NSPasteboard.PasteboardType(ShelfPasteboardTypes.transient))
                case "auto-generated": item.setString("", forType: NSPasteboard.PasteboardType(ShelfPasteboardTypes.autoGenerated))
                default: break
                }
                pasteboard.writeObjects([item])
                controller.debugPollNow()
            },
            Command(id: "shelf.debug-add-files", title: "Add Files to Shelf (Debug)", symbol: "doc.badge.plus",
                    arguments: [CommandArgument(name: "paths", title: "Absolute paths, comma separated")],
                    allowedFromURL: true) { invocation in
                let paths = try invocation.require("paths").split(separator: ",").map(String.init)
                guard paths.allSatisfy({ $0.hasPrefix("/") && !$0.contains("/../") }) else {
                    throw CommandError.invalidArgument("paths", "absolute paths only")
                }
                controller.addFiles(paths.map { URL(filePath: $0) })
            },
            Command(id: "shelf.debug-calendar", title: "Shelf Calendar (Debug)", symbol: "calendar",
                    arguments: [
                        CommandArgument(name: "access", title: "Access", allowedValues: ["real"] + ShelfCalendarAccess.allCases.map(\.rawValue)),
                        CommandArgument(name: "events", title: "Events", isRequired: false, allowedValues: ["sample", "none"]),
                    ],
                    allowedFromURL: true) { invocation in
                let access = try invocation.require("access")
                if access == "real" {
                    controller.debug.eventSource = nil
                } else if let value = ShelfCalendarAccess(rawValue: access) {
                    let samples = invocation.string("events") == "none" ? [] : ShelfSampleEventSource.sampleEvents(now: Date())
                    controller.debug.eventSource = ShelfSampleEventSource(access: value, samples: samples)
                }
                controller.refreshEvents()
            },
            Command(id: "shelf.debug-activate-row", title: "Activate Shelf Row (Debug)", symbol: "cursorarrow.click",
                    arguments: [CommandArgument(name: "index", title: "Row index")], allowedFromURL: true) { invocation in
                let raw = try invocation.require("index")
                let clips = controller.visibleClips
                guard let index = Int(raw), clips.indices.contains(index) else { throw CommandError.invalidArgument("index", raw) }
                controller.copy(clips[index].id)
            },
            // Injected data for hints and cards (never a real player, request or paste).
            // Writes shelf-hints.json with the real volume, brightness and battery readings.
            Command(id: "shelf.debug-inject", title: "Inject Shelf Data (Debug)", symbol: "syringe",
                    arguments: [
                        CommandArgument(name: "hint", title: "Hint", isRequired: false,
                                        allowedValues: ["volume", "mute", "brightness", "plugged", "unplugged", "charged", "low", "notice"]),
                        CommandArgument(name: "hints", title: "Hint switches", isRequired: false, allowedValues: ["on", "off", "default"]),
                        CommandArgument(name: "now-playing", title: "Now playing", isRequired: false,
                                        allowedValues: ["playing", "paused", "no-artwork", "no-control", "none", "real"]),
                        CommandArgument(name: "weather", title: "Weather", isRequired: false, allowedValues: ["report", "setup", "off", "real"]),
                        CommandArgument(name: "dump", title: "Dump", isRequired: false, allowedValues: ["1"]),
                    ],
                    allowedFromURL: true) { invocation in
                switch invocation.string("hints") {
                case "on": controller.debug.hints = ShelfHintConfig()
                case "off": controller.debug.hints = ShelfHintConfig(enabled: false)
                case "default": controller.debug.hints = nil
                default: break
                }
                controller.reconcile()
                switch invocation.string("now-playing") {
                case "playing": controller.debug.nowPlaying = ShelfSampleNowPlaying(state: .sample, artwork: debugArtwork(), canControl: true)
                case "paused":
                    var state = NowPlayingState.sample
                    state.isPlaying = false
                    controller.debug.nowPlaying = ShelfSampleNowPlaying(state: state, artwork: debugArtwork(), canControl: true)
                case "no-artwork": controller.debug.nowPlaying = ShelfSampleNowPlaying(state: .sample, artwork: nil, canControl: true)
                case "no-control": controller.debug.nowPlaying = ShelfSampleNowPlaying(state: .sample, artwork: nil, canControl: false)
                case "none": controller.debug.nowPlaying = ShelfSampleNowPlaying(state: nil, artwork: nil, canControl: false)
                case "real": controller.debug.nowPlaying = nil
                default: break
                }
                switch invocation.string("weather") {
                case "report":
                    var report = WeatherReport.sample
                    report.fetchedAt = Date()
                    controller.debug.weather = ShelfSampleWeather(isEnabled: true, report: report)
                case "setup": controller.debug.weather = ShelfSampleWeather(isEnabled: true, report: nil)
                case "off": controller.debug.weather = ShelfSampleWeather(isEnabled: false, report: nil)
                case "real": controller.debug.weather = nil
                default: break
                }
                if let hint = invocation.string("hint") {
                    let posted: ShelfHint = switch hint {
                    case "volume": .volume(ShelfVolumeReading(level: 0.44, isMuted: false))
                    case "mute": .volume(ShelfVolumeReading(level: 0.44, isMuted: true))
                    case "brightness": .brightness(DisplayBrightness.readableDisplays().first.flatMap(DisplayBrightness.brightness(of:)) ?? 0.6)
                    case "plugged": .battery(.pluggedIn(ShelfPowerSources.read()?.percent ?? 80))
                    case "unplugged": .battery(.unplugged(ShelfPowerSources.read()?.percent ?? 80))
                    case "charged": .battery(.charged)
                    case "low": .battery(.low(20))
                    default: .notice(ShelfPasteOutcome.notTrusted.notice ?? "")
                    }
                    controller.hints.post(posted)
                }
                if invocation.string("dump") == "1" {
                    var state = controller.hints.debugState
                    state["hintFrame"] = controller.hints.panelFrame.map { "\($0)" } ?? "none"
                    state["defaultOutputDevice"] = "\(ShelfVolumeWatcher.defaultOutputDevice())"
                    state["volumeNow"] = ShelfVolumeWatcher.read(ShelfVolumeWatcher.defaultOutputDevice()).map { "\($0.level) muted=\($0.isMuted)" } ?? "none"
                    try DebugFiles.writeJSON(state, name: "shelf-hints.json")
                }
            },
            Command(id: "shelf.debug-dump", title: "Dump Shelf State", symbol: "ladybug", allowedFromURL: true) { _ in
                try DebugFiles.writeJSON(ShelfDebugSnapshot.make(controller), name: "shelf.json")
            },
            // Clears every override, wipes the Debug storage folder's shelf files and closes.
            Command(id: "shelf.debug-reset", title: "Reset Shelf (Debug)", symbol: "arrow.counterclockwise", allowedFromURL: true) { _ in
                controller.dismiss(.api)
                controller.debugWipeAndReset()
            },
        ]
    }

    private static func toggle(_ value: String?) -> Bool?? {
        switch value {
        case "on": .some(true)
        case "off": .some(false)
        case "default": .some(nil)
        default: nil
        }
    }

    private static func configure(_ controller: ShelfController, _ invocation: CommandInvocation) throws {
        var debug = controller.debug
        var rebind = false
        var newRoot: URL??
        if let name = invocation.string("pasteboard") {
            guard !name.isEmpty, name != NSPasteboard.Name.general.rawValue, !name.lowercased().contains("general") else {
                throw CommandError.invalidArgument("pasteboard", name)
            }
            debug.pasteboardName = name
            rebind = true
        }
        if let path = invocation.string("storage") {
            guard path.hasPrefix("/"), !path.contains("/../") else { throw CommandError.invalidArgument("storage", path) }
            newRoot = .some(URL(filePath: path, directoryHint: .isDirectory))
        }
        // Switching a storing section on or off here needs a Debug storage folder: turning
        // one off deletes its data, and that must never be the user's.
        let debugStorage = newRoot != nil || controller.usesDebugStorage
        if let value = toggle(invocation.string("clipboard")) {
            if value == true, debug.pasteboardName == nil { throw CommandError.failed("bind a private pasteboard first") }
            if value != nil, !debugStorage { throw CommandError.failed("pass storage=<folder> first") }
            debug.clipboardEnabled = value
        }
        if let value = toggle(invocation.string("files")) {
            if value != nil, !debugStorage { throw CommandError.failed("pass storage=<folder> first") }
            debug.filesEnabled = value
        }
        if let value = toggle(invocation.string("up-next")) { debug.upNextEnabled = value }
        if let value = toggle(invocation.string("hover")) { debug.openOnHover = value }
        if let value = toggle(invocation.string("drag")) { debug.openOnDrag = value }
        if let value = toggle(invocation.string("remove-after-drag")) { debug.removeAfterDrag = value }
        if let raw = invocation.string("hover-delay") {
            guard let value = Double(raw), value > 0 else { throw CommandError.invalidArgument("hover-delay", raw) }
            debug.hoverDelay = value
        }
        if let raw = invocation.string("file-lifetime") {
            guard let value = Double(raw), value >= 0 else { throw CommandError.invalidArgument("file-lifetime", raw) }
            debug.fileLifetime = .some(value > 0 ? value : nil)
        }
        if let raw = invocation.string("poll") {
            guard let value = Double(raw), value >= 0.05 else { throw CommandError.invalidArgument("poll", raw) }
            debug.pollInterval = value
            rebind = true
        }
        if let raw = invocation.string("size") { debug.panelSize = ShelfPanelSize(setting: raw) }
        if let display = invocation.string("display") { debug.display = display == "pointer" ? nil : display }
        if let appearance = invocation.string("appearance") {
            debug.appearance = switch appearance {
            case "light": .aqua
            case "dark": .darkAqua
            default: nil
            }
        }
        controller.debug = debug
        if let newRoot { controller.debugSetStorageRoot(newRoot) }
        if rebind { controller.debugRebindPasteboard() } else { controller.reconcile() }
    }
}

extension ShelfController {
    /// Debug reset: when the store points at a Debug folder, turns the sections off there
    /// (deleting what the session stored in that folder); then drops every override and
    /// returns to the user's folder. The user's own data is never wiped by a Debug command.
    func debugWipeAndReset() {
        let pasteboardName = debug.pasteboardName
        if usesDebugStorage {
            debug.clipboardEnabled = false
            debug.filesEnabled = false
            debug.upNextEnabled = false
            reconcile()
        }
        debug = ShelfDebugOverrides()
        if let pasteboardName { NSPasteboard(name: NSPasteboard.Name(pasteboardName)).releaseGlobally() }
        debugSetStorageRoot(nil)
    }
}

/// `shelf.debug-dump`: what the shelf is doing, without clip content.
struct ShelfDebugSnapshot: Encodable {
    struct Row: Encodable {
        var id: String
        var kind: String
        var pinned: Bool
        var previewLength: Int
        var source: String?
        /// Global top-left points of the row, when drawn.
        var frame: CGRect?
    }

    struct FileRow: Encodable {
        var name: String
        var presence: String
        /// Global top-left points of the tile, when drawn.
        var frame: CGRect?
    }

    struct Pasteboard: Encodable {
        var name: String
        var isGeneral: Bool
        var changeCount: Int
        /// Only for a private Debug pasteboard: its current plain text (test content).
        var privateText: String?
    }

    var visible: Bool
    var trigger: String?
    var section: String
    var lastClose: String?
    /// Global top-left points.
    var frame: CGRect?
    var appKitFrame: CGRect?
    var screen: CGRect?
    var notch: [CGFloat]?
    var hoverZone: CGRect?
    var dragZone: CGRect?
    var enabledSections: [String]
    var plannedActivities: [String]
    var runningActivities: [String]
    var visibleMonitors: Int
    var clips: [Row]
    var lastSkip: String?
    var paused: Bool
    var files: [FileRow]
    var dropCount: Int
    var calendarAccess: String
    var upNext: [String: Int]
    var joinLinks: [String]
    var pasteboard: Pasteboard?
    var generalPasteboardAccessBehavior: Int
    var storageRoot: String
    var storedFiles: [String: String]
    var overridesActive: Bool
    var appearance: String?
    var panelIsKey: Bool
    /// Global top-left points of the search field, when drawn.
    var searchField: CGRect?

    static func make(_ controller: ShelfController) -> ShelfDebugSnapshot {
        let config = controller.config
        let frame = controller.panelFrame
        let screen = frame.flatMap { frame in NSScreen.screens.first { $0.frame.intersects(frame) } }
        let info = screen.map(ShelfController.info)
        var pasteboard: Pasteboard?
        if controller.debug.pasteboardName != nil {
            let bound = controller.debugBoundPasteboard
            pasteboard = Pasteboard(name: bound.name.rawValue, isGeneral: bound.name == .general, changeCount: bound.changeCount,
                                    privateText: bound.name == .general ? nil : bound.string(forType: .string))
        }
        var stored: [String: String] = [:]
        let fileManager = FileManager.default
        let root = controller.storageRoot
        for url in [root, root.appending(path: "clipboard.json"), root.appending(path: "files.json"), root.appending(path: "clipboard-images")] {
            if let attributes = try? fileManager.attributesOfItem(atPath: url.path(percentEncoded: false)),
               let mode = attributes[.posixPermissions] as? Int {
                stored[url.lastPathComponent] = String(mode, radix: 8)
            }
        }
        let input = ShelfActivityInput(clipboardEnabled: config.clipboardEnabled, clipboardPaused: controller.pausedUntil != nil,
                                       filesEnabled: config.filesEnabled, upNextEnabled: config.upNextEnabled,
                                       openOnHover: config.openOnHover, openOnDrag: config.openOnDrag,
                                       fileLifetime: config.fileLifetime, hasFiles: !controller.files.items.isEmpty)
        let upNext = controller.upNext
        // Window-relative (top-left origin) → global top-left points.
        func global(_ rect: CGRect?) -> CGRect? {
            guard let rect, let frame else { return nil }
            let topLeft = ScreenGeometry.topLeftRect(fromAppKit: frame)
            return CGRect(x: topLeft.minX + rect.minX, y: topLeft.minY + rect.minY, width: rect.width, height: rect.height)
        }
        return ShelfDebugSnapshot(
            visible: controller.isVisible, trigger: controller.trigger?.rawValue, section: controller.section.rawValue,
            lastClose: controller.lastClose?.rawValue,
            frame: frame.map(ScreenGeometry.topLeftRect(fromAppKit:)), appKitFrame: frame, screen: screen?.frame,
            notch: info?.notch.map { [$0.lowerBound, $0.upperBound] },
            hoverZone: info.map { ScreenGeometry.topLeftRect(fromAppKit: ShelfGeometry.hoverZone($0)) },
            dragZone: info.map { ScreenGeometry.topLeftRect(fromAppKit: ShelfGeometry.dragZone($0)) },
            enabledSections: config.enabledSections.map(\.rawValue),
            plannedActivities: ShelfActivityPlan.activities(input).sorted().map(\.rawValue),
            runningActivities: controller.runningActivities.map(\.rawValue),
            visibleMonitors: controller.visibleMonitorCount,
            clips: controller.visibleClips.map { Row(id: $0.id.uuidString, kind: $0.kind.rawValue, pinned: $0.isPinned,
                                                     previewLength: $0.preview.count, source: $0.sourceBundleID,
                                                     frame: global(controller.debugRowFrames[$0.id])) },
            lastSkip: controller.lastSkip?.rawValue, paused: controller.pausedUntil != nil,
            files: controller.files.items.map { FileRow(name: $0.name, presence: (controller.filePresence[$0.id] ?? .present).rawValue,
                                                        frame: global(controller.debugTileFrames[$0.id])) },
            dropCount: controller.dropCount,
            calendarAccess: controller.currentCalendarAccess.rawValue,
            upNext: ["allDayToday": upNext.allDayToday.count, "allDayTomorrow": upNext.allDayTomorrow.count, "timed": upNext.timed.count],
            joinLinks: upNext.timed.compactMap { $0.meetingLink?.service.rawValue },
            pasteboard: pasteboard, generalPasteboardAccessBehavior: controller.generalAccessBehavior.rawValue,
            storageRoot: root.path(percentEncoded: false), storedFiles: stored, overridesActive: !controller.debug.isEmpty,
            appearance: controller.debug.appearance?.rawValue,
            panelIsKey: controller.debugPanelIsKey, searchField: global(controller.searchFieldFrame))
    }
}
#endif
