import CoreGraphics
import Foundation

/// Bundle id of the process that draws the whole menu bar on macOS 27.
public let menuBarAgentBundleID = "com.apple.MenuBarAgent"

/// A running process that may own status items.
public struct RunningAppRecord: Sendable, Equatable, Codable {
    public var pid: Int32
    public var bundleID: String?
    public var name: String?
    public var bundlePath: String?
    /// macOS 27 hides third-party items of apps that do not run from /Applications.
    public var runsOutsideApplications: Bool

    public init(pid: Int32, bundleID: String?, name: String?, bundlePath: String?, runsOutsideApplications: Bool) {
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.bundlePath = bundlePath
        self.runsOutsideApplications = runsOutsideApplications
    }

    /// Whether `path` (already resolved) is inside an Applications folder macOS accepts.
    /// System locations count as inside: their items are never hidden for this reason.
    public static func isOutsideApplications(resolvedPath path: String?) -> Bool {
        guard let path, !path.isEmpty else { return false }
        let systemPrefixes = ["/System/", "/usr/", "/Library/Apple/", "/sbin/", "/bin/"]
        if systemPrefixes.contains(where: path.hasPrefix) { return false }
        return !path.hasPrefix("/Applications/")
    }
}

/// How one app's `AXExtrasMenuBar` read went.
public enum ExtrasReadStatus: String, Sendable, Codable {
    case read
    /// No answer within the messaging timeout, twice.
    case timedOut
    /// The app answers but exposes no Accessibility tree.
    case refused
}

/// One child of an app's `AXExtrasMenuBar` (list A in PLATFORM.md §2).
/// Its frame is stale for hidden items.
public struct ExtraItemRecord: Sendable, Equatable, Codable {
    public var index: Int
    public var frame: CGRect
    /// For MenuBarAgent-hosted extras: `com.apple.menuextra.*`.
    public var axIdentifier: String?
    public var title: String?
    /// `AXDescription` (localized name of system modules).
    public var detail: String?

    public init(index: Int, frame: CGRect, axIdentifier: String? = nil, title: String? = nil, detail: String? = nil) {
        self.index = index
        self.frame = frame
        self.axIdentifier = axIdentifier
        self.title = title
        self.detail = detail
    }
}

public struct AppExtrasRecord: Sendable, Equatable, Codable {
    public var pid: Int32
    public var bundleID: String?
    public var status: ExtrasReadStatus
    public var items: [ExtraItemRecord]

    public init(pid: Int32, bundleID: String?, status: ExtrasReadStatus, items: [ExtraItemRecord]) {
        self.pid = pid
        self.bundleID = bundleID
        self.status = status
        self.items = items
    }
}

/// One slot MenuBarAgent actually draws (list B in PLATFORM.md §2).
public struct DrawnSlotRecord: Sendable, Equatable, Codable {
    public var displayID: UInt32
    /// Global top-left coordinates.
    public var frame: CGRect
    public var ownerPID: Int32?
    public var ownerBundleID: String?
    /// For MenuBarAgent-hosted modules: `com.apple.menuextra.*`.
    public var axIdentifier: String?
    /// The slot sits under the overflow chevron: laid out but not visible in the bar.
    public var isOverflowed: Bool

    public init(displayID: UInt32, frame: CGRect, ownerPID: Int32?, ownerBundleID: String?,
                axIdentifier: String?, isOverflowed: Bool = false) {
        self.displayID = displayID
        self.frame = frame
        self.ownerPID = ownerPID
        self.ownerBundleID = ownerBundleID
        self.axIdentifier = axIdentifier
        self.isOverflowed = isOverflowed
    }
}

/// MenuBarAgent's bar on one display.
public struct DisplayBarRecord: Sendable, Equatable, Codable {
    public var displayID: UInt32
    public var isMain: Bool
    /// Frame of MenuBarAgent's window on this display, global top-left coordinates.
    public var barFrame: CGRect
    /// The native overflow chevron (`menu-bar-overflow-indicator`), when present.
    public var chevronFrame: CGRect?
    public var chevronExpanded: Bool
    public var slots: [DrawnSlotRecord]

    public init(displayID: UInt32, isMain: Bool, barFrame: CGRect, chevronFrame: CGRect?,
                chevronExpanded: Bool, slots: [DrawnSlotRecord]) {
        self.displayID = displayID
        self.isMain = isMain
        self.barFrame = barFrame
        self.chevronFrame = chevronFrame
        self.chevronExpanded = chevronExpanded
        self.slots = slots
    }
}

public struct DrawnSnapshot: Sendable, Equatable, Codable {
    public var displays: [DisplayBarRecord]
    public var capturedAt: Date
    /// False when MenuBarAgent could not be read (no permission, timeout).
    public var isReadable: Bool

    public init(displays: [DisplayBarRecord], capturedAt: Date, isReadable: Bool) {
        self.displays = displays
        self.capturedAt = capturedAt
        self.isReadable = isReadable
    }

    public static let empty = DrawnSnapshot(displays: [], capturedAt: .distantPast, isReadable: false)

    public var allSlots: [DrawnSlotRecord] { displays.flatMap(\.slots) }
}

public enum OverflowClassifier {
    /// Overflowed items keep a slot in MenuBarAgent's tree, stacked under the chevron
    /// (measured on 27.2.1). A slot overlapping the chevron horizontally by more than
    /// one point is overflowed.
    public static func isOverflowed(slot: CGRect, chevron: CGRect?) -> Bool {
        guard let chevron else { return false }
        let overlap = min(slot.maxX, chevron.maxX) - max(slot.minX, chevron.minX)
        return overlap > 1
    }
}
