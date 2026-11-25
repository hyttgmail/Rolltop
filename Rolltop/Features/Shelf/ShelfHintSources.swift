import AppKit
import AudioToolbox
import CoreAudio
import IOKit.ps

// What the hints watch. Each watcher runs only while its hint switch is on; none of them
// needs a permission.

// MARK: - Volume (Core Audio, public)

/// The default output device's volume and mute, following default-device changes.
final class ShelfVolumeWatcher {
    var onChange: ((ShelfVolumeReading) -> Void)?
    private(set) var last: ShelfVolumeReading?
    private var device: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var systemBlock: AudioObjectPropertyListenerBlock?
    private var deviceBlock: AudioObjectPropertyListenerBlock?
    private var deviceAddresses: [AudioObjectPropertyAddress] = []
    private let log = Log.logger("shelf")

    nonisolated private static let defaultDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    var isRunning: Bool { systemBlock != nil }

    func start() {
        guard systemBlock == nil else { return }
        let block = Self.listener { [weak self] in self?.attachDefaultDevice() }
        var address = Self.defaultDeviceAddress
        guard AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block) == noErr else {
            log.error("volume hints: cannot watch the default output device")
            return
        }
        systemBlock = block
        attachDefaultDevice()
    }

    func stop() {
        detachDevice()
        if let systemBlock {
            var address = Self.defaultDeviceAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, systemBlock)
        }
        systemBlock = nil
        last = nil
    }

    private func attachDefaultDevice() {
        detachDevice()
        device = Self.defaultOutputDevice()
        guard device != AudioObjectID(kAudioObjectUnknown) else { return }
        // A new device sets the baseline without a hint (macOS shows none either).
        last = Self.read(device)
        let block = Self.listener { [weak self] in self?.deviceChanged() }
        var added: [AudioObjectPropertyAddress] = []
        for var address in Self.deviceAddresses() where AudioObjectHasProperty(device, &address) {
            if AudioObjectAddPropertyListenerBlock(device, &address, .main, block) == noErr { added.append(address) }
        }
        deviceBlock = block
        deviceAddresses = added
    }

    private func detachDevice() {
        if let deviceBlock {
            for var address in deviceAddresses {
                AudioObjectRemovePropertyListenerBlock(device, &address, .main, deviceBlock)
            }
        }
        deviceBlock = nil
        deviceAddresses = []
        device = AudioObjectID(kAudioObjectUnknown)
    }

    private func deviceChanged() {
        guard let reading = Self.read(device), reading != last else { return }
        last = reading
        onChange?(reading)
    }

    /// Fires on the main queue; built outside the main actor so Core Audio may call it.
    nonisolated private static func listener(_ action: @escaping @MainActor () -> Void) -> AudioObjectPropertyListenerBlock {
        { _, _ in MainActor.assumeIsolated { action() } }
    }

    nonisolated static func deviceAddresses() -> [AudioObjectPropertyAddress] {
        let scope = kAudioDevicePropertyScopeOutput
        return [
            AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, mScope: scope, mElement: kAudioObjectPropertyElementMain),
            AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: scope, mElement: kAudioObjectPropertyElementMain),
            AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: scope, mElement: kAudioObjectPropertyElementMain),
            AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: scope, mElement: 1),
            AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: scope, mElement: 2),
        ]
    }

    nonisolated static func defaultOutputDevice() -> AudioObjectID {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = defaultDeviceAddress
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr ? device : AudioObjectID(kAudioObjectUnknown)
    }

    /// Volume (the device's main volume as the menu bar shows it) and mute; nil when the
    /// device has no volume control.
    nonisolated static func read(_ device: AudioObjectID) -> ShelfVolumeReading? {
        guard device != AudioObjectID(kAudioObjectUnknown) else { return nil }
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                                 mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr else { return nil }
        var muted: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyMute
        if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) != noErr { muted = 0 }
        return ShelfVolumeReading(level: min(max(volume, 0), 1), isMuted: muted != 0)
    }
}

// MARK: - Brightness (DisplayServices, private, Platform/DisplayBrightness.swift)

/// Brightness of every display whose brightness can be read. Uses DisplayServices'
/// change notification; when it cannot be registered, polls once a second (one
/// DisplayServices call per display per second, only while the brightness hint is on).
/// A change counts once it moved at least `threshold` from the settled value, so slow
/// automatic-brightness ramps do not produce hints.
final class ShelfBrightnessWatcher {
    var onChange: ((Float) -> Void)?
    private(set) var displays: [CGDirectDisplayID] = []
    private(set) var registered: [CGDirectDisplayID] = []
    private(set) var isPolling = false
    private var settled: [CGDirectDisplayID: Float] = [:]
    private var lastSeen: [CGDirectDisplayID: Float] = [:]
    private var lastChange: Date = .distantPast
    private var timer: Timer?
    private var running = false
    static let threshold: Float = 0.03
    static let settleAfter: TimeInterval = 1.0

    var isRunning: Bool { running }

    func start() {
        guard !running, DisplayBrightness.isAvailable else { return }
        running = true
        displays = DisplayBrightness.readableDisplays()
        for display in displays {
            let value = DisplayBrightness.brightness(of: display)
            settled[display] = value
            lastSeen[display] = value
        }
        DisplayBrightness.onChange = { [weak self] in self?.check() }
        registered = displays.filter { DisplayBrightness.register($0) }
        if registered.isEmpty, !displays.isEmpty {
            isPolling = true
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            }
            timer.tolerance = 0.3
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    func stop() {
        guard running else { return }
        running = false
        for display in registered { DisplayBrightness.unregister(display) }
        registered = []
        DisplayBrightness.onChange = nil
        timer?.invalidate()
        timer = nil
        isPolling = false
        settled = [:]
        lastSeen = [:]
    }

    private func check() {
        let now = Date()
        for display in displays {
            guard let value = DisplayBrightness.brightness(of: display) else { continue }
            let previous = lastSeen[display] ?? value
            lastSeen[display] = value
            if abs(value - previous) > 0.0001 {
                // A quiet second since the last change: what we see now is the new baseline.
                if now.timeIntervalSince(lastChange) > Self.settleAfter { settled[display] = previous }
                lastChange = now
            }
            if let base = settled[display], abs(value - base) >= Self.threshold {
                settled[display] = value
                onChange?(value)
            }
        }
    }
}

// MARK: - Battery (IOKit power sources, public)

/// The internal battery: plugged in, unplugged, fully charged, low. Nothing on a Mac
/// without a battery.
final class ShelfBatteryWatcher {
    var onChange: ((ShelfBatteryEvent) -> Void)?
    private(set) var last: ShelfBatteryReading?
    private var source: CFRunLoopSource?

    var isRunning: Bool { source != nil }

    func start() {
        guard source == nil else { return }
        last = ShelfPowerSources.read()
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let created = IOPSNotificationCreateRunLoopSource(ShelfPowerSources.callback, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), created, .defaultMode)
        source = created
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
        source = nil
        last = nil
    }

    fileprivate func powerSourcesChanged() {
        guard let reading = ShelfPowerSources.read() else { return }
        let event = ShelfBatteryEvent.classify(from: last, to: reading)
        last = reading
        if let event { onChange?(event) }
    }
}

nonisolated enum ShelfPowerSources {
    /// Runs on the main run loop (the source is added there).
    static let callback: IOPowerSourceCallbackType = { context in
        guard let context else { return }
        let address = UInt(bitPattern: context)
        MainActor.assumeIsolated {
            guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return }
            Unmanaged<ShelfBatteryWatcher>.fromOpaque(pointer).takeUnretainedValue().powerSourcesChanged()
        }
    }

    /// The internal battery, nil without one.
    static func read() -> ShelfBatteryReading? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = max(description[kIOPSMaxCapacityKey] as? Int ?? 100, 1)
            return ShelfBatteryReading(onPower: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                                       percent: Int((Double(current) / Double(maximum) * 100).rounded()),
                                       isCharged: description[kIOPSIsChargedKey] as? Bool ?? false)
        }
        return nil
    }
}
