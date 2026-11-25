import Foundation

/// Automation rules in a Rolltop backup (`BackupParticipating`). The rules live in the
/// settings key `rolltop.automations.rules`, which this participant owns, so the backup's
/// generic settings section leaves it out. Writing the key is the same path as a settings
/// import: the controller notices, replaces its rules and revokes every script approval.
/// Approvals (a file on this Mac) are never exported, and imported rules with a script
/// condition arrive turned off.
final class AutomationsBackupParticipant: BackupParticipating {
    struct Payload: Codable {
        static let formatID = "com.alphapengwang.rolltop.automations"
        var format = Payload.formatID
        var version = 1
        var rules: AutomationRuleList
    }

    private let settings: SettingsStore

    init(settings: SettingsStore) { self.settings = settings }

    var backupID: String { "automations" }
    var backupTitle: String { String(localized: "Automations", table: "Automations") }
    var backupOwnedSettingsKeys: Set<String> { [AutomationsSettings.rules.name] }

    func exportBackupData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Payload(rules: settings[AutomationsSettings.rules]))
    }

    func backupSummary(for data: Data) throws -> String {
        let rules = try decode(data).rules.rules
        let scripted = rules.filter { !$0.scriptConditions.isEmpty }.count
        let count = String(localized: "\(rules.count) automations", table: "Automations")
        return scripted == 0 ? count
            : String(localized: "\(count), \(scripted) with scripts (imported turned off)", table: "Automations")
    }

    func importBackupData(_ data: Data) throws {
        var list = try decode(data).rules
        for index in list.rules.indices where !list.rules[index].scriptConditions.isEmpty {
            list.rules[index].isEnabled = false
        }
        settings[AutomationsSettings.rules] = list
    }

    func resetBackupData() throws {
        settings[AutomationsSettings.rules] = AutomationRuleList()
    }

    private func decode(_ data: Data) throws -> Payload {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data), payload.format == Payload.formatID else {
            throw CommandError.failed(String(localized: "The backup’s automations are unreadable.", table: "Automations"))
        }
        return payload
    }
}
