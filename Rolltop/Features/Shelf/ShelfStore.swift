import Foundation

/// On-disk storage of the shelf: only on this Mac, under Application Support, readable by
/// the owner only (directory 0700, files 0600), excluded from Time Machine.
///
///     <root>/clipboard.json          clipboard history
///     <root>/clipboard-images/*.png  images of image clips (size-capped)
///     <root>/files.json              file shelf references (paths + bookmarks)
///
/// Writes run on a serial queue; `flush()` waits for them.
nonisolated final class ShelfStore: @unchecked Sendable {
    let root: URL
    private let queue = DispatchQueue(label: "com.alphapengwang.rolltop.shelf.store", qos: .utility)
    private let log = Log.logger("shelf")

    /// `~/Library/Application Support/Rolltop/Shelf`.
    static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Rolltop/Shelf", directoryHint: .isDirectory)
    }

    init(root: URL) {
        self.root = root
    }

    var clipboardURL: URL { root.appending(path: "clipboard.json") }
    var imagesURL: URL { root.appending(path: "clipboard-images", directoryHint: .isDirectory) }
    var filesURL: URL { root.appending(path: "files.json") }

    func imageURL(_ name: String) -> URL { imagesURL.appending(path: name) }

    private struct ClipFile: Codable {
        var version = 1
        var clips: [ShelfClip]
    }

    private struct FilesFile: Codable {
        var version = 1
        var items: [ShelfFileItem]
    }

    // MARK: Reading (synchronous, small files)

    func loadClips() -> [ShelfClip] {
        guard let data = try? Data(contentsOf: clipboardURL) else { return [] }
        do { return try Self.decoder.decode(ClipFile.self, from: data).clips } catch {
            log.error("clipboard history unreadable, starting empty: \(error.localizedDescription)")
            return []
        }
    }

    func loadFiles() -> [ShelfFileItem] {
        guard let data = try? Data(contentsOf: filesURL) else { return [] }
        do { return try Self.decoder.decode(FilesFile.self, from: data).items } catch {
            log.error("file shelf unreadable, starting empty: \(error.localizedDescription)")
            return []
        }
    }

    var hasStoredData: Bool { FileManager.default.fileExists(atPath: root.path(percentEncoded: false)) }

    // MARK: Writing (queued)

    func saveClips(_ clips: [ShelfClip]) {
        guard let data = try? Self.encoder.encode(ClipFile(clips: clips)) else { return }
        let url = clipboardURL
        let root = root
        queue.async { [log] in
            do {
                try Self.prepareDirectory(root)
                try Self.writeProtected(data, to: url)
            } catch { log.error("saving clipboard history failed: \(error.localizedDescription)") }
        }
    }

    func saveImage(_ data: Data, name: String) {
        let url = imageURL(name)
        let root = root
        let images = imagesURL
        queue.async { [log] in
            do {
                try Self.prepareDirectory(root)
                try Self.prepareDirectory(images)
                try Self.writeProtected(data, to: url)
            } catch { log.error("saving a clipboard image failed: \(error.localizedDescription)") }
        }
    }

    func deleteImages(_ names: [String]) {
        guard !names.isEmpty else { return }
        let urls = names.map(imageURL)
        queue.async {
            for url in urls { try? FileManager.default.removeItem(at: url) }
        }
    }

    func saveFiles(_ items: [ShelfFileItem]) {
        guard let data = try? Self.encoder.encode(FilesFile(items: items)) else { return }
        let url = filesURL
        let root = root
        queue.async { [log] in
            do {
                try Self.prepareDirectory(root)
                try Self.writeProtected(data, to: url)
            } catch { log.error("saving the file shelf failed: \(error.localizedDescription)") }
        }
    }

    /// Deletes the clipboard history and its images; removes the folder when nothing is left.
    func wipeClipboard() {
        let urls = [clipboardURL, imagesURL]
        queue.async { [self] in
            for url in urls { try? FileManager.default.removeItem(at: url) }
            removeRootIfEmpty()
        }
    }

    /// Forgets the file shelf (references only: the files themselves are never touched).
    func wipeFiles() {
        let url = filesURL
        queue.async { [self] in
            try? FileManager.default.removeItem(at: url)
            removeRootIfEmpty()
        }
    }

    /// Waits for queued writes.
    func flush() { queue.sync {} }

    private func removeRootIfEmpty() {
        let path = root.path(percentEncoded: false)
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: path), contents.isEmpty {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    // MARK: Protection

    /// Creates the folder if needed, owner-only, excluded from backups.
    static func prepareDirectory(_ url: URL) throws {
        let fileManager = FileManager.default
        let path = url.path(percentEncoded: false)
        if !fileManager.fileExists(atPath: path) {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try? mutable.setResourceValues(values)
    }

    /// Atomic write, then owner read/write only (the atomic rename replaces the file, so the
    /// mode is applied after every write; the 0700 folder covers the moment in between).
    static func writeProtected(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path(percentEncoded: false))
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
