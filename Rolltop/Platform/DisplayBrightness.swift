import CoreGraphics
import Foundation

/// Display brightness through the private DisplayServices framework, resolved at run time
/// with `dlsym`. Read-only: Rolltop never sets brightness. Every member degrades to
/// "unavailable" (nil, false, empty) when the framework or a symbol is missing.
///
/// `DisplayServicesRegisterForBrightnessChangeNotifications(display, observer, callback)`
/// takes a `CFNotificationCallback`; whether it fires for key presses, and for which
/// displays, is unverified on macOS 27 (needs someone to press the brightness keys).
nonisolated enum DisplayBrightness {
    private typealias GetFunction = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias RegisterFunction = @convention(c) (CGDirectDisplayID, UnsafeMutableRawPointer?, CFNotificationCallback) -> Int32
    private typealias UnregisterFunction = @convention(c) (CGDirectDisplayID, UnsafeMutableRawPointer?) -> Int32

    nonisolated(unsafe) private static let handle: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)

    nonisolated(unsafe) private static let getFunction: GetFunction? = symbol("DisplayServicesGetBrightness")
    nonisolated(unsafe) private static let registerFunction: RegisterFunction? = symbol("DisplayServicesRegisterForBrightnessChangeNotifications")
    nonisolated(unsafe) private static let unregisterFunction: UnregisterFunction? = symbol("DisplayServicesUnregisterForBrightnessChangeNotifications")

    private static func symbol<T>(_ name: String) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    /// Reading brightness is possible at all.
    static var isAvailable: Bool { getFunction != nil }
    /// Change notifications can be registered (the symbol resolves).
    static var canObserve: Bool { registerFunction != nil }

    /// 0…1, nil when the display has no readable brightness (most external displays).
    static func brightness(of display: CGDirectDisplayID) -> Float? {
        guard let getFunction else { return nil }
        var value: Float = 0
        guard getFunction(display, &value) == 0, value.isFinite else { return nil }
        return min(max(value, 0), 1)
    }

    /// Online displays whose brightness can be read.
    static func readableDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).filter { brightness(of: $0) != nil }
    }

    /// Called on the main actor after any registered display reports a change.
    @MainActor static var onChange: (@MainActor () -> Void)?

    private static let callback: CFNotificationCallback = { _, _, _, _, _ in
        Task { @MainActor in DisplayBrightness.onChange?() }
    }

    /// Registers for change notifications of `display`. False when the symbol is missing or
    /// DisplayServices refuses.
    static func register(_ display: CGDirectDisplayID) -> Bool {
        guard let registerFunction else { return false }
        return registerFunction(display, observer(display), callback) == 0
    }

    static func unregister(_ display: CGDirectDisplayID) {
        _ = unregisterFunction?(display, observer(display))
    }

    private static func observer(_ display: CGDirectDisplayID) -> UnsafeMutableRawPointer? {
        UnsafeMutableRawPointer(bitPattern: UInt(display) &+ 0x5354_0000)
    }
}
