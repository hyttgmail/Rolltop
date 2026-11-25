import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Watches one pasteboard's change count on a light timer and reads new entries, after the
/// privacy rules allowed them. The pasteboard is injected: the general pasteboard in normal
/// use, a private named one in tests and Debug sessions. The same object is used to copy
/// clips back, so a test never touches the user's clipboard.
///
/// macOS 15.4+ asks the user before an app reads the *general* pasteboard programmatically
/// (`NSPasteboard.accessBehavior`, SDK header); named pasteboards are always readable.
/// Change count and types are read without asking; content only after the rules pass.
final class ShelfClipboardMonitor {
    struct Read {
        var content: ShelfPasteboardContent
        var frontmostBundleID: String?
    }

    enum Outcome {
        case read(Read)
        case skipped(ShelfClipSkipReason)
        /// Our own copy-back: nothing to read.
        case ownWrite
    }

    let pasteboard: NSPasteboard
    var interval: TimeInterval
    var ignoredApps: Set<String> = []
    var onOutcome: ((Outcome) -> Void)?
    private(set) var isRunning = false
    private var timer: Timer?
    private var lastChangeCount: Int
    private var ownChangeCount: Int?
    private let log = Log.logger("shelf")

    /// Longest edge of a stored image, pixels.
    static let maxImagePixels = 1600
    /// Image data larger than this is not recorded at all.
    static let maxImageSourceBytes = 40_000_000

    init(pasteboard: NSPasteboard, interval: TimeInterval = 0.5) {
        self.pasteboard = pasteboard
        self.interval = interval
        lastChangeCount = pasteboard.changeCount
    }

    var isGeneral: Bool { pasteboard.name == .general }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        // Only what is copied from now on is recorded.
        lastChangeCount = pasteboard.changeCount
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = interval / 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        log.info("clipboard monitor started on \(isGeneral ? "the general pasteboard" : "a private pasteboard") every \(interval) s")
    }

    func stop() {
        guard isRunning else { return }
        timer?.invalidate()
        timer = nil
        isRunning = false
        log.info("clipboard monitor stopped")
    }

    /// Checks the change count now (the timer calls this; Debug writes call it at once).
    func poll() {
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        if count == ownChangeCount {
            onOutcome?(.ownWrite)
            return
        }
        let types = (pasteboard.types ?? []).map(\.rawValue)
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let reason = ShelfClipRules.skipReason(types: types, frontmostBundleID: frontmost, ignoredApps: ignoredApps) {
            log.info("clipboard change skipped: \(reason.rawValue)")
            onOutcome?(.skipped(reason))
            return
        }
        let content = readContent(types: Set(types))
        if let declared = content.declaredSource, ignoredApps.contains(declared) {
            onOutcome?(.skipped(.ignoredApp))
            return
        }
        onOutcome?(.read(Read(content: content, frontmostBundleID: frontmost)))
    }

    private func readContent(types: Set<String>) -> ShelfPasteboardContent {
        var content = ShelfPasteboardContent()
        if types.contains(ShelfPasteboardTypes.fileURL) {
            let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            content.filePaths = urls.map { $0.path(percentEncoded: false) }
        }
        if content.filePaths.isEmpty {
            content.plainText = pasteboard.string(forType: .string)
            if types.contains(ShelfPasteboardTypes.rtf) { content.rtf = pasteboard.data(forType: .rtf) }
            if types.contains(ShelfPasteboardTypes.url) {
                content.url = pasteboard.string(forType: .URL)
                    ?? (pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL])?.first?.absoluteString
            }
            if content.plainText == nil, types.contains(ShelfPasteboardTypes.png) || types.contains(ShelfPasteboardTypes.tiff) {
                let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff)
                if let data, data.count <= Self.maxImageSourceBytes, let image = Self.cappedPNG(data, maxPixels: Self.maxImagePixels) {
                    content.image = image.data
                    content.imagePixelSize = image.size
                }
            }
        }
        if types.contains(ShelfPasteboardTypes.source) {
            content.declaredSource = pasteboard.string(forType: NSPasteboard.PasteboardType(ShelfPasteboardTypes.source))
        }
        return content
    }

    // MARK: Copy back

    /// Puts a clip back on the monitored pasteboard; the resulting change is not re-read.
    @discardableResult
    func write(_ clip: ShelfClip, image: Data?) -> Bool {
        pasteboard.clearContents()
        var ok = false
        switch clip.kind {
        case .text:
            ok = pasteboard.setString(clip.text ?? "", forType: .string)
        case .richText:
            let item = NSPasteboardItem()
            if let rtf = clip.rtf { item.setData(rtf, forType: .rtf) }
            item.setString(clip.text ?? "", forType: .string)
            ok = pasteboard.writeObjects([item])
        case .url:
            let item = NSPasteboardItem()
            if let url = clip.url { item.setString(url, forType: .URL) }
            item.setString(clip.text ?? clip.url ?? "", forType: .string)
            ok = pasteboard.writeObjects([item])
        case .files:
            let urls = (clip.filePaths ?? []).map { URL(filePath: $0) as NSURL }
            ok = pasteboard.writeObjects(urls)
        case .image:
            if let image {
                let item = NSPasteboardItem()
                item.setData(image, forType: .png)
                if let tiff = NSImage(data: image)?.tiffRepresentation { item.setData(tiff, forType: .tiff) }
                ok = pasteboard.writeObjects([item])
            }
        }
        ownChangeCount = pasteboard.changeCount
        lastChangeCount = ownChangeCount ?? lastChangeCount
        return ok
    }

    // MARK: Images

    /// PNG of the image, downscaled so the longest edge is at most `maxPixels`.
    nonisolated static func cappedPNG(_ data: Data, maxPixels: Int) -> (data: Data, size: CGSize)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (output as Data, CGSize(width: image.width, height: image.height))
    }
}
