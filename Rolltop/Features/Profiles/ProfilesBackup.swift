import Foundation

/// Profiles in a Rolltop backup (`BackupParticipating`): every profile with its id, plus the
/// active marker. Profile files stay the Profiles feature's business.
final class ProfilesBackupParticipant: BackupParticipating {
    struct Payload: Codable {
        static let formatID = "com.alphapengwang.rolltop.profiles"
        var format = Payload.formatID
        var version = 1
        var activeProfileID: String?
        var profiles: [RolltopProfile]
    }

    private let controller: ProfilesController

    init(controller: ProfilesController) { self.controller = controller }

    var backupID: String { "profiles" }
    var backupTitle: String { String(localized: "Profiles", table: "Profiles") }
    var backupOwnedSettingsKeys: Set<String> { [] }

    func exportBackupData() throws -> Data {
        try ProfileFileStore.encoder().encode(Payload(activeProfileID: controller.activeProfileID, profiles: controller.all))
    }

    func backupSummary(for data: Data) throws -> String {
        let count = try decode(data).profiles.count
        return String(localized: "\(count) profiles", table: "Profiles")
    }

    func importBackupData(_ data: Data) throws {
        let payload = try decode(data)
        controller.replaceAll(with: ProfileFileStore.Snapshot(profiles: payload.profiles, activeProfileID: payload.activeProfileID))
    }

    func resetBackupData() throws {
        controller.replaceAll(with: ProfileFileStore.Snapshot(profiles: [], activeProfileID: nil))
    }

    private func decode(_ data: Data) throws -> Payload {
        guard let payload = try? ProfileFileStore.decoder().decode(Payload.self, from: data), payload.format == Payload.formatID else {
            throw ProfileFileError.notAProfile
        }
        return payload
    }
}
