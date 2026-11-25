import Foundation

/// A held menu bar restriction. Hiding lasts until `invalidate()` or until this
/// process exits (macOS then releases it, also after a crash).
final class RestrictionAssertion {
    let serial: Int
    private var raw: AnyObject?

    init(raw: AnyObject, serial: Int) {
        self.raw = raw
        self.serial = serial
    }

    var isValid: Bool { raw != nil }

    func invalidate() {
        guard let raw else { return }
        self.raw = nil
        RLTMenuBarRestriction.invalidate(raw)
    }
}

/// Swift face of the private allow-list API. Replaceable in tests.
protocol MenuBarRestricting: AnyObject {
    var isAvailable: Bool { get }
    /// Returns the assertion to hold, or nil when it could not be created (the
    /// completion then reports the error). The completion runs once on the main actor.
    func activate(systemIDs: [Int], bundleIDs: [String],
                  completion: @escaping @MainActor (Error?) -> Void) -> RestrictionAssertion?
}

final class MenuBarRestriction: MenuBarRestricting {
    private var serial = 0

    var isAvailable: Bool { RLTMenuBarRestriction.isAvailable() }

    func activate(systemIDs: [Int], bundleIDs: [String],
                  completion: @escaping @MainActor (Error?) -> Void) -> RestrictionAssertion? {
        serial += 1
        let raw = RLTMenuBarRestriction.activate(
            withSystemItems: systemIDs.map { NSNumber(value: $0) },
            bundleIdentifiers: bundleIDs,
            completion: { error in
                // The shim calls back on the main queue.
                MainActor.assumeIsolated { completion(error) }
            })
        return raw.map { RestrictionAssertion(raw: $0 as AnyObject, serial: serial) }
    }
}
