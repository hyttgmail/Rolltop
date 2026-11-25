import AppKit
import Foundation
import Observation
import RolltopCore

/// An automatic backup on disk, for the Backup pane's list.
nonisolated struct InteropLocalBackup: Identifiable, Hashable, Sendable {
    let url: URL
    let createdAt: Date
    let reason: String
    var id: URL { url }
}

/// Exports, imports, restores and resets Rolltop's setup: the exportable settings, the
/// layout, and every `BackupParticipating` section (profiles, automation rules). Every
/// import, restore and reset first writes an automatic backup to
/// `~/Library/Application Support/Rolltop/Backups/` (newest ten kept).
@Observable
final class InteropBackupController {
    enum ResetScope: String, Sendable { case layout, everything }

    private(set) var localBackups: [InteropLocalBackup] = []
    /// Bumps after every import, restore and reset (the pane shows "Restored").
    private(set) var lastChange: Date?

    @ObservationIgnored private unowned let context: AppContext
    @ObservationIgnored let directory: URL
    @ObservationIgnored var now: () -> Date = Date.init
    @ObservationIgnored private let log = Log.logger("interop")

    static let keepCount = 10

    init(context: AppContext, directory: URL) {
        self.context = context
        self.directory = directory
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Rolltop/Backups", directoryHint: .isDirectory)
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
    }

    private var participants: [any BackupParticipating] { context.services[.backupParticipants].participants }

    /// Settings keys that are not part of the settings section: the layout and every
    /// participant-owned key.
    var reservedSettingsKeys: Set<String> {
        participants.reduce(into: [CoreSettings.layout.name]) { $0.formUnion($1.backupOwnedSettingsKeys) }
    }

    // MARK: Making a backup

    func snapshot(reason: String) throws -> InteropBackupFile {
        var sections: [String: InteropBackupSection] = [:]
        for participant in participants {
            let data = try participant.exportBackupData()
            let summary = (try? participant.backupSummary(for: data)) ?? ""
            sections[participant.backupID] = InteropBackupSection(title: participant.backupTitle, summary: summary, data: data)
        }
        return InteropBackupFile(createdAt: now(), appVersion: Self.appVersion, reason: reason,
                                 settings: InteropBackupMerge.settingsSection(from: context.settings.exportAll(), reserved: reservedSettingsKeys),
                                 layout: context.layout.layout, sections: sections)
    }

    func exportData(reason: String = "export") throws -> Data {
        try InteropBackupFile.encoder().encode(try snapshot(reason: reason))
    }

    func export(to url: URL) async throws {
        let data = try exportData()
        try await Self.write(data, to: url)
        log.notice("exported a backup (\(data.count) bytes)")
    }

    // MARK: Reading

    func read(_ url: URL) async throws -> InteropBackupFile {
        let data = try await Task.detached { try Data(contentsOf: url) }.value
        return try InteropBackupFile.read(data)
    }

    func preview(of file: InteropBackupFile) -> InteropBackupPreview {
        var parts: [InteropBackupPreview.Part] = []
        if !file.settings.isEmpty {
            parts.append(.init(part: .settings, title: String(localized: "Settings", table: "Automation"),
                               summary: String(localized: "\(file.settings.count) settings", table: "Automation"), isAvailable: true))
        }
        if let layout = file.layout {
            let hidden = layout.sections.values.filter { $0 != .shown }.count
            parts.append(.init(part: .layout, title: String(localized: "Menu bar layout", table: "Automation"),
                               summary: String(localized: "Placed: \(layout.sections.count), hidden: \(hidden)", table: "Automation"),
                               isAvailable: true))
        }
        for id in file.sections.keys.sorted() {
            guard let section = file.sections[id] else { continue }
            let participant = context.services[.backupParticipants].participant(id: id)
            var summary = section.summary
            if let participant, let data = try? section.payload(), let fresh = try? participant.backupSummary(for: data) {
                summary = fresh
            }
            parts.append(.init(part: .section(id), title: participant?.backupTitle ?? section.title, summary: summary,
                               isAvailable: participant != nil))
        }
        return InteropBackupPreview(createdAt: file.createdAt, appVersion: file.appVersion, version: file.version,
                                    isFromNewerVersion: file.version > InteropBackupFile.currentVersion, parts: parts,
                                    skippedSettings: file.skippedSettings)
    }

    // MARK: Importing

    /// Brings in the chosen parts. Every chosen section is checked first; then an automatic
    /// backup is written; then the parts are applied. If applying fails, the automatic
    /// backup is put back and the error is rethrown.
    func importBackup(_ file: InteropBackupFile, parts: Set<InteropBackupPart>, reason: String = "before-import") async throws {
        let parts = parts.filter { part in
            switch part {
            case .settings: true
            case .layout: file.layout != nil
            case .section(let id): file.sections[id] != nil && context.services[.backupParticipants].participant(id: id) != nil
            }
        }
        guard !parts.isEmpty else { throw InteropBackupError.nothingSelected }
        // 1. Validate every chosen section before anything changes.
        var payloads: [(any BackupParticipating, Data)] = []
        for case .section(let id) in parts.sorted() {
            guard let participant = context.services[.backupParticipants].participant(id: id), let section = file.sections[id] else { continue }
            do {
                let data = try section.payload()
                _ = try participant.backupSummary(for: data)
                payloads.append((participant, data))
            } catch {
                throw InteropBackupError.sectionFailed(participant.backupTitle, error.localizedDescription)
            }
        }
        // 2. Automatic backup of everything as it is now.
        let safety = try snapshot(reason: reason)
        try await saveLocalBackup(safety)
        // 3. Apply; on failure put the safety copy back.
        do {
            try apply(file, parts: parts, payloads: payloads)
        } catch {
            log.error("import failed, restoring the automatic backup: \(error.localizedDescription)")
            rollBack(to: safety)
            throw error
        }
        lastChange = now()
        log.notice("imported a backup: \(parts.map(\.id).sorted().joined(separator: ", "))")
    }

    static func allParts(of file: InteropBackupFile) -> Set<InteropBackupPart> {
        var parts: Set<InteropBackupPart> = [.settings]
        if file.layout != nil { parts.insert(.layout) }
        for id in file.sections.keys { parts.insert(.section(id)) }
        return parts
    }

    /// Puts every part of the automatic backup back, continuing past failures.
    private func rollBack(to safety: InteropBackupFile) {
        try? apply(safety, parts: [.settings, .layout], payloads: [])
        for (id, section) in safety.sections {
            guard let participant = context.services[.backupParticipants].participant(id: id), let data = try? section.payload() else { continue }
            do {
                try participant.importBackupData(data)
            } catch {
                log.error("rollback of \(id) failed: \(error.localizedDescription)")
            }
        }
    }

    private func apply(_ file: InteropBackupFile, parts: Set<InteropBackupPart>, payloads: [(any BackupParticipating, Data)]) throws {
        if parts.contains(.settings) {
            let imported = file.settings.compactMapValues(\.plist)
            let merged = InteropBackupMerge.settingsToWrite(imported: imported, current: context.settings.exportAll(),
                                                            reserved: reservedSettingsKeys)
            context.settings.replaceAll(with: merged)
        }
        if parts.contains(.layout), let layout = file.layout {
            context.layout.replace(with: layout)
        }
        for (participant, data) in payloads {
            do {
                try participant.importBackupData(data)
            } catch {
                throw InteropBackupError.sectionFailed(participant.backupTitle, error.localizedDescription)
            }
        }
    }

    /// Imports every part of a local backup.
    func restore(_ backup: InteropLocalBackup) async throws {
        let file = try await read(backup.url)
        try await importBackup(file, parts: Self.allParts(of: file), reason: "before-restore")
    }

    // MARK: Reset

    func reset(_ scope: ResetScope) async throws {
        try await saveLocalBackup(try snapshot(reason: "before-reset"))
        switch scope {
        case .layout:
            context.layout.replace(with: .empty)
        case .everything:
            for participant in participants { try participant.resetBackupData() }
            context.layout.replace(with: .empty)
            context.settings.replaceAll(with: [:])
            InteropSettings.reset(in: context.settings)
        }
        lastChange = now()
        log.notice("reset \(scope.rawValue)")
    }

    // MARK: Local backups

    func saveLocalBackup(_ file: InteropBackupFile) async throws {
        let data = try InteropBackupFile.encoder().encode(file)
        let base = "Rolltop \(Self.fileStamp(file.createdAt)) \(file.reason)"
        let directory = directory
        try await Task.detached {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var url = directory.appending(path: "\(base).\(InteropBackupFile.fileExtension)")
            var counter = 2
            while FileManager.default.fileExists(atPath: url.path) {
                url = directory.appending(path: "\(base) \(counter).\(InteropBackupFile.fileExtension)")
                counter += 1
            }
            try data.write(to: url, options: .withoutOverwriting)
        }.value
        await refreshLocalBackups(prune: true)
    }

    /// Reads the folder (off the main thread), removes all but the newest ten.
    func refreshLocalBackups(prune: Bool = false) async {
        let directory = directory
        let keep = Self.keepCount
        let list = await Task.detached { () -> [InteropLocalBackup] in
            let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            var found: [InteropLocalBackup] = []
            for url in urls where url.pathExtension == InteropBackupFile.fileExtension {
                guard let data = try? Data(contentsOf: url), let file = try? InteropBackupFile.read(data) else { continue }
                found.append(InteropLocalBackup(url: url, createdAt: file.createdAt, reason: file.reason))
            }
            if prune {
                let doomed = Set(InteropBackupMerge.backupsToPrune(found.map { ($0.url, $0.createdAt) }, keep: keep))
                for url in doomed { try? FileManager.default.removeItem(at: url) }
                found.removeAll { doomed.contains($0.url) }
            }
            return found.sorted { $0.createdAt > $1.createdAt }
        }.value
        if list != localBackups { localBackups = list }
    }

    func showInFinder(_ backup: InteropLocalBackup?) {
        if let backup {
            NSWorkspace.shared.activateFileViewerSelecting([backup.url])
        } else {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(directory)
        }
    }

    /// `2026-11-24 21.30.05` (file names cannot hold colons).
    nonisolated static func fileStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.string(from: date)
    }

    nonisolated static func write(_ data: Data, to url: URL) async throws {
        try await Task.detached { try data.write(to: url, options: .atomic) }.value
    }
}
