import Foundation

// File shelf: the pure part. The shelf holds references (path + bookmark), never copies;
// items expire after a lifetime or stay until removed; the list is capped.

/// One file or folder on the shelf, as stored on disk.
nonisolated struct ShelfFileItem: Codable, Sendable, Identifiable, Equatable {
    var id: UUID
    /// Where the file was when last resolved.
    var path: String
    /// Bookmark data that follows renames and moves (nil when it could not be made).
    var bookmark: Data?
    var isDirectory: Bool
    var addedAt: Date

    var name: String { (path as NSString).lastPathComponent }
}

/// A file a drop or command wants to add.
nonisolated struct ShelfFileDrop: Sendable, Equatable {
    var path: String
    var bookmark: Data?
    var isDirectory: Bool
}

nonisolated enum ShelfFilePresence: String, Sendable, Equatable {
    case present
    /// Deleted, or on a volume that is not mounted.
    case missing
}

nonisolated struct ShelfFileList: Codable, Sendable, Equatable {
    /// Newest first.
    private(set) var items: [ShelfFileItem] = []

    static let defaultCap = 50

    init(items: [ShelfFileItem] = []) {
        self.items = items.sorted { $0.addedAt > $1.addedAt }
    }

    /// Adds drops newest first; a path already on the shelf moves to the front with a fresh
    /// date (its lifetime restarts). Beyond `cap` the oldest items leave. Returns the ids
    /// of the added or refreshed items.
    @discardableResult
    mutating func add(_ drops: [ShelfFileDrop], now: Date, cap: Int = defaultCap) -> [UUID] {
        var touched: [UUID] = []
        for drop in drops.reversed() {
            if let index = items.firstIndex(where: { $0.path == drop.path }) {
                var item = items.remove(at: index)
                item.addedAt = now
                if drop.bookmark != nil { item.bookmark = drop.bookmark }
                items.insert(item, at: 0)
                touched.append(item.id)
            } else {
                let item = ShelfFileItem(id: UUID(), path: drop.path, bookmark: drop.bookmark, isDirectory: drop.isDirectory, addedAt: now)
                items.insert(item, at: 0)
                touched.append(item.id)
            }
        }
        if items.count > max(1, cap) { items.removeLast(items.count - max(1, cap)) }
        return touched.reversed()
    }

    /// Items older than `lifetime` (nil = they stay until removed). Returns what left.
    @discardableResult
    mutating func expire(now: Date, lifetime: TimeInterval?) -> [ShelfFileItem] {
        guard let lifetime else { return [] }
        let removed = items.filter { now.timeIntervalSince($0.addedAt) >= lifetime }
        items.removeAll { now.timeIntervalSince($0.addedAt) >= lifetime }
        return removed
    }

    /// When the next item expires (to schedule one timer instead of polling).
    func nextExpiry(lifetime: TimeInterval?) -> Date? {
        guard let lifetime, let oldest = items.map(\.addedAt).min() else { return nil }
        return oldest.addingTimeInterval(lifetime)
    }

    @discardableResult
    mutating func remove(_ id: UUID) -> ShelfFileItem? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        return items.remove(at: index)
    }

    mutating func removeAll() { items = [] }

    /// The file moved (bookmark resolved elsewhere): remember the new path.
    mutating func updatePath(_ id: UUID, to path: String) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].path != path else { return }
        items[index].path = path
    }
}

/// What a drop onto the shelf adds: file URLs only (web links and other data are ignored),
/// standardised, without duplicates, in drop order.
nonisolated enum ShelfDropPlanner {
    static func fileURLs(from urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for url in urls where url.isFileURL {
            let standard = url.standardizedFileURL
            let path = standard.path(percentEncoded: false)
            guard !path.isEmpty, path != "/", seen.insert(path).inserted else { continue }
            result.append(standard)
        }
        return result
    }

    /// Whether a drag carrying these pasteboard types is worth opening the shelf for.
    static func carriesFiles(types: [String]) -> Bool {
        types.contains(ShelfPasteboardTypes.fileURL) || types.contains("NSFilenamesPboardType")
    }
}

/// Lifetime choices for the settings picker, in hours (0 = until removed).
nonisolated enum ShelfFileLifetime {
    static let choices: [Int] = [1, 24, 24 * 7, 0]
    static let defaultHours = 24

    static func seconds(hours: Int) -> TimeInterval? { hours > 0 ? TimeInterval(hours) * 3600 : nil }
}
