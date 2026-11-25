import AppKit
import Observation

/// One shared sampler per source, however many widgets use it. A source samples only
/// while some client (the bar, an open settings pane) asks for it, at the shortest
/// interval asked for, and nothing samples while the displays sleep. Scripts run per
/// widget, one run at a time.
@Observable
final class CustomItemsSamplerHub {
    struct ScriptJob: Equatable {
        var command: String
        var interval: Double
        var timeout: Double
    }

    private(set) var readings = CustomItemsReadings()
    /// Bumps on every published sample (SwiftUI previews read it).
    private(set) var revision = 0

    /// Called after a source (or a script widget, with its id) published a new reading.
    @ObservationIgnored var onUpdate: ((CustomItemWidgetSource, String?) -> Void)?
    /// Reads the services behind music, calendar, Focus and weather widgets (set by the
    /// feature; resolves the services on every call, so a provider registered later counts).
    @ObservationIgnored var ambientReader: (() -> CustomItemsAmbient)?

    @ObservationIgnored private var demands: [String: [CustomItemWidgetSource: Double]] = [:]
    @ObservationIgnored private var scriptJobs: [String: ScriptJob] = [:]
    @ObservationIgnored private var timers: [CustomItemWidgetSource: Timer] = [:]
    @ObservationIgnored private var intervals: [CustomItemWidgetSource: Double] = [:]
    @ObservationIgnored private var scriptTimers: [String: Timer] = [:]
    @ObservationIgnored private var scriptsRunning: Set<String> = []
    @ObservationIgnored private var inFlight: Set<CustomItemWidgetSource> = []
    @ObservationIgnored private var cpuBaseline: CustomItemsCPUTicks?
    @ObservationIgnored private var cpuHistory = CustomItemsHistory()
    @ObservationIgnored private var networkBaseline: (counters: [CustomItemsInterfaceCounters], at: Date)?
    @ObservationIgnored private var networkHistory: [Double] = []
    @ObservationIgnored private(set) var isAsleep = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private(set) var sampleCounts: [String: Int] = [:]
    @ObservationIgnored private(set) var scriptRunCount = 0
    private let log = Log.logger("custom-items")

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        for (name, asleep) in [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.willSleepNotification, true),
                               (NSWorkspace.screensDidWakeNotification, false), (NSWorkspace.didWakeNotification, false)] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setAsleep(asleep) }
            })
        }
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.timers[.clock] != nil else { return }
                    self.sample(.clock)
                    self.scheduleClock()
                }
            })
        }
    }

    func stop() {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0); NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        demands.removeAll()
        scriptJobs.removeAll()
        apply()
    }

    // MARK: Demand

    /// Sets what `client` needs; an empty demand removes the client.
    func setDemand(_ demand: [CustomItemWidgetSource: Double], client: String) {
        if demand.isEmpty { demands.removeValue(forKey: client) } else { demands[client] = demand }
        apply()
    }

    /// The script widgets to run (only approved, enabled ones).
    func setScripts(_ jobs: [String: ScriptJob]) {
        let previous = scriptJobs
        scriptJobs = jobs
        for id in previous.keys where jobs[id] == nil { readings.scripts.removeValue(forKey: id) }
        applyScripts(changedFrom: previous)
    }

    /// Samples a source (or runs a widget's script) now.
    func refresh(source: CustomItemWidgetSource, scriptID: String? = nil) {
        if source == .script, let scriptID {
            runScript(scriptID)
        } else if source.isShared {
            sample(source)
        }
    }

    var effectiveDemand: [CustomItemWidgetSource: Double] { CustomItemsDemand.merge(Array(demands.values)) }
    var runningTimerCount: Int { timers.count + scriptTimers.count }
    var activeIntervals: [CustomItemWidgetSource: Double] { intervals }
    var activeScriptIDs: [String] { scriptTimers.keys.sorted() }

    /// Displays (or the Mac) went to sleep or woke up. Internal for tests.
    func setAsleep(_ asleep: Bool) {
        guard asleep != isAsleep else { return }
        isAsleep = asleep
        log.info(asleep ? "displays asleep: sampling paused" : "displays awake: sampling resumed")
        // Deltas across a sleep are meaningless.
        cpuBaseline = nil
        networkBaseline = nil
        apply()
        applyScripts(changedFrom: asleep ? [:] : scriptJobs)
    }

    private func apply() {
        let wanted = isAsleep ? [:] : effectiveDemand
        for (source, timer) in timers where wanted[source] != intervals[source] {
            timer.invalidate()
            timers.removeValue(forKey: source)
            intervals.removeValue(forKey: source)
            if wanted[source] == nil {
                log.info("sampler \(source.rawValue) stopped")
                switch source {
                case .cpu: cpuBaseline = nil; cpuHistory.removeAll()
                case .network: networkBaseline = nil; networkHistory.removeAll()
                default: break
                }
            }
        }
        for (source, interval) in wanted where timers[source] == nil {
            intervals[source] = interval
            log.info("sampler \(source.rawValue) started, every \(interval) s")
            if source == .clock {
                sample(.clock)
                scheduleClock()
                continue
            }
            let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sample(source) }
            }
            timer.tolerance = interval * 0.1
            RunLoop.main.add(timer, forMode: .common)
            timers[source] = timer
            sample(source)
            if source == .cpu || source == .network {
                // The first sample is only a baseline: publish a value soon instead of a
                // full interval later.
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(600))
                    guard let self, self.timers[source] != nil else { return }
                    self.sample(source)
                }
            }
        }
    }

    /// Clocks tick at the next whole second or minute, not on a drifting interval.
    private func scheduleClock() {
        timers[.clock]?.invalidate()
        guard let interval = intervals[.clock] else { timers.removeValue(forKey: .clock); return }
        let next = CustomItemsClock.nextTick(after: Date(), showsSeconds: interval < 60).addingTimeInterval(0.02)
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.intervals[.clock] != nil else { return }
                self.sample(.clock)
                self.scheduleClock()
            }
        }
        timer.tolerance = interval < 60 ? 0.05 : 0.3
        RunLoop.main.add(timer, forMode: .common)
        timers[.clock] = timer
    }

    // MARK: Sampling

    private func sample(_ source: CustomItemWidgetSource) {
        sampleCounts[source.rawValue, default: 0] += 1
        switch source {
        case .clock:
            readings.now = Date()
            publish(.clock)
        case .label, .script:
            break
        case .music, .calendar, .focus, .weather:
            if let snapshot = ambientReader?() { readings.ambient.take(source, from: snapshot) }
            publish(source)
        case .cpu, .memory, .network, .battery, .disk, .gpu:
            guard inFlight.insert(source).inserted else { return }
            Task { [weak self] in
                let raw = await Task.detached(priority: .utility) { CustomItemsRawSample.read(source) }.value
                self?.inFlight.remove(source)
                self?.absorb(raw, source: source)
            }
        }
    }

    private func absorb(_ raw: CustomItemsRawSample, source: CustomItemWidgetSource) {
        switch raw {
        case .cpu(let ticks?):
            if let baseline = cpuBaseline, let usage = CustomItemsCPUMath.usage(from: baseline, to: ticks) {
                readings.cpu = usage
                cpuHistory.append(usage.total)
                readings.cpuHistory = cpuHistory.values
            }
            cpuBaseline = ticks
        case .network(let counters, let at):
            if let baseline = networkBaseline,
               let rates = CustomItemsNetworkMath.rates(from: baseline.counters, to: counters, elapsed: at.timeIntervalSince(baseline.at)) {
                readings.network = rates
                networkHistory.append(rates.down + rates.up)
                if networkHistory.count > 24 { networkHistory.removeFirst(networkHistory.count - 24) }
                readings.networkHistory = networkHistory
            }
            networkBaseline = (counters, at)
        case .memory(let figures):
            readings.memory = figures
        case .battery(let state):
            readings.battery = state
            readings.batteryPresent = state != nil
        case .disk(let figures):
            readings.disk = figures
        case .gpu(let utilization):
            readings.gpu = utilization
            readings.gpuReported = utilization != nil
        case .cpu(nil):
            break
        }
        publish(source)
    }

    private func publish(_ source: CustomItemWidgetSource, scriptID: String? = nil) {
        revision += 1
        onUpdate?(source, scriptID)
    }

    // MARK: Scripts

    private func applyScripts(changedFrom previous: [String: ScriptJob]) {
        let wanted = isAsleep ? [:] : scriptJobs
        for (id, timer) in scriptTimers where wanted[id] == nil || wanted[id] != previous[id] {
            timer.invalidate()
            scriptTimers.removeValue(forKey: id)
            log.info("script widget \(id) stopped")
        }
        for (id, job) in wanted where scriptTimers[id] == nil {
            let timer = Timer(timeInterval: job.interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.runScript(id) }
            }
            timer.tolerance = job.interval * 0.1
            RunLoop.main.add(timer, forMode: .common)
            scriptTimers[id] = timer
            log.info("script widget \(id) started, every \(job.interval) s")
            runScript(id)
        }
    }

    private func runScript(_ id: String) {
        guard let job = scriptJobs[id], !isAsleep, scriptsRunning.insert(id).inserted else { return }
        scriptRunCount += 1
        Task { [weak self] in
            let result = await CustomItemsScriptRunner.run(job.command, timeout: job.timeout)
            guard let self else { return }
            self.scriptsRunning.remove(id)
            // Edited or switched off meanwhile: drop the stale result.
            guard self.scriptJobs[id] == job else { return }
            if result.status != .ok { self.log.notice("script widget \(id): \(result.status.rawValue)") }
            self.readings.scripts[id] = result
            self.publish(.script, scriptID: id)
        }
    }

    // MARK: Debug

    struct Snapshot: Codable {
        var asleep: Bool
        var demand: [String: Double]
        var clients: [String]
        var samplers: [String: Double]
        var scripts: [String]
        var runningTimers: Int
        var sampleCounts: [String: Int]
        var scriptRuns: Int
        var batteryPresent: Bool?
        var gpuReported: Bool?
    }

    func snapshot() -> Snapshot {
        Snapshot(asleep: isAsleep, demand: Dictionary(uniqueKeysWithValues: effectiveDemand.map { ($0.key.rawValue, $0.value) }),
                 clients: demands.keys.sorted(),
                 samplers: Dictionary(uniqueKeysWithValues: intervals.map { ($0.key.rawValue, $0.value) }),
                 scripts: activeScriptIDs, runningTimers: runningTimerCount, sampleCounts: sampleCounts,
                 scriptRuns: scriptRunCount, batteryPresent: readings.batteryPresent,
                 gpuReported: readings.gpuReported)
    }
}

/// One raw read, made off the main thread.
nonisolated enum CustomItemsRawSample: Sendable {
    case cpu(CustomItemsCPUTicks?)
    case memory(CustomItemsMemoryFigures?)
    case network([CustomItemsInterfaceCounters], Date)
    case battery(CustomItemsBatteryState?)
    case disk(CustomItemsDiskFigures?)
    case gpu(Double?)

    static func read(_ source: CustomItemWidgetSource) -> CustomItemsRawSample {
        switch source {
        case .cpu: .cpu(CustomItemsReaders.cpuTicks())
        case .memory: .memory(CustomItemsReaders.memoryFigures())
        case .network: .network(CustomItemsReaders.interfaceCounters(), Date())
        case .battery: .battery(CustomItemsReaders.battery())
        case .disk: .disk(CustomItemsReaders.disk())
        case .gpu: .gpu(CustomItemsReaders.gpuUtilization())
        case .clock, .label, .script, .music, .calendar, .focus, .weather: .cpu(nil)
        }
    }
}
