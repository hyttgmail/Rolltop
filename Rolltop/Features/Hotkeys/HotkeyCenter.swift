import Carbon.HIToolbox
import Foundation
import RolltopCore

/// Registers global shortcuts. The real one is `HotkeyCenter` (Carbon); tests inject fakes.
protocol HotkeyRegistering: AnyObject {
    /// Called with the id passed to `register` when the shortcut is pressed.
    var onPress: ((UInt32) -> Void)? { get set }
    /// `noErr` (0) on success, else the Carbon status.
    func register(_ combo: KeyCombo, id: UInt32) -> OSStatus
    func unregister(id: UInt32)
}

/// Global shortcuts through Carbon `RegisterEventHotKey` (no Accessibility or Input
/// Monitoring needed). One event handler on the event dispatcher target receives every
/// press and forwards the hotkey id to `onPress` on the main thread.
final class HotkeyCenter: HotkeyRegistering {
    /// 'RLTP'.
    nonisolated static let signature: OSType = 0x524C_5450

    var onPress: ((UInt32) -> Void)?
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private let log = Log.logger("hotkeys")

    /// Installs the Carbon event handler once.
    func install() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetEventDispatcherTarget(), hotkeyEventHandler, 1, &spec,
                                         Unmanaged.passUnretained(self).toOpaque(), &handler)
        if status != noErr { log.error("InstallEventHandler failed: \(status)") }
    }

    func register(_ combo: KeyCombo, id: UInt32) -> OSStatus {
        install()
        unregister(id: id)
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(UInt32(combo.keyCode), KeyComboRules.carbonModifiers(combo.modifiers), hotKeyID,
                                         GetEventDispatcherTarget(), 0, &ref)
        if status == noErr, let ref { refs[id] = ref }
        return status
    }

    func unregister(id: UInt32) {
        guard let ref = refs.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(ref)
    }

    func unregisterAll() {
        for id in Array(refs.keys) { unregister(id: id) }
    }

    /// Removes the handler and every hotkey (at quit, or when a test is done).
    func invalidate() {
        unregisterAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    var registeredIDs: Set<UInt32> { Set(refs.keys) }

    /// The handler's main-actor half. Tests call it through `SendEventToEventTarget`.
    func dispatch(id: UInt32) {
        guard refs[id] != nil else { return }
        onPress?(id)
    }

    /// Builds the event Carbon sends for a press of hotkey `id` (for tests: no key is posted).
    nonisolated static func makePressEvent(id: UInt32) -> EventRef? {
        var event: EventRef?
        guard CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0,
                          EventAttributes(kEventAttributeNone), &event) == noErr, let event else { return nil }
        var hotKeyID = EventHotKeyID(signature: signature, id: id)
        SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                          MemoryLayout<EventHotKeyID>.size, &hotKeyID)
        return event
    }
}

/// The Carbon callback. Hotkey events arrive on the main thread.
private nonisolated func hotkeyEventHandler(_ next: EventHandlerCallRef?, _ event: EventRef?,
                                            _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr, hotKeyID.signature == HotkeyCenter.signature else { return OSStatus(eventNotHandledErr) }
    let id = hotKeyID.id
    let center = Unmanaged<HotkeyCenter>.fromOpaque(userData)
    MainActor.assumeIsolated {
        center.takeUnretainedValue().dispatch(id: id)
    }
    return noErr
}
