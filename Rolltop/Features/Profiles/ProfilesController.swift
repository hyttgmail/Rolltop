import Foundation
import Observation
import RolltopCore

/// Settings keys of the Profiles feature.
enum ProfilesSettings {
    /// Contribute the first five profiles to Rolltop's status menu.
    static let showInStatusMenu = SettingsKey<Bool>("rolltop.profiles.show-in-menu", default: true)
}

/// Owns the profiles: list, active profile, persistence, applying, and automatic
/// switching at launch and on display changes. Registered as `.profiles`.
@Observable
final class ProfilesController: ProfileApplying, ProfileLayoutRestoring {
    /// In the user's order.
    private(set) var all: [RolltopProfile] = []
    private(set) var activeProfileID: String?
    /// Why the active profile was last applied, for the pane ("at launch", "displays changed").
    private(set) var lastApplyReason: ApplyReason?
    private(set) var lastApplyDate: Date?

    enum ApplyReason: String, Sendable {
        case user, launch, displays, automation, command
    }

    @ObservationIgnored let store: ProfileFileStore
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let layoutStore: LayoutStore
    @ObservationIgnored private let now: () -> Date
    /// Called after the list (ids, names, order, symbols) or the active profile changed.
    @ObservationIgnored var onListChange: (() -> Void)?
    @ObservationIgnored private let log = Log.logger("profiles")

    init(settings: SettingsStore, layout: LayoutStore, store: ProfileFileStore, now: @escaping () -> Date = Date.init) {
        self.settings = settings
        self.layoutStore = layout
        self.store = store
        self.now = now
    }

    func load() {
        let snapshot = store.load()
        all = snapshot.profiles
        activeProfileID = snapshot.activeProfileID
        log.info("loaded \(all.count) profiles")
        onListChange?()
    }

    // MARK: Queries

    var profiles: [ProfileSummary] {
        all.map { ProfileSummary(id: $0.id, name: $0.name, symbol: $0.symbol) }
    }

    func profile(id: String) -> RolltopProfile? { all.first { $0.id == id } }

    var activeProfile: RolltopProfile? { activeProfileID.flatMap(profile(id:)) }

    /// The active profile differs from the current layout or its included settings.
    var isActiveModified: Bool {
        guard let profile = activeProfile else { return false }
        return isModified(profile)
    }

    func isModified(_ profile: RolltopProfile) -> Bool {
        if layoutStore.layout != profile.layout { return true }
        guard !profile.settingsPrefixes.isEmpty else { return false }
        _ = settings.revision
        return !ProfileSettingsSnapshot.matches(current: settings.exportAll(), snapshot: profile.settings,
                                                prefixes: profile.settingsPrefixes)
    }

    // MARK: Applying

    func applyProfile(id: String) throws {
        try applyProfile(id: id, reason: .command)
    }

    func applyProfile(id: String, reason: ApplyReason) throws {
        guard let profile = profile(id: id) else { throw ProfileFileError.unknownProfile(id) }
        apply(profile, reason: reason)
    }

    /// Replaces the layout atomically, writes the profile's included settings, and makes
    /// it the active profile.
    private func apply(_ profile: RolltopProfile, reason: ApplyReason) {
        layoutStore.replace(with: profile.layout)
        if !profile.settingsPrefixes.isEmpty {
            writeSettings(profile.settings, prefixes: profile.settingsPrefixes)
        }
        activeProfileID = profile.id
        lastApplyReason = reason
        lastApplyDate = now()
        persist()
        onListChange?()
        log.info("applied profile \(profile.id) (\(reason.rawValue))")
    }

    func restoreLayout(_ layout: Layout, activeProfileID id: String?) {
        layoutStore.replace(with: layout)
        activeProfileID = id.flatMap { profile(id: $0) == nil ? nil : $0 }
        lastApplyReason = .automation
        lastApplyDate = now()
        persist()
        onListChange?()
    }

    /// Applies the profile `step` places after the active one (wrapping).
    func applyNeighbor(step: Int) throws {
        guard let id = ProfileNaming.neighbor(of: activeProfileID, in: all.map(\.id), step: step) else {
            throw CommandError.failed(String(localized: "There are no profiles.", table: "Profiles"))
        }
        try applyProfile(id: id, reason: .command)
    }

    /// Re-applies the active profile, discarding changes made since.
    func revertActive() {
        guard let profile = activeProfile else { return }
        apply(profile, reason: .user)
    }

    // MARK: Automatic switching

    /// At launch a profile whose display rule matches wins (unless it is already active,
    /// so edits from the last session survive); otherwise the "apply at launch" profile is
    /// applied. Returns the id applied.
    @discardableResult
    func applyAtLaunch(configuration: ProfileDisplayConfiguration) -> String? {
        if let match = ProfileDisplayRule.bestMatch(in: all, for: configuration) {
            if match.id != activeProfileID { apply(match, reason: .displays) }
            return match.id
        }
        if let launch = all.first(where: \.applyAtLaunch) {
            apply(launch, reason: .launch)
            return launch.id
        }
        return nil
    }

    /// The set of displays changed: apply the best matching profile unless it is already
    /// active. When nothing matches, leave things as they are.
    @discardableResult
    func displayConfigurationChanged(_ configuration: ProfileDisplayConfiguration) -> String? {
        guard let match = ProfileDisplayRule.bestMatch(in: all, for: configuration) else { return nil }
        guard match.id != activeProfileID else { return nil }
        apply(match, reason: .displays)
        return match.id
    }

    // MARK: Editing

    /// Saves the current layout (and the chosen settings groups) as a new profile and
    /// makes it active. The name is made unique.
    @discardableResult
    func saveCurrent(name: String, symbol: String = RolltopProfile.defaultSymbol,
                     including groups: [ProfileSettingsGroup] = []) -> RolltopProfile {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? String(localized: "Profile", table: "Profiles") : trimmed
        let finalName = ProfileNaming.uniqueName(base, existing: all.map(\.name))
        let id = ProfileNaming.makeID(for: finalName, existing: Set(all.map(\.id)))
        let prefixes = groups.map(\.prefix)
        let date = now()
        let profile = RolltopProfile(id: id, name: finalName, symbol: symbol, layout: layoutStore.layout,
                                  settingsPrefixes: prefixes,
                                  settings: ProfileSettingsSnapshot.capture(from: settings.exportAll(), prefixes: prefixes),
                                  createdAt: date, updatedAt: date)
        all.append(profile)
        activeProfileID = id
        lastApplyReason = .user
        lastApplyDate = date
        persist()
        onListChange?()
        log.info("saved profile \(id)")
        return profile
    }

    /// Replaces the editable fields of a profile (name, symbol, included groups, apply at
    /// launch, display rule). Newly included groups capture the current values.
    func update(_ edited: RolltopProfile) {
        guard let index = all.firstIndex(where: { $0.id == edited.id }) else { return }
        var profile = all[index]
        let others = all.filter { $0.id != edited.id }.map(\.name)
        let trimmed = edited.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { profile.name = ProfileNaming.uniqueName(trimmed, existing: others) }
        profile.symbol = edited.symbol.isEmpty ? RolltopProfile.defaultSymbol : edited.symbol
        let added = edited.settingsPrefixes.filter { !profile.settingsPrefixes.contains($0) }
        let removed = profile.settingsPrefixes.filter { !edited.settingsPrefixes.contains($0) }
        if !added.isEmpty {
            profile.settings.merge(ProfileSettingsSnapshot.capture(from: settings.exportAll(), prefixes: added)) { _, new in new }
        }
        if !removed.isEmpty {
            profile.settings = profile.settings.filter { key, _ in !removed.contains(where: key.hasPrefix) }
        }
        profile.settingsPrefixes = edited.settingsPrefixes
        profile.displayRule = edited.displayRule
        profile.applyAtLaunch = edited.applyAtLaunch
        profile.updatedAt = now()
        all[index] = profile
        if profile.applyAtLaunch {
            for other in all.indices where other != index { all[other].applyAtLaunch = false }
        }
        persist()
        onListChange?()
    }

    func rename(id: String, to name: String) {
        guard var profile = profile(id: id) else { return }
        profile.name = name
        update(profile)
    }

    func setSymbol(id: String, to symbol: String) {
        guard var profile = profile(id: id) else { return }
        profile.symbol = symbol
        update(profile)
    }

    func setApplyAtLaunch(id: String, _ on: Bool) {
        guard var profile = profile(id: id) else { return }
        profile.applyAtLaunch = on
        update(profile)
    }

    func setIncluded(_ group: ProfileSettingsGroup, _ on: Bool, id: String) {
        guard var profile = profile(id: id) else { return }
        profile.settingsPrefixes.removeAll { $0 == group.prefix }
        if on { profile.settingsPrefixes.append(group.prefix) }
        update(profile)
    }

    /// Stores the current layout and included settings in the profile.
    func updateFromCurrent(id: String) {
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        all[index].layout = layoutStore.layout
        all[index].settings = ProfileSettingsSnapshot.capture(from: settings.exportAll(), prefixes: all[index].settingsPrefixes)
        all[index].updatedAt = now()
        persist()
        onListChange?()
    }

    @discardableResult
    func duplicate(id: String) -> RolltopProfile? {
        guard let index = all.firstIndex(where: { $0.id == id }) else { return nil }
        var copy = all[index]
        copy.name = ProfileNaming.uniqueName(String(localized: "\(copy.name) copy", table: "Profiles"), existing: all.map(\.name))
        copy.id = ProfileNaming.makeID(for: copy.name, existing: Set(all.map(\.id)))
        copy.applyAtLaunch = false
        copy.createdAt = now()
        copy.updatedAt = copy.createdAt
        all.insert(copy, at: index + 1)
        persist()
        onListChange?()
        return copy
    }

    func delete(id: String) {
        guard all.contains(where: { $0.id == id }) else { return }
        all.removeAll { $0.id == id }
        if activeProfileID == id { activeProfileID = nil }
        persist()
        onListChange?()
        log.info("deleted profile \(id)")
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        all.move(fromOffsets: source, toOffset: destination)
        persist()
        onListChange?()
    }

    /// Moves a profile one place up (`-1`) or down (`+1`).
    func move(id: String, by offset: Int) {
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard all.indices.contains(target) else { return }
        all.swapAt(index, target)
        persist()
        onListChange?()
    }

    // MARK: Export and import

    func exportData(id: String) throws -> Data {
        guard let profile = profile(id: id) else { throw ProfileFileError.unknownProfile(id) }
        return try ProfileFileStore.encoder().encode(ProfileExportFile(profile: profile))
    }

    /// Adds the profile in `data` under a fresh id and a unique name. "Apply at launch"
    /// is cleared; the file's id is never used as a file name.
    @discardableResult
    func importData(_ data: Data) throws -> RolltopProfile {
        let decoder = ProfileFileStore.decoder()
        var profile: RolltopProfile
        if let file = try? decoder.decode(ProfileExportFile.self, from: data), file.format == ProfileExportFile.formatID {
            profile = file.profile
        } else {
            throw ProfileFileError.notAProfile
        }
        let trimmed = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.name = ProfileNaming.uniqueName(trimmed.isEmpty ? String(localized: "Imported profile", table: "Profiles") : trimmed,
                                                existing: all.map(\.name))
        profile.id = ProfileNaming.makeID(for: profile.name, existing: Set(all.map(\.id)))
        profile.applyAtLaunch = false
        profile.updatedAt = now()
        all.append(profile)
        persist()
        onListChange?()
        log.info("imported profile \(profile.id)")
        return profile
    }

    /// Replaces every profile and the active marker, keeping ids (backup import, restore,
    /// "Reset everything"). Does not apply a profile: the backup restores the layout itself.
    func replaceAll(with snapshot: ProfileFileStore.Snapshot) {
        var seenLaunch = false
        var seenIDs: Set<String> = []
        all = snapshot.profiles.filter { ProfileNaming.isValidID($0.id) && seenIDs.insert($0.id).inserted }.map { profile in
            var profile = profile
            if profile.applyAtLaunch { profile.applyAtLaunch = !seenLaunch; seenLaunch = true }
            return profile
        }
        activeProfileID = snapshot.activeProfileID.flatMap { id in all.contains { $0.id == id } ? id : nil }
        persist()
        onListChange?()
        log.info("replaced all profiles (\(all.count))")
    }

    // MARK: Private

    private func persist() {
        store.save(ProfileFileStore.Snapshot(profiles: all, activeProfileID: activeProfileID))
    }

    /// Makes the keys under `prefixes` hold exactly `snapshot`, key by key; nothing outside
    /// the prefixes is touched (unlike `replaceAll`, which rewrites every key).
    private func writeSettings(_ snapshot: [String: ProfileSettingValue], prefixes: [String]) {
        let changes = ProfileSettingsSnapshot.changes(currentKeys: settings.exportAll().keys, snapshot: snapshot, prefixes: prefixes)
        let defaults = settings.defaults
        for key in changes.remove { defaults.removeObject(forKey: key) }
        for (key, value) in changes.set { defaults.set(value.plistObject, forKey: key) }
    }
}
