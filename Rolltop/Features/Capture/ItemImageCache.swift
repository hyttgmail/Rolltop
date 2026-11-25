import AppKit
import Foundation

/// Metadata of one cached item image (`index.json`).
nonisolated struct CacheRecord: Codable, Sendable, Equatable {
    var key: ItemImageKey
    var traits: ImageTraits
    /// Pixels per point of the capture.
    var scale: Double
    var pixelWidth: Int
    var pixelHeight: Int
    var capturedAt: Date
    /// PNG size on disk.
    var bytes: Int
}

nonisolated struct CacheIndex: Codable, Sendable, Equatable {
    var version = 1
    var records: [CacheRecord] = []
    /// When each owner was last present in the menu bar (string form of `OwnerID`).
    var ownerLastSeen: [String: Date] = [:]
}

/// Which cached images to drop. Pure, so the policy is testable.
nonisolated enum CachePruner {
    struct Limits: Sendable {
        var maxAge: TimeInterval = 30 * 24 * 3600
        var maxEntries = 400
        var maxBytes = 4 * 1024 * 1024
    }

    static func keysToRemove(_ index: CacheIndex, now: Date, limits: Limits = Limits()) -> Set<ItemImageKey> {
        func lastSeen(_ record: CacheRecord) -> Date { index.ownerLastSeen[record.key.owner] ?? record.capturedAt }
        var remove = Set<ItemImageKey>()
        // Owners not seen for `maxAge`.
        for record in index.records where now.timeIntervalSince(lastSeen(record)) > limits.maxAge {
            remove.insert(record.key)
        }
        // Then the least recently seen until the cache fits.
        var kept = index.records.filter { !remove.contains($0.key) }
            .sorted { (lastSeen($0), $0.capturedAt) > (lastSeen($1), $1.capturedAt) }
        var bytes = kept.reduce(0) { $0 + $1.bytes }
        while !kept.isEmpty, kept.count > limits.maxEntries || bytes > limits.maxBytes {
            let dropped = kept.removeLast()
            bytes -= dropped.bytes
            remove.insert(dropped.key)
        }
        return remove
    }
}

/// Item images in memory and in `~/Library/Caches/com.alphapengwang.rolltop/items/` (small PNGs,
/// pixels as captured, plus `index.json`). Disk writes run on a serial queue; PNGs are
/// decoded on first use.
final class ItemImageCache {
    /// A decoded image ready to serve.
    final class Entry {
        let record: CacheRecord
        let image: CGImage
        /// Black with the foreground's strength as alpha; drawn as a template.
        let mask: CGImage?
        private var sized: [CGFloat: NSImage] = [:]

        init(record: CacheRecord, image: CGImage, mask: CGImage?) {
            self.record = record
            self.image = image
            self.mask = mask
        }

        var isTemplate: Bool { mask != nil }

        func nsImage(height: CGFloat) -> NSImage {
            if let cached = sized[height] { return cached }
            let points = CGSize(width: CGFloat(record.pixelWidth) / record.scale,
                                height: CGFloat(record.pixelHeight) / record.scale)
            let layout = ItemImageSizing.layout(contentPoints: points, requestedHeight: height)
            let image = Self.render(mask ?? self.image, canvas: layout.canvas, content: layout.content)
            image.isTemplate = isTemplate
            sized[height] = image
            return image
        }

        /// Draws into a 2× bitmap so the result is thread-safe and cheap to draw.
        private static func render(_ source: CGImage, canvas: CGSize, content: CGRect) -> NSImage {
            let scale: CGFloat = 2
            let width = max(1, Int((canvas.width * scale).rounded(.up))), height = max(1, Int((canvas.height * scale).rounded(.up)))
            let image = NSImage(size: canvas)
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
            context.interpolationQuality = .high
            context.draw(source, in: CGRect(x: content.minX * scale, y: content.minY * scale,
                                            width: content.width * scale, height: content.height * scale))
            if let cgImage = context.makeImage() {
                let rep = NSBitmapImageRep(cgImage: cgImage)
                rep.size = canvas
                image.addRepresentation(rep)
            }
            return image
        }
    }

    let directory: URL
    private(set) var index = CacheIndex()
    private var entries: [ItemImageKey: Entry] = [:]
    private var missing: Set<ItemImageKey> = []
    private let ioQueue = DispatchQueue(label: "com.alphapengwang.rolltop.capture-cache", qos: .utility)
    private var indexWriteScheduled = false
    private let limits: CachePruner.Limits
    private let log = Log.logger("capture")

    static var defaultDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches.appending(path: "com.alphapengwang.rolltop/items", directoryHint: .isDirectory)
    }

    init(directory: URL = ItemImageCache.defaultDirectory, limits: CachePruner.Limits = .init()) {
        self.directory = directory
        self.limits = limits
        if let data = try? Data(contentsOf: directory.appending(path: "index.json")),
           let decoded = try? JSONDecoder().decode(CacheIndex.self, from: data), decoded.version == 1 {
            index = decoded
        }
    }

    var count: Int { index.records.count }
    var totalBytes: Int { index.records.reduce(0) { $0 + $1.bytes } }

    func record(for key: ItemImageKey) -> CacheRecord? { index.records.first { $0.key == key } }

    /// The decoded image for `key`, loading it from disk on first use.
    func entry(for key: ItemImageKey) -> Entry? {
        if let entry = entries[key] { return entry }
        guard !missing.contains(key), let record = record(for: key) else { return nil }
        let url = directory.appending(path: key.fileName)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            missing.insert(key)
            return nil
        }
        let entry = Self.makeEntry(record: record, image: image)
        entries[key] = entry
        return entry
    }

    private static func makeEntry(record: CacheRecord, image: CGImage) -> Entry {
        var mask: CGImage?
        if record.traits.isTemplateLike, let pixels = PixelBuffer(image: image) {
            mask = ImageAnalysis.templateMask(pixels, lightForeground: record.traits.lightForeground).makeImage()
        }
        return Entry(record: record, image: image, mask: mask)
    }

    /// Stores new captures (memory now, disk in the background). Returns the keys whose
    /// image changed.
    @discardableResult
    func store(_ items: [CapturedItem], now: Date = Date()) -> [ItemImageKey] {
        var changed: [ItemImageKey] = []
        var writes: [(URL, Data)] = []
        for item in items {
            guard let image = item.pixels.makeImage(),
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { continue }
            let record = CacheRecord(key: item.key, traits: item.traits, scale: Double(item.scale),
                                     pixelWidth: item.pixels.width, pixelHeight: item.pixels.height,
                                     capturedAt: now, bytes: png.count)
            if let old = entry(for: item.key), old.record.pixelWidth == record.pixelWidth,
               old.record.pixelHeight == record.pixelHeight, old.record.traits.isTemplateLike == record.traits.isTemplateLike,
               PixelBuffer(image: old.image) == item.pixels {
                continue   // unchanged
            }
            index.records.removeAll { $0.key == item.key }
            index.records.append(record)
            entries[item.key] = Self.makeEntry(record: record, image: image)
            missing.remove(item.key)
            changed.append(item.key)
            writes.append((directory.appending(path: item.key.fileName), png))
        }
        guard !changed.isEmpty else { return [] }
        let directory = directory
        let pending = writes
        ioQueue.async {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (url, data) in pending { try? data.write(to: url, options: .atomic) }
        }
        prune(now: now)
        scheduleIndexWrite()
        return changed
    }

    /// Records owners present in the bar now (for the 30-day pruning).
    func markSeen(_ owners: some Sequence<String>, now: Date = Date()) {
        var dirty = false
        for owner in owners {
            // Hour granularity is enough and keeps index writes rare.
            if let last = index.ownerLastSeen[owner], now.timeIntervalSince(last) < 3600 { continue }
            index.ownerLastSeen[owner] = now
            dirty = true
        }
        if dirty { scheduleIndexWrite() }
    }

    /// Drops what the pruning policy says; returns the removed keys.
    @discardableResult
    func prune(now: Date = Date()) -> Set<ItemImageKey> {
        let remove = CachePruner.keysToRemove(index, now: now, limits: limits)
        guard !remove.isEmpty else { return [] }
        index.records.removeAll { remove.contains($0.key) }
        let liveOwners = Set(index.records.map(\.key.owner))
        index.ownerLastSeen = index.ownerLastSeen.filter { liveOwners.contains($0.key) || now.timeIntervalSince($0.value) <= limits.maxAge }
        for key in remove { entries[key] = nil }
        let urls = remove.map { directory.appending(path: $0.fileName) }
        ioQueue.async { for url in urls { try? FileManager.default.removeItem(at: url) } }
        scheduleIndexWrite()
        log.info("pruned \(remove.count) cached item images")
        return remove
    }

    func removeAll() {
        index = CacheIndex()
        entries.removeAll()
        missing.removeAll()
        let directory = directory
        ioQueue.async { try? FileManager.default.removeItem(at: directory) }
    }

    /// Blocks until queued disk work is done (tests, quit).
    func flush() {
        if indexWriteScheduled { writeIndexNow() }
        ioQueue.sync {}
    }

    private func scheduleIndexWrite() {
        guard !indexWriteScheduled else { return }
        indexWriteScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            self?.writeIndexNow()
        }
    }

    private func writeIndexNow() {
        indexWriteScheduled = false
        guard let data = try? JSONEncoder().encode(index) else { return }
        let directory = directory
        ioQueue.async {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: directory.appending(path: "index.json"), options: .atomic)
        }
    }
}
