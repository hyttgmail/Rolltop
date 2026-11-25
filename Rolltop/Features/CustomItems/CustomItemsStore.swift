import CryptoKit
import Foundation
import Observation
import RolltopCore

enum CustomItemsSettings {
    /// Spacers, groups and widgets (exported, imported, carried by profiles).
    static let model = SettingsKey<CustomItemsModel>("rolltop.custom-items.model", default: .empty)
    /// Script widgets the user allowed to run on this Mac: widget id → fingerprint of the
    /// command. Transient: never exported, imported or reset, so an imported or restored
    /// script widget starts disabled until the user enables it here.
    static let scriptApprovals = SettingsKey<[String: String]>("rolltop.custom-items.script-approvals", default: [:])
}

/// The model in settings plus this Mac's script approvals. Writes go through here; a
/// change made elsewhere (an import, a profile, a backup restore) is picked up through the
/// settings revision and revokes every script approval.
@Observable
final class CustomItemsStore {
    private(set) var model: CustomItemsModel
    private(set) var approvals: [String: String]
    /// Stored data exists but could not be read at all: nothing is written over it.
    private(set) var isReadOnly = false
    /// The item whose editor the settings pane should open (from an item's "Edit…").
    var pendingEditID: String?

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private var observer: ChangeObserver?
    @ObservationIgnored var onChange: (() -> Void)?
    private let log = Log.logger("custom-items")

    init(settings: SettingsStore) {
        self.settings = settings
        settings.markTransient(CustomItemsSettings.scriptApprovals)
        model = settings[CustomItemsSettings.model]
        approvals = settings[CustomItemsSettings.scriptApprovals]
        isReadOnly = Self.storedDataIsUnreadable(settings)
        if isReadOnly { log.error("stored custom items could not be read; leaving them untouched") }
        observer = ChangeObserver(track: { [weak self] in _ = self?.settings.revision }) { [weak self] in
            self?.reloadFromSettings()
        }
    }

    private static func storedDataIsUnreadable(_ settings: SettingsStore) -> Bool {
        guard let data = settings.defaults.data(forKey: CustomItemsSettings.model.name) else { return false }
        return (try? JSONDecoder().decode(CustomItemsModel.self, from: data)) == nil
    }

    /// Picks up a change made outside this store (internal for tests).
    func reloadFromSettings() {
        let stored = settings[CustomItemsSettings.model]
        let storedApprovals = settings[CustomItemsSettings.scriptApprovals]
        var changed = false
        if stored != model {
            log.notice("custom items changed outside this pane (import, profile or restore): script widgets need approval again")
            model = stored
            isReadOnly = Self.storedDataIsUnreadable(settings)
            if !approvals.isEmpty {
                approvals = [:]
                settings[CustomItemsSettings.scriptApprovals] = [:]
            }
            changed = true
        } else if storedApprovals != approvals {
            approvals = storedApprovals
            changed = true
        }
        if changed { onChange?() }
    }

    // MARK: Reading

    static func fingerprint(of command: String) -> String {
        SHA256.hash(data: Data(command.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func isApproved(_ widget: CustomItemWidget) -> Bool {
        widget.source != .script || approvals[widget.id] == Self.fingerprint(of: widget.scriptCommand)
    }

    /// Shown in the bar: enabled, and for scripts also approved on this Mac.
    func isActive(_ id: String) -> Bool {
        if let widget = model.widget(id) { return widget.isEnabled && isApproved(widget) && !widget.scriptCommand.isEmptyScript(for: widget.source) }
        return model.isEnabled(id) ?? false
    }

    // MARK: Writing

    func update(_ change: (inout CustomItemsModel) -> Void) {
        guard !isReadOnly else {
            log.error("custom items are read-only (unreadable stored data); change ignored")
            return
        }
        var next = model
        change(&next)
        guard next != model else { return }
        model = next
        settings[CustomItemsSettings.model] = next
        // Approvals of widgets that are gone or whose command changed lapse.
        let valid = approvals.filter { id, fingerprint in
            next.widget(id).map { $0.source == .script && Self.fingerprint(of: $0.scriptCommand) == fingerprint } ?? false
        }
        if valid != approvals { setApprovals(valid) }
        onChange?()
    }

    func replaceModel(_ model: CustomItemsModel) {
        update { $0 = model }
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        update { model in
            if let index = model.spacers.firstIndex(where: { $0.id == id }) { model.spacers[index].isEnabled = enabled }
            if let index = model.groups.firstIndex(where: { $0.id == id }) { model.groups[index].isEnabled = enabled }
            if let index = model.widgets.firstIndex(where: { $0.id == id }) { model.widgets[index].isEnabled = enabled }
        }
    }

    /// The user allowed this script widget to run on this Mac (from the settings pane,
    /// after a confirmation) and switched it on.
    func approveAndEnable(_ id: String) {
        guard let widget = model.widget(id), widget.source == .script else { return }
        var next = approvals
        next[id] = Self.fingerprint(of: widget.scriptCommand)
        setApprovals(next)
        if widget.isEnabled { onChange?() } else { setEnabled(id, true) }
    }

    func remove(_ id: String) {
        update { model in
            model.spacers.removeAll { $0.id == id }
            model.groups.removeAll { $0.id == id }
            model.widgets.removeAll { $0.id == id }
        }
    }

    func upsert(spacer: CustomItemSpacer) {
        update { model in
            if let index = model.spacers.firstIndex(where: { $0.id == spacer.id }) { model.spacers[index] = spacer } else { model.spacers.append(spacer) }
        }
    }

    func upsert(group: CustomItemGroup) {
        update { model in
            if let index = model.groups.firstIndex(where: { $0.id == group.id }) { model.groups[index] = group } else { model.groups.append(group) }
        }
    }

    func upsert(widget: CustomItemWidget) {
        update { model in
            if let index = model.widgets.firstIndex(where: { $0.id == widget.id }) { model.widgets[index] = widget } else { model.widgets.append(widget) }
        }
    }

    func move(_ kind: CustomItemKind, fromOffsets: IndexSet, toOffset: Int) {
        update { model in
            switch kind {
            case .spacer: model.spacers.move(fromOffsets: fromOffsets, toOffset: toOffset)
            case .group: model.groups.move(fromOffsets: fromOffsets, toOffset: toOffset)
            case .widget: model.widgets.move(fromOffsets: fromOffsets, toOffset: toOffset)
            }
        }
    }

    /// A fresh id that no item (readable or not) uses.
    func newID(_ kind: CustomItemKind) -> String {
        let unreadableIDs = model.unreadable.values.flatMap { $0.compactMap(\.id) }
        return CustomItemsIDs.next(for: kind, existing: model.allIDs.union(unreadableIDs))
    }

    private func setApprovals(_ next: [String: String]) {
        approvals = next
        settings[CustomItemsSettings.scriptApprovals] = next
    }

    #if DEBUG
    /// Live tests: stands in for the pane's confirmation click.
    func debugApprove(_ id: String) { approveAndEnable(id) }
    #endif
}

extension String {
    /// A script widget with no command has nothing to run.
    nonisolated fileprivate func isEmptyScript(for source: CustomItemWidgetSource) -> Bool {
        source == .script && trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
