import Foundation

/// Spacers, groups and widgets in a Rolltop backup (`BackupParticipating`). The items live in
/// the settings key `rolltop.custom-items.model`, which this participant owns, so the
/// backup's settings section leaves it out. Script approvals (this Mac's trust decisions)
/// are never exported, and imported script widgets arrive turned off: the user turns each
/// on again in Settings › Custom Items, which asks first.
final class CustomItemsBackupParticipant: BackupParticipating {
    struct Payload: Codable {
        static let formatID = "com.alphapengwang.rolltop.custom-items"
        var format = Payload.formatID
        var version = 1
        var model: CustomItemsModel
    }

    private let settings: SettingsStore

    init(settings: SettingsStore) { self.settings = settings }

    var backupID: String { "custom-items" }
    var backupTitle: String { String(localized: "Custom Items", table: "CustomItems") }
    var backupOwnedSettingsKeys: Set<String> { [CustomItemsSettings.model.name] }

    func exportBackupData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Payload(model: settings[CustomItemsSettings.model]))
    }

    func backupSummary(for data: Data) throws -> String {
        let model = try decode(data).model
        let count = model.spacers.count + model.groups.count + model.widgets.count
        let scripts = model.widgets.filter { $0.source == .script }.count
        let items = String(localized: "\(count) items", table: "CustomItems")
        guard scripts > 0 else { return items }
        let turnedOff = String(localized: "\(scripts) script widgets arrive turned off", table: "CustomItems")
        return String(localized: "\(items), \(turnedOff)", table: "CustomItems",
                      comment: "A backup's custom items: their count, then the script widgets note")
    }

    func importBackupData(_ data: Data) throws {
        settings[CustomItemsSettings.model] = Self.turningScriptsOff(try decode(data).model)
    }

    func resetBackupData() throws {
        settings.reset(CustomItemsSettings.model)
    }

    /// Script widgets arrive turned off (their approvals stay on the Mac that gave them).
    static func turningScriptsOff(_ model: CustomItemsModel) -> CustomItemsModel {
        var model = model
        for index in model.widgets.indices where model.widgets[index].source == .script {
            model.widgets[index].isEnabled = false
        }
        return model
    }

    private func decode(_ data: Data) throws -> Payload {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data), payload.format == Payload.formatID else {
            throw CommandError.failed(String(localized: "The custom items in the backup can’t be read.", table: "CustomItems"))
        }
        return payload
    }
}
