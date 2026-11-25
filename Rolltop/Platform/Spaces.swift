import CoreGraphics
import Darwin
import Foundation

/// One Space as the window server lists it.
nonisolated struct ManagedSpace: Equatable, Sendable {
    enum Kind: String, Sendable {
        case desktop
        /// Anything that is not a desktop (full-screen apps, tiled full screen).
        case fullScreen = "full-screen"
    }

    /// The Space's `uuid`. On 27.2.1 the main display's first desktop reports "" here, so
    /// "" is a valid id (unique per display; callers key by display first).
    var id: String
    var kind: Kind
}

/// The Spaces of one display, in Mission Control order.
nonisolated struct ManagedDisplaySpaces: Equatable, Sendable {
    /// The display's UUID string (the same as `CGDisplayCreateUUIDFromDisplayID`), or "Main"
    /// when "Displays have separate Spaces" is off (not seen on this Mac).
    var displayKey: String
    var spaces: [ManagedSpace]
    var currentID: String?

    var desktops: [ManagedSpace] { spaces.filter { $0.kind == .desktop } }
}

/// Read-only access to the Spaces of each display through the private
/// `CGSCopyManagedDisplaySpaces` (resolved at run time). Never switches, creates or removes
/// a Space. Returns nil ("unavailable") when a symbol is missing or the data has an
/// unexpected shape.
///
/// Keys measured on 27.2.1 (2026-11-25): an array of dictionaries with
/// `"Display Identifier"` (display UUID string), `"Current Space"` (a Space dictionary) and
/// `"Spaces"` (array); a Space dictionary has `ManagedSpaceID`, `id64`, `type` (0 = desktop)
/// and `uuid`.
nonisolated enum ManagedSpaces {
    private typealias ConnectionFunction = @convention(c) () -> Int32
    private typealias CopySpacesFunction = @convention(c) (Int32) -> Unmanaged<CFArray>?

    private static let functions: (connection: ConnectionFunction, copy: CopySpacesFunction)? = {
        let handle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let connection = dlsym(handle, "CGSMainConnectionID"),
              let copy = dlsym(handle, "CGSCopyManagedDisplaySpaces") else { return nil }
        return (unsafeBitCast(connection, to: ConnectionFunction.self), unsafeBitCast(copy, to: CopySpacesFunction.self))
    }()

    static var isAvailable: Bool { functions != nil }

    /// Every display's Spaces, or nil when unavailable.
    static func read() -> [ManagedDisplaySpaces]? {
        guard let functions, let array = functions.copy(functions.connection())?.takeRetainedValue() else { return nil }
        return parse(array as NSArray as? [Any] ?? [])
    }

    /// Parses the raw `CGSCopyManagedDisplaySpaces` array; nil when its shape is unexpected.
    static func parse(_ raw: [Any]) -> [ManagedDisplaySpaces]? {
        var result: [ManagedDisplaySpaces] = []
        for entry in raw {
            guard let display = entry as? [String: Any],
                  let key = display["Display Identifier"] as? String,
                  let spaces = display["Spaces"] as? [Any] else { return nil }
            var parsed: [ManagedSpace] = []
            for space in spaces {
                guard let space = space as? [String: Any], let parsedSpace = parseSpace(space) else { return nil }
                parsed.append(parsedSpace)
            }
            let current = (display["Current Space"] as? [String: Any]).flatMap(parseSpace)?.id
            result.append(ManagedDisplaySpaces(displayKey: key, spaces: parsed, currentID: current))
        }
        return result.isEmpty ? nil : result
    }

    private static func parseSpace(_ space: [String: Any]) -> ManagedSpace? {
        guard let id = space["uuid"] as? String, let type = (space["type"] as? NSNumber)?.intValue else { return nil }
        return ManagedSpace(id: id, kind: type == 0 ? .desktop : .fullScreen)
    }

    /// The entry for `displayKey`, falling back to the shared "Main" entry.
    static func spaces(forDisplay displayKey: String, in lists: [ManagedDisplaySpaces]) -> ManagedDisplaySpaces? {
        lists.first { $0.displayKey.caseInsensitiveCompare(displayKey) == .orderedSame }
            ?? lists.first { $0.displayKey == "Main" }
    }
}
