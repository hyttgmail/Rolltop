import Darwin
import Foundation
import IOKit
import IOKit.ps

/// Raw system readings for widgets: public Mach, sysctl, IOKit power source and file
/// system APIs, no permissions needed. Called off the main thread by the sampler hub.
nonisolated enum CustomItemsReaders {
    private static let host = mach_host_self()

    static func cpuTicks() -> CustomItemsCPUTicks? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let ticks = info.cpu_ticks
        return CustomItemsCPUTicks(user: UInt64(ticks.0), system: UInt64(ticks.1), idle: UInt64(ticks.2), nice: UInt64(ticks.3))
    }

    static func vmCounts() -> CustomItemsVMCounts? {
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        guard host_page_size(host, &pageSize) == KERN_SUCCESS else { return nil }
        return CustomItemsVMCounts(pageSize: UInt64(pageSize), physicalMemory: ProcessInfo.processInfo.physicalMemory,
                                   free: UInt64(info.free_count), active: UInt64(info.active_count),
                                   inactive: UInt64(info.inactive_count), speculative: UInt64(info.speculative_count),
                                   wired: UInt64(info.wire_count), compressed: UInt64(info.compressor_page_count),
                                   purgeable: UInt64(info.purgeable_count), external: UInt64(info.external_page_count),
                                   internal: UInt64(info.internal_page_count))
    }

    static func sysctlInt32(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    static func memoryFigures() -> CustomItemsMemoryFigures? {
        guard let counts = vmCounts() else { return nil }
        return CustomItemsMemoryMath.figures(counts, pressureLevel: sysctlInt32("kern.memorystatus_vm_pressure_level"),
                                             freeLevelPercent: sysctlInt32("kern.memorystatus_level"))
    }

    /// 64-bit byte counters of every interface (`NET_RT_IFLIST2`).
    static func interfaceCounters() -> [CustomItemsInterfaceCounters] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return [] }
        var result: [CustomItemsInterfaceCounters] = []
        buffer.withUnsafeBytes { raw in
            var offset = 0
            let headerSize = MemoryLayout<if_msghdr>.size
            while offset + headerSize <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let messageLength = Int(header.ifm_msglen)
                guard messageLength > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= length {
                    let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
                    if if_indextoname(UInt32(message.ifm_index), &name) != nil {
                        let bytes = name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                        result.append(CustomItemsInterfaceCounters(name: String(decoding: bytes, as: UTF8.self),
                                                                   received: message.ifm_data.ifi_ibytes,
                                                                   sent: message.ifm_data.ifi_obytes))
                    }
                }
                offset += messageLength
            }
        }
        return result
    }

    /// The internal battery, nil on Macs without one.
    static func battery() -> CustomItemsBatteryState? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  description[kIOPSIsPresentKey] as? Bool ?? true,
                  let current = description[kIOPSCurrentCapacityKey] as? Int else { continue }
            return CustomItemsBatteryMath.state(
                current: current, max: description[kIOPSMaxCapacityKey] as? Int ?? 100,
                isCharging: description[kIOPSIsChargingKey] as? Bool ?? false,
                isOnAC: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                isCharged: description[kIOPSIsChargedKey] as? Bool ?? false,
                timeToEmpty: description[kIOPSTimeToEmptyKey] as? Int,
                timeToFull: description[kIOPSTimeToFullChargeKey] as? Int)
        }
        return nil
    }

    /// GPU usage of the busiest `IOAccelerator` (public IOKit, no permission), 0…1; nil
    /// when no accelerator reports `Device Utilization %`.
    static func gpuUtilization() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var statistics: [[String: Any]] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            if let value = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
               let dictionary = value as? [String: Any] {
                statistics.append(dictionary)
            }
        }
        return CustomItemsGPUMath.utilization(from: statistics)
    }

    /// The startup volume.
    static func disk() -> CustomItemsDiskFigures? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(filePath: "/").resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacity else { return nil }
        return CustomItemsDiskFigures(total: Int64(total), available: Int64(available),
                                      availableForImportantUsage: values.volumeAvailableCapacityForImportantUsage)
    }
}

// MARK: - Scripts

nonisolated struct CustomItemsScriptResult: Equatable, Sendable {
    enum Status: String, Sendable { case ok, failed, timedOut = "timed-out", launchFailed = "launch-failed" }

    var status: Status
    /// The first non-empty line of standard output, trimmed and capped.
    var line: String?
    var exitCode: Int32?
    var duration: TimeInterval
}

nonisolated enum CustomItemsScriptRunner {
    static let maximumLineLength = 60
    static let outputLimit = 4096

    /// A minimal environment: no inherited variables (API keys, tokens) reach the script.
    static func environment(home: String = NSHomeDirectory()) -> [String: String] {
        ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin", "HOME": home,
         "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8", "TMPDIR": NSTemporaryDirectory()]
    }

    /// The first non-empty line of `output`, trimmed and capped.
    static func firstLine(of output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return String(trimmed.prefix(maximumLineLength)) }
        }
        return nil
    }

    /// Runs `/bin/sh -c command` in `/` with `environment()`, standard input and error
    /// closed, in its own process group, which is ended as a whole after `timeout` seconds
    /// (`ScriptRunner`, Platform).
    static func run(_ command: String, timeout: TimeInterval) async -> CustomItemsScriptResult {
        let result = await ScriptRunner.run(command, timeout: timeout,
                                            options: .init(environment: environment(), currentDirectory: "/",
                                                           capturesStandardError: false, outputLimit: outputLimit))
        let status: CustomItemsScriptResult.Status = if result.launchError != nil { .launchFailed }
            else if result.timedOut { .timedOut }
            else if result.terminationStatus == 0 { .ok }
            else { .failed }
        return CustomItemsScriptResult(status: status, line: firstLine(of: String(decoding: result.output, as: UTF8.self)),
                                       exitCode: result.timedOut ? nil : result.terminationStatus, duration: result.duration)
    }
}

