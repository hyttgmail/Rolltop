import Foundation

/// One JSON file per profile plus `index.json` (order, active profile) in
/// `~/Library/Application Support/Rolltop/Profiles/`.
///
/// Loading is synchronous (a handful of small files, read once at launch). Saving runs on
/// a serial queue right after every change, so a kill (SIGTERM from a script) loses at
/// most the last few milliseconds; `flush()` waits for pending writes.
nonisolated final class ProfileFileStore: @unchecked Sendable {
    struct Snapshot: Equatable, Sendable {
        var profiles: [RolltopProfile]
        var activeProfileID: String?
    }

    let directory: URL
    private let queue = DispatchQueue(label: "com.alphapengwang.rolltop.profiles.files")
    /// Last bytes written per file name (queue only).
    private var written: [String: Data] = [:]
    private let log = Log.logger("profiles")

    init(directory: URL) {
        self.directory = directory
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Rolltop/Profiles", directoryHint: .isDirectory)
    }

    static let indexName = "index.json"

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Reads every profile file. Order: the index first, then files the index does not
    /// list (sorted by creation date). Unreadable files are skipped and logged; the
    /// file name is the profile's id.
    func load() -> Snapshot {
        queue.sync {
            let fileManager = FileManager.default
            let decoder = Self.decoder()
            var index = ProfileIndexFile()
            if let data = try? Data(contentsOf: directory.appending(path: Self.indexName)) {
                if let decoded = try? decoder.decode(ProfileIndexFile.self, from: data) {
                    index = decoded
                    written[Self.indexName] = data
                } else {
                    log.error("unreadable profile index; using file order")
                }
            }
            let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
            var byID: [String: RolltopProfile] = [:]
            for name in names where name.hasSuffix(".json") && name != Self.indexName {
                let id = String(name.dropLast(".json".count))
                guard ProfileNaming.isValidID(id) else { continue }
                guard let data = try? Data(contentsOf: directory.appending(path: name)),
                      var profile = try? decoder.decode(RolltopProfile.self, from: data) else {
                    log.error("skipping unreadable profile file \(name)")
                    continue
                }
                profile.id = id
                if profile.name.trimmingCharacters(in: .whitespaces).isEmpty { profile.name = id }
                byID[id] = profile
                written[name] = data
            }
            var ordered: [RolltopProfile] = []
            for id in index.order {
                if let profile = byID.removeValue(forKey: id) { ordered.append(profile) }
            }
            ordered += byID.values.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
            // Keep "apply at launch" unique even if files were edited by hand.
            var seenLaunch = false
            for index in ordered.indices where ordered[index].applyAtLaunch {
                if seenLaunch { ordered[index].applyAtLaunch = false }
                seenLaunch = true
            }
            let active = index.activeProfileID.flatMap { id in ordered.contains { $0.id == id } ? id : nil }
            return Snapshot(profiles: ordered, activeProfileID: active)
        }
    }

    /// Writes what changed: changed profile files, the index, and removes files of
    /// profiles that are gone.
    func save(_ snapshot: Snapshot) {
        queue.async { [self] in
            write(snapshot)
        }
    }

    /// Waits until every queued write is done.
    func flush() {
        queue.sync {}
    }

    private func write(_ snapshot: Snapshot) {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            log.error("cannot create the profiles folder: \(error.localizedDescription)")
            return
        }
        let encoder = Self.encoder()
        var keep: Set<String> = [Self.indexName]
        for profile in snapshot.profiles where ProfileNaming.isValidID(profile.id) {
            let name = profile.id + ".json"
            keep.insert(name)
            guard let data = try? encoder.encode(profile) else { continue }
            if written[name] == data { continue }
            do {
                try data.write(to: directory.appending(path: name), options: .atomic)
                written[name] = data
            } catch {
                log.error("cannot write profile \(profile.id): \(error.localizedDescription)")
            }
        }
        let index = ProfileIndexFile(order: snapshot.profiles.map(\.id), activeProfileID: snapshot.activeProfileID)
        if let data = try? encoder.encode(index), written[Self.indexName] != data {
            do {
                try data.write(to: directory.appending(path: Self.indexName), options: .atomic)
                written[Self.indexName] = data
            } catch {
                log.error("cannot write the profile index: \(error.localizedDescription)")
            }
        }
        for name in written.keys where !keep.contains(name) {
            try? fileManager.removeItem(at: directory.appending(path: name))
            written[name] = nil
        }
    }
}
