import Foundation

/// User-facing names and detail lines (table "CustomItems").
enum CustomItemsText {
    static func title(of source: CustomItemWidgetSource) -> String {
        switch source {
        case .cpu: String(localized: "CPU", table: "CustomItems")
        case .memory: String(localized: "Memory", table: "CustomItems")
        case .network: String(localized: "Network", table: "CustomItems")
        case .battery: String(localized: "Battery", table: "CustomItems")
        case .disk: String(localized: "Disk", table: "CustomItems")
        case .clock: String(localized: "Date and time", table: "CustomItems")
        case .label: String(localized: "Label", table: "CustomItems")
        case .script: String(localized: "Script", table: "CustomItems")
        case .gpu: String(localized: "GPU", table: "CustomItems")
        case .music: String(localized: "Music", table: "CustomItems")
        case .calendar: String(localized: "Next calendar event", table: "CustomItems")
        case .focus: String(localized: "Focus", table: "CustomItems")
        case .weather: String(localized: "Weather", table: "CustomItems")
        }
    }

    /// The click choice's name; the default click of music and weather widgets does that
    /// source's own thing (`CustomItemsAmbientClick`).
    static func title(of kind: CustomItemWidgetActionKind, source: CustomItemWidgetSource) -> String {
        switch (kind, source) {
        case (.menu, .music): String(localized: "Play or pause", table: "CustomItems")
        case (.menu, .weather): String(localized: "Open Weather settings", table: "CustomItems")
        default: title(of: kind)
        }
    }

    static func title(of style: CustomItemWidgetStyle) -> String {
        switch style {
        case .symbolAndText: String(localized: "Symbol and text", table: "CustomItems")
        case .textOnly: String(localized: "Text only", table: "CustomItems")
        case .symbolOnly: String(localized: "Symbol only", table: "CustomItems")
        }
    }

    static func title(of kind: CustomItemWidgetActionKind) -> String {
        switch kind {
        case .none: String(localized: "Nothing", table: "CustomItems")
        case .open: String(localized: "Open an app, file or URL", table: "CustomItems")
        case .command: String(localized: "Run a Rolltop command", table: "CustomItems")
        case .menu: String(localized: "Show details", table: "CustomItems")
        }
    }

    static func title(of kind: CustomItemGlyphKind) -> String {
        switch kind {
        case .none: String(localized: "Blank", table: "CustomItems")
        case .text: String(localized: "Text", table: "CustomItems")
        case .emoji: String(localized: "Emoji", table: "CustomItems")
        case .symbol: String(localized: "Symbol", table: "CustomItems")
        }
    }

    static func title(of figure: CustomItemMemoryFigure) -> String {
        switch figure {
        case .used: String(localized: "Memory used", table: "CustomItems")
        case .pressure: String(localized: "Memory pressure", table: "CustomItems")
        }
    }

    static func title(of direction: CustomItemNetworkDirection) -> String {
        switch direction {
        case .both: String(localized: "Download and upload", table: "CustomItems")
        case .down: String(localized: "Download", table: "CustomItems")
        case .up: String(localized: "Upload", table: "CustomItems")
        }
    }

    static func title(of figure: CustomItemBatteryFigure) -> String {
        switch figure {
        case .percent: String(localized: "Charge", table: "CustomItems")
        case .timeRemaining: String(localized: "Time remaining", table: "CustomItems")
        }
    }

    nonisolated static func title(of pressure: CustomItemsMemoryFigures.Pressure) -> String {
        switch pressure {
        case .normal: String(localized: "Normal", table: "CustomItems")
        case .warning: String(localized: "Elevated", table: "CustomItems")
        case .critical: String(localized: "Critical", table: "CustomItems")
        }
    }

    /// A one-line description of a widget for lists ("CPU · every 2 s").
    static func summary(of widget: CustomItemWidget) -> String {
        switch widget.source {
        case .clock:
            let zone = widget.timeZone.flatMap(TimeZone.init(identifier:))
            let zoneName = zone.map { $0.localizedName(for: .generic, locale: .autoupdatingCurrent) ?? $0.identifier }
            return zoneName.map { "\(widget.clockFormat) · \($0)" } ?? widget.clockFormat
        case .label: return widget.label
        case .script: return widget.scriptCommand
        default:
            let seconds = Int(widget.effectiveInterval)
            return String(localized: "Every \(seconds) s", table: "CustomItems")
        }
    }

    /// Lines of a widget's details menu.
    static func details(for widget: CustomItemWidget, readings: CustomItemsReadings) -> [String] {
        switch widget.source {
        case .cpu:
            guard let cpu = readings.cpu else { return [waiting] }
            return [String(localized: "CPU: \(CustomItemsFormat.percent(cpu.total))", table: "CustomItems"),
                    String(localized: "User: \(CustomItemsFormat.percent(cpu.user))", table: "CustomItems"),
                    String(localized: "System: \(CustomItemsFormat.percent(cpu.system))", table: "CustomItems")]
        case .memory:
            guard let memory = readings.memory else { return [waiting] }
            var lines = [String(localized: "Used: \(CustomItemsFormat.memory(memory.used)) of \(CustomItemsFormat.memory(memory.total))", table: "CustomItems"),
                         String(localized: "App memory: \(CustomItemsFormat.memory(memory.app))", table: "CustomItems"),
                         String(localized: "Wired: \(CustomItemsFormat.memory(memory.wired))", table: "CustomItems"),
                         String(localized: "Compressed: \(CustomItemsFormat.memory(memory.compressed))", table: "CustomItems"),
                         String(localized: "Cached files: \(CustomItemsFormat.memory(memory.cached))", table: "CustomItems")]
            lines.append(String(localized: "Pressure: \(title(of: memory.pressure))", table: "CustomItems"))
            return lines
        case .network:
            guard let network = readings.network else { return [waiting] }
            var lines = [String(localized: "Total: ↓\(CustomItemsFormat.byteRate(network.down)) ↑\(CustomItemsFormat.byteRate(network.up))", table: "CustomItems")]
            for interface in network.interfaces {
                lines.append("\(interface.name): ↓\(CustomItemsFormat.byteRate(interface.down)) ↑\(CustomItemsFormat.byteRate(interface.up))")
            }
            return lines
        case .battery:
            guard let battery = readings.battery else { return [waiting] }
            var lines = [CustomItemsFormat.percent(Double(battery.percent) / 100)]
            if battery.isCharging {
                lines.append(String(localized: "Charging", table: "CustomItems"))
            } else if battery.isOnAC {
                lines.append(battery.isCharged ? String(localized: "Charged", table: "CustomItems")
                    : String(localized: "On power adapter, not charging", table: "CustomItems"))
            } else {
                lines.append(String(localized: "On battery", table: "CustomItems"))
            }
            if let minutes = battery.minutesRemaining {
                let time = CustomItemsFormat.duration(minutes: minutes)
                lines.append(battery.isCharging ? String(localized: "\(time) until full", table: "CustomItems")
                    : String(localized: "\(time) remaining", table: "CustomItems"))
            }
            return lines
        case .disk:
            guard let disk = readings.disk else { return [waiting] }
            var lines = [String(localized: "Available: \(CustomItemsFormat.bytes(disk.available)) of \(CustomItemsFormat.bytes(disk.total))", table: "CustomItems")]
            if let important = disk.availableForImportantUsage, important > disk.available {
                lines.append(String(localized: "Including purgeable space: \(CustomItemsFormat.bytes(important))", table: "CustomItems"))
            }
            return lines
        case .clock:
            let zone = widget.timeZone.flatMap(TimeZone.init(identifier:)) ?? .autoupdatingCurrent
            let date = readings.now.formatted(Date.FormatStyle(date: .complete, time: .shortened, timeZone: zone))
            return [date, zone.localizedName(for: .generic, locale: .autoupdatingCurrent) ?? zone.identifier]
        case .label:
            return []
        case .gpu:
            if readings.gpuReported == false { return [String(localized: "This Mac does not report GPU usage.", table: "CustomItems")] }
            guard let gpu = readings.gpu else { return [waiting] }
            return [String(localized: "GPU: \(CustomItemsFormat.percent(gpu))", table: "CustomItems")]
        case .music:
            guard let state = readings.ambient.nowPlaying else { return [String(localized: "Nothing is playing", table: "CustomItems")] }
            return [state.title, state.artist, state.player.displayName].compactMap { $0 }
        case .calendar:
            let ambient = readings.ambient
            guard let event = CustomItemsAmbientText.event(ambient.nextEvent, authorized: ambient.calendarAuthorized, now: ambient.checkedAt) else {
                return [String(localized: "No event in the next 24 hours", table: "CustomItems")]
            }
            let time = event.start.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened))
            return [event.title, time, event.location].compactMap { $0 }
        case .focus:
            return [CustomItemsAmbientText.focus(isFocused: readings.ambient.isFocused, label: readings.ambient.focusLabel)
                    ?? String(localized: "No Focus known to be on", table: "CustomItems")]
        case .weather:
            guard readings.ambient.weatherEnabled, let report = readings.ambient.weather else {
                return [String(localized: "Weather is off", table: "CustomItems")]
            }
            return ["\(report.placeName): \(CustomItemsAmbientText.temperature(report.temperature))", report.condition.localizedName,
                    WeatherAttribution.openMeteo.text]
        case .script:
            guard let result = readings.scripts[widget.id] else { return [String(localized: "Not run yet", table: "CustomItems")] }
            let status: String = switch result.status {
            case .ok: String(localized: "Last run succeeded", table: "CustomItems")
            case .failed: String(localized: "Last run failed (exit \(Int(result.exitCode ?? -1)))", table: "CustomItems")
            case .timedOut: String(localized: "Last run timed out", table: "CustomItems")
            case .launchFailed: String(localized: "The script could not start", table: "CustomItems")
            }
            return [status]
        }
    }

    private static var waiting: String { String(localized: "Measuring…", table: "CustomItems") }
}
