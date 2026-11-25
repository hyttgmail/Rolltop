import Foundation

/// A system menu bar module that macOS lets an allow-list keep or drop on its own.
///
/// The raw value is the integer macOS expects in `allowedSystemItems`
/// (decoded on macOS 27.2.1, see docs/PLATFORM.md §3).
public enum SystemModule: Int, CaseIterable, Sendable, Hashable, Comparable {
    case battery = 0
    case bluetooth = 1
    case clock = 2
    /// Unverified: id 3 is assumed to be Displays (not present on the test machine).
    case displays = 3
    /// Unverified: id 4 is assumed to be Keyboard Brightness.
    case keyboard = 4
    case sound = 5
    case wifi = 6
    /// Unverified: id 7 is assumed to be Screen Mirroring.
    case screenMirroring = 7
    case controlCenter = 8

    /// The integer passed to `allowedSystemItems`.
    public var systemItemID: Int { rawValue }

    /// Whether the id ↔ module mapping was measured on a real machine.
    public var isVerified: Bool {
        switch self {
        case .displays, .keyboard, .screenMirroring: false
        default: true
        }
    }

    /// Stable name used in storage and URLs (`system:<name>`).
    public var name: String {
        switch self {
        case .battery: "battery"
        case .bluetooth: "bluetooth"
        case .clock: "clock"
        case .displays: "displays"
        case .keyboard: "keyboard"
        case .sound: "sound"
        case .wifi: "wifi"
        case .screenMirroring: "screen-mirroring"
        case .controlCenter: "control-center"
        }
    }

    /// Fixed English name. The app shows a localized name (`ItemNames.module`); this one
    /// keeps catalog entries stable while macOS's spoken descriptions carry live state in
    /// the system language ("Wi‑Fi, connected, 3 bars").
    public var defaultName: String {
        switch self {
        case .battery: "Battery"
        case .bluetooth: "Bluetooth"
        case .clock: "Clock"
        case .displays: "Displays"
        case .keyboard: "Keyboard Brightness"
        case .sound: "Sound"
        case .wifi: "Wi-Fi"
        case .screenMirroring: "Screen Mirroring"
        case .controlCenter: "Control Center"
        }
    }

    /// The `AXIdentifier` MenuBarAgent reports for this module.
    /// The identifiers of the three unverified modules are guesses.
    public var axIdentifier: String {
        switch self {
        case .battery: "com.apple.menuextra.battery"
        case .bluetooth: "com.apple.menuextra.bluetooth"
        case .clock: "com.apple.menuextra.clock"
        case .displays: "com.apple.menuextra.display"
        case .keyboard: "com.apple.menuextra.keyboardbrightness"
        case .sound: "com.apple.menuextra.sound"
        case .wifi: "com.apple.menuextra.wifi"
        case .screenMirroring: "com.apple.menuextra.screenmirroring"
        case .controlCenter: "com.apple.menuextra.controlcenter"
        }
    }

    public init?(name: String) {
        guard let match = Self.allCases.first(where: { $0.name == name }) else { return nil }
        self = match
    }

    public init?(axIdentifier: String) {
        guard let match = Self.allCases.first(where: { $0.axIdentifier == axIdentifier }) else { return nil }
        self = match
    }

    public init?(systemItemID: Int) {
        self.init(rawValue: systemItemID)
    }

    public static func < (lhs: SystemModule, rhs: SystemModule) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Prefix shared by every MenuBarAgent-hosted extra.
    public static let menuExtraIdentifierPrefix = "com.apple.menuextra."
}

extension SystemModule: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let name = try container.decode(String.self)
        guard let module = SystemModule(name: name) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown system module \(name)")
        }
        self = module
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(name)
    }
}
