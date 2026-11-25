import Foundation

/// The latest readings of every source, as the sampler hub publishes them.
nonisolated struct CustomItemsReadings: Equatable, Sendable {
    var cpu: CustomItemsCPUUsage?
    /// 0…1, oldest first.
    var cpuHistory: [Double] = []
    var memory: CustomItemsMemoryFigures?
    var network: CustomItemsNetworkRates?
    /// Bytes per second (down + up), oldest first.
    var networkHistory: [Double] = []
    var battery: CustomItemsBatteryState?
    /// nil until the first battery read; false on Macs without a battery.
    var batteryPresent: Bool?
    var disk: CustomItemsDiskFigures?
    var now = Date()
    /// Last result per script widget id.
    var scripts: [String: CustomItemsScriptResult] = [:]
    /// 0…1, the busiest accelerator.
    var gpu: Double?
    /// nil until the first GPU read; false when this Mac does not report GPU usage.
    var gpuReported: Bool?
    /// What the service-fed widgets show.
    var ambient = CustomItemsAmbient()
}

/// What one widget draws: an optional symbol, an optional text and an optional history.
nonisolated struct CustomItemsWidgetContent: Equatable, Sendable {
    var symbol: String?
    var text: String?
    /// 0…1 values for the sparkline, oldest first.
    var history: [Double]?
    /// Strings at least as wide as any text this widget shows (automatic width).
    var widthSamples: [String]
    /// VoiceOver label.
    var accessibilityText: String

    /// Placeholder until the first reading.
    static let placeholder = "–"
}

nonisolated enum CustomItemsWidgetText {
    /// The value part of the text (no label prefix), or nil before the first reading.
    static func value(for widget: CustomItemWidget, readings: CustomItemsReadings) -> String? {
        switch widget.source {
        case .cpu:
            return readings.cpu.map { CustomItemsFormat.percent($0.total) }
        case .memory:
            guard let memory = readings.memory else { return nil }
            switch widget.memoryFigure {
            case .used: return CustomItemsFormat.memory(memory.used)
            case .pressure: return memory.pressurePercent.map { CustomItemsFormat.percent($0 / 100) } ?? CustomItemsText.title(of: memory.pressure)
            }
        case .network:
            guard let network = readings.network else { return nil }
            let down = "↓" + CustomItemsFormat.byteRate(network.down)
            let up = "↑" + CustomItemsFormat.byteRate(network.up)
            switch widget.networkDirection {
            case .both: return "\(down) \(up)"
            case .down: return down
            case .up: return up
            }
        case .battery:
            guard let battery = readings.battery else { return nil }
            if widget.batteryFigure == .timeRemaining, let minutes = battery.minutesRemaining {
                return CustomItemsFormat.duration(minutes: minutes)
            }
            return CustomItemsFormat.percent(Double(battery.percent) / 100)
        case .disk:
            return readings.disk.map { CustomItemsFormat.bytes($0.available) }
        case .clock:
            return CustomItemsClock.text(for: readings.now, format: widget.clockFormat,
                                         timeZone: widget.timeZone.flatMap(TimeZone.init(identifier:)))
        case .label:
            return widget.label
        case .script:
            return readings.scripts[widget.id]?.line
        case .gpu:
            return readings.gpu.map { CustomItemsFormat.percent($0) }
        case .music:
            return readings.ambient.nowPlaying.map { CustomItemsAmbientText.music($0) }
        case .calendar:
            let ambient = readings.ambient
            return CustomItemsAmbientText.event(ambient.nextEvent, authorized: ambient.calendarAuthorized, now: ambient.checkedAt)
                .map { CustomItemsAmbientText.calendar($0) }
        case .focus:
            return CustomItemsAmbientText.focus(isFocused: readings.ambient.isFocused, label: readings.ambient.focusLabel)
        case .weather:
            guard readings.ambient.weatherEnabled, let report = readings.ambient.weather else { return nil }
            return CustomItemsAmbientText.temperature(report.temperature)
        }
    }

    /// The widget leaves the bar: nothing playing, no event soon (or no Calendars access),
    /// weather off or not fetched yet.
    static func isEmpty(_ widget: CustomItemWidget, readings: CustomItemsReadings) -> Bool {
        widget.source.hidesWhenEmpty && value(for: widget, readings: readings) == nil
    }

    /// The source's own symbol while the widget keeps the default one.
    static func dynamicSymbol(for widget: CustomItemWidget, readings: CustomItemsReadings) -> String? {
        guard widget.symbol == widget.source.defaultSymbol else { return nil }
        switch widget.source {
        case .battery: return readings.battery.map(CustomItemsBatteryMath.symbol(for:))
        case .music: return readings.ambient.nowPlaying.map { $0.isPlaying ? "play.fill" : "pause.fill" }
        case .focus: return readings.ambient.isFocused == true ? "moon.fill" : nil
        case .weather: return readings.ambient.weatherEnabled ? readings.ambient.weather?.symbolName : nil
        default: return nil
        }
    }

    /// Labels show their text alone; other sources put a non-empty label before the value
    /// ("NYC 09:41").
    static func prefix(for widget: CustomItemWidget) -> String? {
        guard widget.source != .label else { return nil }
        let trimmed = widget.label.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func content(for widget: CustomItemWidget, readings: CustomItemsReadings) -> CustomItemsWidgetContent {
        let value = value(for: widget, readings: readings)
        let prefix = prefix(for: widget)
        func joined(_ text: String) -> String { prefix.map { "\($0) \(text)" } ?? text }

        var symbol: String? = widget.showsSymbol ? widget.symbol : nil
        if symbol != nil, let dynamic = dynamicSymbol(for: widget, readings: readings) { symbol = dynamic }
        // Focus has a quiet state (symbol only), never a word for "off" or "unknown".
        let quiet = widget.source == .focus && value == nil
        let text: String? = widget.showsText && !quiet ? joined(value ?? CustomItemsWidgetContent.placeholder) : nil
        var samples = widget.showsText ? CustomItemsFormat.widestSamples(for: widget.source, widget: widget).map(joined) : []
        if let text { samples.append(text) }

        var history: [Double]?
        if widget.drawsHistory {
            switch widget.source {
            case .cpu: history = readings.cpuHistory
            case .network: history = CustomItemsHistory.normalised(readings.networkHistory)
            default: break
            }
        }
        var spoken = [prefix ?? "", value ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        if widget.source == .music, let state = readings.ambient.nowPlaying {
            let status = state.isPlaying ? String(localized: "Playing", table: "CustomItems") : String(localized: "Paused", table: "CustomItems")
            spoken = "\(status): \(spoken)"
        }
        return CustomItemsWidgetContent(symbol: symbol, text: text, history: history, widthSamples: samples,
                                        accessibilityText: spoken)
    }
}

// MARK: - Demand

/// Which shared sources must sample, and how often.
nonisolated enum CustomItemsDemand {
    /// The shortest interval any active widget asks for, per shared source.
    static func sources(for widgets: [CustomItemWidget]) -> [CustomItemWidgetSource: Double] {
        var demand: [CustomItemWidgetSource: Double] = [:]
        for widget in widgets where widget.source.isShared {
            let interval = widget.effectiveInterval
            demand[widget.source] = min(demand[widget.source] ?? .infinity, interval)
        }
        return demand
    }

    /// Merges several clients' demands (the bar, an open settings pane).
    static func merge(_ demands: [[CustomItemWidgetSource: Double]]) -> [CustomItemWidgetSource: Double] {
        demands.reduce(into: [:]) { result, demand in
            for (source, interval) in demand { result[source] = min(result[source] ?? .infinity, interval) }
        }
    }
}
