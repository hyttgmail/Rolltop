import Foundation

// Pure sampling arithmetic and formatting for widgets. No system calls: readers feed raw
// counters in, tests feed injected samples.

// MARK: - Counters

nonisolated enum CustomItemsCounter {
    /// The increase of a monotonic counter `bits` wide from `previous` to `current`.
    /// A smaller `current` is a wrap when the counter is narrower than 64 bits and the drop
    /// is more than half its range; otherwise it was reset (interface down/up, sleep) and
    /// the interval has no delta: nil.
    static func delta(from previous: UInt64, to current: UInt64, bits: Int = 64) -> UInt64? {
        if current >= previous { return current - previous }
        guard bits < 64 else { return nil }
        let range = UInt64(1) << UInt64(bits)
        guard previous < range, previous - current > range / 2 else { return nil }
        return range - previous + current
    }
}

// MARK: - CPU

/// Aggregate CPU ticks (`host_statistics(HOST_CPU_LOAD_INFO)`: 32-bit counters).
nonisolated struct CustomItemsCPUTicks: Equatable, Sendable {
    var user: UInt64
    var system: UInt64
    var idle: UInt64
    var nice: UInt64

    static let counterBits = 32
}

nonisolated struct CustomItemsCPUUsage: Equatable, Sendable {
    /// 0…1
    var total: Double
    var user: Double
    var system: Double
}

nonisolated enum CustomItemsCPUMath {
    /// Usage between two tick samples; nil when no tick elapsed or a counter was reset.
    static func usage(from previous: CustomItemsCPUTicks, to current: CustomItemsCPUTicks) -> CustomItemsCPUUsage? {
        let bits = CustomItemsCPUTicks.counterBits
        guard let user = CustomItemsCounter.delta(from: previous.user, to: current.user, bits: bits),
              let system = CustomItemsCounter.delta(from: previous.system, to: current.system, bits: bits),
              let idle = CustomItemsCounter.delta(from: previous.idle, to: current.idle, bits: bits),
              let nice = CustomItemsCounter.delta(from: previous.nice, to: current.nice, bits: bits) else { return nil }
        let total = user + system + idle + nice
        guard total > 0 else { return nil }
        let busy = Double(user + system + nice) / Double(total)
        return CustomItemsCPUUsage(total: min(max(busy, 0), 1), user: Double(user + nice) / Double(total),
                                   system: Double(system) / Double(total))
    }
}

// MARK: - Network

nonisolated struct CustomItemsInterfaceCounters: Equatable, Sendable {
    var name: String
    var received: UInt64
    var sent: UInt64
}

nonisolated struct CustomItemsNetworkRates: Equatable, Sendable {
    struct Interface: Equatable, Sendable {
        var name: String
        var down: Double
        var up: Double
    }

    /// Bytes per second over the counted interfaces.
    var down: Double
    var up: Double
    var interfaces: [Interface]
}

nonisolated enum CustomItemsNetworkMath {
    /// Counts physical links only: Ethernet/Wi-Fi (`en*`) and cellular (`pdp_ip*`). Tunnels
    /// (`utun`, `ipsec`), AWDL, bridges and loopback would count the same bytes twice.
    static func isCounted(interface name: String) -> Bool {
        name.hasPrefix("en") || name.hasPrefix("pdp_ip")
    }

    /// Rates between two samples `elapsed` seconds apart. Interfaces missing from either
    /// sample, or whose counter was reset, contribute nothing for this interval.
    static func rates(from previous: [CustomItemsInterfaceCounters], to current: [CustomItemsInterfaceCounters],
                      elapsed: TimeInterval, counterBits: Int = 64) -> CustomItemsNetworkRates? {
        guard elapsed > 0.05 else { return nil }
        let before = Dictionary(previous.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var interfaces: [CustomItemsNetworkRates.Interface] = []
        var down = 0.0
        var up = 0.0
        for now in current where isCounted(interface: now.name) {
            guard let then = before[now.name] else { continue }
            let received = CustomItemsCounter.delta(from: then.received, to: now.received, bits: counterBits) ?? 0
            let sent = CustomItemsCounter.delta(from: then.sent, to: now.sent, bits: counterBits) ?? 0
            let rate = CustomItemsNetworkRates.Interface(name: now.name, down: Double(received) / elapsed, up: Double(sent) / elapsed)
            interfaces.append(rate)
            down += rate.down
            up += rate.up
        }
        return CustomItemsNetworkRates(down: down, up: up, interfaces: interfaces.sorted { $0.name < $1.name })
    }
}

// MARK: - Memory

/// Page counts from `host_statistics64(HOST_VM_INFO64)` plus the page size and RAM size.
nonisolated struct CustomItemsVMCounts: Equatable, Sendable {
    var pageSize: UInt64
    var physicalMemory: UInt64
    var free: UInt64
    var active: UInt64
    var inactive: UInt64
    var speculative: UInt64
    var wired: UInt64
    /// Pages occupied by the compressor (`compressor_page_count`).
    var compressed: UInt64
    var purgeable: UInt64
    /// File-backed pages (`external_page_count`).
    var external: UInt64
    /// Anonymous pages (`internal_page_count`).
    var `internal`: UInt64
}

nonisolated struct CustomItemsMemoryFigures: Equatable, Sendable {
    enum Pressure: String, Sendable { case normal, warning, critical }

    var total: UInt64
    /// App memory + wired + compressed, as Activity Monitor's "Memory Used".
    var used: UInt64
    var app: UInt64
    var wired: UInt64
    var compressed: UInt64
    /// File-backed and purgeable memory macOS frees on demand.
    var cached: UInt64
    var pressure: Pressure
    /// 0…100: the share of memory not available without paging (100 − free level).
    var pressurePercent: Double?
}

nonisolated enum CustomItemsMemoryMath {
    static func figures(_ counts: CustomItemsVMCounts, pressureLevel: Int?, freeLevelPercent: Int?) -> CustomItemsMemoryFigures {
        let page = counts.pageSize
        let appPages = counts.internal > counts.purgeable ? counts.internal - counts.purgeable : 0
        let app = appPages * page
        let wired = counts.wired * page
        let compressed = counts.compressed * page
        let cached = (counts.external + counts.purgeable) * page
        let pressure: CustomItemsMemoryFigures.Pressure = switch pressureLevel {
        case 4?: .critical
        case 2?: .warning
        default: .normal
        }
        let percent = freeLevelPercent.map { Double(min(max(100 - $0, 0), 100)) }
        return CustomItemsMemoryFigures(total: counts.physicalMemory, used: min(app + wired + compressed, max(counts.physicalMemory, 1)),
                                        app: app, wired: wired, compressed: compressed, cached: cached,
                                        pressure: pressure, pressurePercent: percent)
    }
}

// MARK: - Battery

nonisolated struct CustomItemsBatteryState: Equatable, Sendable {
    /// 0…100
    var percent: Int
    var isCharging: Bool
    var isOnAC: Bool
    var isCharged: Bool
    /// Minutes to empty (on battery) or to full (charging); nil while macOS is estimating.
    var minutesRemaining: Int?
}

nonisolated enum CustomItemsBatteryMath {
    /// From an IOPowerSources description: capacity keys may be absolute (mAh) on some
    /// models, so the percentage is current / max.
    static func state(current: Int, max maximum: Int, isCharging: Bool, isOnAC: Bool, isCharged: Bool,
                      timeToEmpty: Int?, timeToFull: Int?) -> CustomItemsBatteryState {
        let percent = maximum > 0 ? Int((Double(current) / Double(maximum) * 100).rounded()) : current
        let raw = isCharging ? timeToFull : (isOnAC ? nil : timeToEmpty)
        let minutes = raw.flatMap { $0 >= 0 && $0 < 60 * 48 ? $0 : nil }
        return CustomItemsBatteryState(percent: min(max(percent, 0), 100), isCharging: isCharging, isOnAC: isOnAC,
                                       isCharged: isCharged, minutesRemaining: minutes)
    }

    /// An SF Symbol for the level, with the bolt while charging.
    static func symbol(for state: CustomItemsBatteryState) -> String {
        if state.isCharging { return "battery.100percent.bolt" }
        return switch state.percent {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }
}

// MARK: - Disk

nonisolated struct CustomItemsDiskFigures: Equatable, Sendable {
    var total: Int64
    /// What `df` calls available.
    var available: Int64
    /// Available including purgeable space macOS would free for important use.
    var availableForImportantUsage: Int64?
}

// MARK: - Clock

nonisolated enum CustomItemsClock {
    /// Whether a `DateFormatter` pattern shows seconds (an `s` outside quoted literals).
    static func showsSeconds(format: String) -> Bool {
        var quoted = false
        for character in format {
            if character == "'" { quoted.toggle(); continue }
            if !quoted, character == "s" { return true }
        }
        return false
    }

    /// The next instant the text can change: the next whole second or minute.
    static func nextTick(after date: Date, showsSeconds: Bool) -> Date {
        let step: TimeInterval = showsSeconds ? 1 : 60
        let t = date.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (floor(t / step) + 1) * step)
    }

    static func text(for date: Date, format: String, timeZone: TimeZone?, locale: Locale = .autoupdatingCurrent) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone ?? .autoupdatingCurrent
        formatter.dateFormat = format.isEmpty ? CustomItemWidget.defaultClockFormat : format
        return formatter.string(from: date)
    }

    /// Dates whose formatted text is the widest a pattern produces in practice: every
    /// month, every weekday, AM and PM, two-digit fields. The renderer measures them all.
    static func widthSamples(format: String, timeZone: TimeZone?, locale: Locale = .autoupdatingCurrent) -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone ?? .autoupdatingCurrent
        // Every month on day 28 plus seven consecutive days (every weekday), each at 23:58:58
        // and 10:58:58 (two-digit hours in 24 h and 12 h patterns, AM and PM).
        let days = (1...12).map { (month: $0, day: 28) } + (3...9).map { (month: 1, day: $0) }
        var samples: [String] = []
        for (month, day) in days {
            for hour in [23, 10] {
                let components = DateComponents(year: 2028, month: month, day: day, hour: hour, minute: 58, second: 58)
                if let date = calendar.date(from: components) {
                    samples.append(text(for: date, format: format, timeZone: timeZone, locale: locale))
                }
            }
        }
        return samples
    }
}

// MARK: - Formatting

nonisolated enum CustomItemsFormat {
    /// "7%", "42%", "100%".
    static func percent(_ fraction: Double) -> String {
        let value = Int((min(max(fraction.isFinite ? fraction : 0, 0), 1) * 100).rounded())
        return (Double(value) / 100).formatted(.percent)
    }

    /// Decimal (1000-based) units like Finder and Activity Monitor, at most three digits:
    /// "0 KB/s", "4.2 KB/s", "42 KB/s", "420 KB/s", "1.2 MB/s". Below 1000 B/s it shows KB
    /// with one decimal so the unit, and therefore the width, changes less often.
    static func byteRate(_ bytesPerSecond: Double) -> String {
        let value = max(bytesPerSecond.isFinite ? bytesPerSecond : 0, 0)
        return scaled(value, units: ["KB/s", "MB/s", "GB/s", "TB/s"], startingAt: 1000)
    }

    /// "512 MB", "12 GB", "1.5 TB".
    static func bytes(_ count: Int64) -> String {
        let value = Double(max(count, 0))
        if value < 1_000_000 { return scaled(value, units: ["KB", "MB", "GB", "TB", "PB"], startingAt: 1000) }
        return scaled(value, units: ["MB", "GB", "TB", "PB"], startingAt: 1_000_000)
    }

    /// Value in `units[0]` = value / base, stepping up by 1000; one decimal below 10.
    private static func scaled(_ value: Double, units: [String], startingAt base: Double) -> String {
        var scaled = value / base
        var unit = 0
        // Round first so 999.6 KB becomes 1.0 MB, not "1000 KB".
        while unit < units.count - 1, rounded(scaled) >= 1000 {
            scaled /= 1000
            unit += 1
        }
        return "\(number(scaled)) \(units[unit])"
    }

    private static func rounded(_ value: Double) -> Double {
        value < 9.95 ? (value * 10).rounded() / 10 : value.rounded()
    }

    private static func number(_ value: Double) -> String {
        if value == 0 { return "0" }
        if value < 9.95 { return value.formatted(.number.precision(.fractionLength(1)).grouping(.never)) }
        return Int(value.rounded()).formatted(.number.grouping(.never))
    }

    /// Memory in binary units with Activity Monitor's labels: "18 GB" is 18 GiB, so a
    /// 36 GiB Mac reads "36 GB", not "39 GB". One decimal below 10.
    static func memory(_ bytes: UInt64) -> String {
        let gib = Double(bytes) / 1_073_741_824
        if gib >= 1 { return "\(number(gib)) GB" }
        return "\(number(Double(bytes) / 1_048_576)) MB"
    }

    /// "3:07" (hours:minutes), "0:45".
    static func duration(minutes: Int) -> String {
        let minutes = max(minutes, 0)
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }

    /// Strings at least as wide as any value a source shows (with monospaced digits): the
    /// automatic width reserves room for the widest so the bar never jitters.
    static func widestSamples(for source: CustomItemWidgetSource, widget: CustomItemWidget) -> [String] {
        switch source {
        case .cpu: return ["100%"]
        case .network:
            let rate = ["8.8 MB/s", "888 KB/s", "888 MB/s", "888 GB/s"]
            switch widget.networkDirection {
            case .both: return rate.map { "↓\($0) ↑\($0)" }
            case .down: return rate.map { "↓\($0)" }
            case .up: return rate.map { "↑\($0)" }
            }
        case .memory:
            return widget.memoryFigure == .used ? ["888 GB", "8.8 GB", "888 MB", "8.8 MB"] : ["100%"]
        case .battery:
            return widget.batteryFigure == .percent ? ["100%"] : ["88:88", "100%"]
        case .disk: return ["888 GB", "8.8 TB", "888 MB"]
        case .clock:
            return CustomItemsClock.widthSamples(format: widget.clockFormat, timeZone: widget.timeZone.flatMap(TimeZone.init(identifier:)))
        case .label: return [widget.label]
        case .gpu: return ["100%"]
        case .weather: return ["-88°", "188°"]
        // Texts of any width: the shown text sets the width (music is capped).
        case .script, .music, .calendar, .focus: return []
        }
    }
}

// MARK: - History

/// A fixed-size history of 0…1 values, oldest first.
nonisolated struct CustomItemsHistory: Equatable, Sendable {
    let capacity: Int
    private(set) var values: [Double] = []

    init(capacity: Int = 24) { self.capacity = max(capacity, 1) }

    mutating func append(_ value: Double) {
        values.append(min(max(value.isFinite ? value : 0, 0), 1))
        if values.count > capacity { values.removeFirst(values.count - capacity) }
    }

    mutating func removeAll() { values.removeAll() }

    /// Network rates normalised to the largest in the window (at least `floor` bytes/s, so
    /// an idle link draws a flat line instead of noise).
    static func normalised(_ rates: [Double], floor: Double = 50_000) -> [Double] {
        let top = max(rates.max() ?? 0, floor)
        return rates.map { min(max($0 / top, 0), 1) }
    }
}
