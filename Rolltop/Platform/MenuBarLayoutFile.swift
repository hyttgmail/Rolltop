import AppKit
import Foundation
import UniformTypeIdentifiers

// The two files of other processes that the layout editor reads (PLATFORM §5): the menu
// bar order table (MenuBarAgent) and Control Center's allow list. Both live in another
// app's group container: touching them can raise a consent prompt ("… would like to
// access data from other apps") that blocks the call until the user answers. Nothing here
// runs by itself: the layout editor calls it only after the user's click on its consent
// row (and never from a test). The Control Center file is never written.

/// One of the two files.
nonisolated enum MenuBarProtectedFile: String, CaseIterable, Sendable, Codable {
    /// `com.apple.MenuBar.plist`, key `TrailingItemPreferredPositions` (read and written).
    case layout
    /// `group.com.apple.controlcenter.plist`, key `trackedApplications` (read only).
    case allowList = "allow-list"

    var url: URL {
        let home = URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory)
        switch self {
        case .layout:
            return home.appending(path: "Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar.plist")
        case .allowList:
            return home.appending(path: "Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter.plist")
        }
    }

    var fileName: String { url.lastPathComponent }

    /// The path-based preferences domain cfprefsd serves: the absolute path without `.plist`.
    var preferencesDomain: String { url.deletingPathExtension().path(percentEncoded: false) }

    var key: String {
        switch self {
        case .layout: "TrailingItemPreferredPositions"
        case .allowList: "trackedApplications"
        }
    }
}

/// What one read returned. The value travels as property-list data so it can cross threads.
nonisolated enum MenuBarFileRead: Sendable, Equatable {
    /// The key's value, encoded as a binary property list.
    case value(Data)
    /// The file was read but has no such key (access works).
    case keyMissing
    /// CFPreferences returned nothing: refused silently or no such key (cannot tell).
    case noValue
    case failed(String)

    var succeeded: Bool {
        switch self {
        case .value, .keyMissing: true
        case .noValue, .failed: false
        }
    }

    var name: String {
        switch self {
        case .value(let data): "value (\(data.count) bytes)"
        case .keyMissing: "key missing"
        case .noValue: "no value"
        case .failed(let reason): "failed: \(reason)"
        }
    }

    /// The decoded value.
    var object: Any? {
        guard case .value(let data) = self else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil)
    }
}

/// Blocking calls on the two files. Run them only through `MenuBarBoundedCall` (off the
/// main thread, with a timeout) and only after the user's consent.
nonisolated enum MenuBarFileIO {
    /// Reads the key through cfprefsd (path domain). May block on a consent prompt.
    static func readPreferences(_ file: MenuBarProtectedFile) -> MenuBarFileRead {
        let domain = file.preferencesDomain as CFString
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard let value = CFPreferencesCopyValue(file.key as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            return .noValue
        }
        return encode(value)
    }

    /// Reads the file itself.
    static func readFile(at url: URL, key: String) -> MenuBarFileRead {
        do {
            let data = try Data(contentsOf: url)
            guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                return .failed("root is not a dictionary")
            }
            guard let value = root[key] else { return .keyMissing }
            return encode(value as AnyObject)
        } catch let error as NSError {
            let underlying = (error.userInfo[NSUnderlyingErrorKey] as? NSError).map { " (\($0.domain) \($0.code))" } ?? ""
            return .failed("\(error.domain) \(error.code)\(underlying)")
        }
    }

    /// Reads the file through a bookmark the user made by choosing it in an open panel.
    static func readBookmark(_ bookmark: Data, key: String) -> MenuBarFileRead {
        var stale = false
        let url = (try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], bookmarkDataIsStale: &stale))
            ?? (try? URL(resolvingBookmarkData: bookmark, options: [], bookmarkDataIsStale: &stale))
        guard let url else { return .failed("bookmark does not resolve") }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return readFile(at: url, key: key)
    }

    /// Writes new weights into the order table through cfprefsd: re-reads the table, changes
    /// only `changes` in the raw dictionary (other rows keep their exact values), writes it
    /// back and synchronizes. Never used for the Control Center file.
    static func writeLayout(_ changes: [String: Double]) -> MenuBarFileWrite {
        let file = MenuBarProtectedFile.layout
        let domain = file.preferencesDomain as CFString
        let key = file.key as CFString
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard let current = CFPreferencesCopyValue(key, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? NSDictionary else {
            return .refused("re-read returned no table")
        }
        let table = NSMutableDictionary(dictionary: current)
        for (name, weight) in changes { table[name] = NSNumber(value: weight) }
        CFPreferencesSetValue(key, table, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            return .refused("synchronize failed")
        }
        return .written
    }

    private static func encode(_ value: AnyObject) -> MenuBarFileRead {
        do {
            return .value(try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0))
        } catch {
            return .failed("value is not a property list")
        }
    }

    /// Makes a bookmark for a file the user chose (security-scoped where allowed).
    static func bookmark(for url: URL) -> Data? {
        (try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
    }

    /// The open panel of "Choose File…", at the file's folder, naming the file to pick.
    /// Returns the chosen URL only when it is that file. Main actor; never prompts by itself.
    @MainActor
    static func chooseFile(_ file: MenuBarProtectedFile, message: String) async -> (url: URL?, choseOther: Bool) {
        let panel = NSOpenPanel()
        panel.directoryURL = file.url.deletingLastPathComponent()
        panel.message = message
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.allowedContentTypes = [.propertyList]
        NSApp.activate()
        guard await panel.begin() == .OK, let url = panel.url else { return (nil, false) }
        guard url.lastPathComponent == file.fileName else { return (nil, true) }
        return (url, false)
    }
}

/// What a write did.
nonisolated enum MenuBarFileWrite: Sendable, Equatable {
    case written
    case refused(String)
}

/// Runs a blocking call on its own thread and waits at most `timeout`. A call that never
/// returns keeps only its own thread: it blocks neither later attempts nor quitting. A
/// result that arrives after the timeout goes to `late` (once).
nonisolated final class MenuBarBoundedCall<Result: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result?, Never>?
    private var late: (@Sendable (Result) -> Void)?

    static func run(timeout: Duration, label: String, _ work: @escaping @Sendable () -> Result,
                    late: (@Sendable (Result) -> Void)? = nil) async -> Result? {
        let call = MenuBarBoundedCall<Result>()
        call.late = late
        return await withCheckedContinuation { continuation in
            call.continuation = continuation
            let thread = Thread { call.deliver(work()) }
            thread.name = "Rolltop.\(label)"
            thread.start()
            let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { call.expire() }
        }
    }

    private func deliver(_ result: Result) {
        lock.lock()
        let waiting = continuation
        continuation = nil
        let lateHandler = waiting == nil ? late : nil
        late = nil
        lock.unlock()
        if let waiting { waiting.resume(returning: result) } else { lateHandler?(result) }
    }

    private func expire() {
        lock.lock()
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(returning: nil)
    }
}
