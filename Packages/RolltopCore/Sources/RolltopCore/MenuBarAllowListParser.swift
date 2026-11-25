import Foundation

/// Reads Control Center's allow list (key `trackedApplications`: a binary property list
/// whose root is a flat array alternating keys and values). A key is
/// `{ "bundle": { "_0": "<bundle id>" } }` or `{ "adhocBinary": … }`; a value is
/// `{ "location": <key shape>, "menuItemLocations": [<key shape>…], "isAllowed": Bool }`.
/// Apps switched off in System Settings › Menu Bar have `isAllowed` false.
/// Unverified on this Mac (web research 2026-11-25): the parser is tolerant.
public enum MenuBarAllowListParser {
    public enum Identity: Sendable, Equatable, Hashable {
        case bundle(String)
        /// An ad-hoc signed binary (no bundle id); its description, types only.
        case adhoc
    }

    public struct Entry: Sendable, Equatable {
        public var identity: Identity
        public var isAllowed: Bool
        /// Bundle ids of the entry's `menuItemLocations`.
        public var itemLocations: [String]

        public init(identity: Identity, isAllowed: Bool, itemLocations: [String]) {
            self.identity = identity
            self.isAllowed = isAllowed
            self.itemLocations = itemLocations
        }
    }

    public enum Result: Sendable, Equatable {
        case entries([Entry], skipped: Int)
        /// The root is not the expected array; the description lists types and key names only.
        case notRecognized(String)
    }

    /// Parses the `trackedApplications` value: `Data` (a property list) or an already
    /// decoded object.
    public static func parse(_ value: Any?) -> Result {
        var root = value
        if let data = value as? Data {
            guard let decoded = try? PropertyListSerialization.propertyList(from: data, format: nil) else {
                return .notRecognized("data that is not a property list (\(data.count) bytes)")
            }
            root = decoded
        }
        guard let array = root as? [Any] else { return .notRecognized(describe(root)) }
        var entries: [Entry] = []
        var skipped = 0
        var index = 0
        while index < array.count {
            guard index + 1 < array.count else { skipped += 1; break }
            let key = array[index], value = array[index + 1]
            index += 2
            guard let identity = identity(key), let dict = value as? [String: Any],
                  let allowed = dict["isAllowed"] as? Bool else {
                skipped += 1
                continue
            }
            let locations = (dict["menuItemLocations"] as? [Any] ?? []).compactMap { location -> String? in
                if case .bundle(let id)? = self.identity(location) { id } else { nil }
            }
            entries.append(Entry(identity: identity, isAllowed: allowed, itemLocations: locations))
        }
        return .entries(entries, skipped: skipped)
    }

    /// Bundle ids switched off, in file order, without duplicates.
    public static func turnedOff(_ entries: [Entry]) -> [String] {
        var seen = Set<String>()
        return entries.compactMap { entry -> String? in
            guard !entry.isAllowed, case .bundle(let id) = entry.identity, seen.insert(id).inserted else { return nil }
            return id
        }
    }

    static func identity(_ object: Any) -> Identity? {
        guard let dict = object as? [String: Any] else { return nil }
        if let bundle = dict["bundle"] as? [String: Any], let id = bundle["_0"] as? String, !id.isEmpty {
            return .bundle(id)
        }
        if dict["adhocBinary"] != nil { return .adhoc }
        return nil
    }

    /// Types and key names only, never values: safe to log and to show.
    public static func describe(_ object: Any?, depth: Int = 0) -> String {
        switch object {
        case nil: return "nothing"
        case let dict as [String: Any]:
            guard depth < 2 else { return "dictionary" }
            let keys = dict.keys.sorted().map { "\($0): \(describe(dict[$0], depth: depth + 1))" }
            return "dictionary {\(keys.joined(separator: ", "))}"
        case let array as [Any]:
            guard depth < 2, let first = array.first else { return "array of \(array.count)" }
            return "array of \(array.count), first \(describe(first, depth: depth + 1))"
        case is String: return "string"
        case is Data: return "data"
        case is Date: return "date"
        case let number as NSNumber:
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? "boolean" : "number"
        default: return String(describing: type(of: object!))
        }
    }
}
