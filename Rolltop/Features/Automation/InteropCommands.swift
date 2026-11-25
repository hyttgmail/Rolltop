import Foundation
import RolltopCore

/// The feature's commands. Backup commands take a path so scripts and tests can run them
/// without panels; they never run from links (`allowedFromURL: false`, and the link
/// policy refuses their tier).
enum InteropCommands {
    static func commands(context: AppContext, backups: InteropBackupController) -> [Command] {
        [
            Command(id: "interop.export-backup", title: LocalizedStringResource("Export Rolltop Backup", table: "Automation"),
                    symbol: "square.and.arrow.up",
                    arguments: [CommandArgument(name: "path", title: LocalizedStringResource("File", table: "Automation"))],
                    allowedFromURL: false,
                    effect: .destructive) { invocation in
                let url = try backupURL(try invocation.require("path"), mustExist: false)
                try await backups.export(to: url)
            },
            Command(id: "interop.import-backup", title: LocalizedStringResource("Import Rolltop Backup", table: "Automation"),
                    symbol: "square.and.arrow.down",
                    arguments: [CommandArgument(name: "path", title: LocalizedStringResource("File", table: "Automation")),
                                CommandArgument(name: "parts", title: LocalizedStringResource("Parts", table: "Automation"), isRequired: false)],
                    allowedFromURL: false,
                    effect: .destructive) { invocation in
                let url = try backupURL(try invocation.require("path"), mustExist: true)
                let file = try await backups.read(url)
                try await backups.importBackup(file, parts: parts(invocation.string("parts"), file: file))
            },
        ]
    }

    /// An absolute path to a `.rolltopbackup` (or `.json`) file, without `..` components.
    static func backupURL(_ path: String, mustExist: Bool) throws -> URL {
        let url = URL(filePath: path)
        guard path.hasPrefix("/"), !url.pathComponents.contains(".."),
              [InteropBackupFile.fileExtension, "json"].contains(url.pathExtension) else {
            throw CommandError.invalidArgument("path", path)
        }
        if mustExist, !FileManager.default.fileExists(atPath: path) { throw CommandError.invalidArgument("path", path) }
        return url
    }

    /// `settings,layout,profiles,automations`; empty or missing means everything in the file.
    static func parts(_ raw: String?, file: InteropBackupFile) -> Set<InteropBackupPart> {
        guard let raw, !raw.isEmpty else { return InteropBackupController.allParts(of: file) }
        return Set(raw.split(separator: ",").map { InteropBackupPart(id: $0.trimmingCharacters(in: .whitespaces)) })
    }
}
