import Carbon.HIToolbox
import Foundation
import Observation
import RolltopCore

/// Keeps the registered global shortcuts in line with the commands and the user's choices,
/// and runs a command (with `source: .hotkey`) when its shortcut is pressed. Registered as
/// the `.hotkeyBindings` service.
@Observable
final class HotkeyController: HotkeyBindingProviding {
    private(set) var revision = 0
    /// Every action with a shortcut (registered or not).
    private(set) var bindings: [HotkeyAction: ResolvedBinding] = [:]
    /// Actions whose shortcut is not active, and why.
    private(set) var problems: [HotkeyAction: HotkeyProblem] = [:]
    private(set) var isRecording = false
    private(set) var lastFired: HotkeyAction?
    private(set) var lastError: String?

    /// The run started by the last press (tests await it).
    @ObservationIgnored private(set) var lastRun: Task<Void, Never>?

    @ObservationIgnored private let commands: CommandRegistry
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let registrar: HotkeyRegistering
    @ObservationIgnored private let systemCombos: () -> Set<KeyCombo>
    @ObservationIgnored private let itemName: (OwnerID) -> String
    @ObservationIgnored private var registered: [HotkeyAction: (id: UInt32, combo: KeyCombo)] = [:]
    @ObservationIgnored private var actionsByID: [UInt32: HotkeyAction] = [:]
    @ObservationIgnored private var nextID: UInt32 = 1
    @ObservationIgnored private var observer: ChangeObserver?
    @ObservationIgnored private var lastInputs: (overrides: [HotkeyOverride], defaults: [HotkeyAction: KeyCombo], commands: Set<CommandID>)?
    @ObservationIgnored private let log = Log.logger("hotkeys")

    init(commands: CommandRegistry, settings: SettingsStore, registrar: HotkeyRegistering,
         systemCombos: @escaping () -> Set<KeyCombo> = HotkeyController.enabledSystemCombos,
         itemName: @escaping (OwnerID) -> String = { $0.stringValue }) {
        self.commands = commands
        self.settings = settings
        self.registrar = registrar
        self.systemCombos = systemCombos
        self.itemName = itemName
    }

    func start() {
        registrar.onPress = { [weak self] id in self?.fire(id: id) }
        observer = ChangeObserver(track: { [weak self] in
            guard let self else { return }
            _ = self.commands.commands
            _ = self.settings[HotkeySettings.overrides]
        }) { [weak self] in
            self?.reload()
        }
        reload(force: true)
    }

    func stop() {
        observer?.cancel()
        unregisterAll()
    }

    // MARK: Resolution and registration

    var overrides: [HotkeyOverride] { settings[HotkeySettings.overrides] }

    /// Shortcuts declared by commands (argument-less actions).
    var defaults: [HotkeyAction: KeyCombo] {
        Dictionary(commands.commands.compactMap { command in command.defaultShortcut.map { (HotkeyAction(command.id), $0) } },
                   uniquingKeysWith: { first, _ in first })
    }

    func reload(force: Bool = false) {
        let overrides = overrides
        let defaults = defaults
        let ids = Set(commands.commands.map(\.id))
        if !force, let last = lastInputs, last.overrides == overrides, last.defaults == defaults, last.commands == ids { return }
        lastInputs = (overrides, defaults, ids)

        let resolved = HotkeyResolver.resolve(defaults: defaults, overrides: overrides)
        let plan = HotkeyResolver.plan(resolved)
        let system = systemCombos()
        var problems = plan.conflicts.mapValues { HotkeyProblem.conflict($0) }
        var desired: [HotkeyAction: KeyCombo] = [:]
        for (action, combo) in plan.active where ids.contains(action.command) {
            if system.contains(combo) {
                problems[action] = .reservedBySystem
            } else {
                desired[action] = combo
            }
        }
        apply(desired, problems: &problems)
        bindings = resolved
        self.problems = problems
        revision += 1
        log.info("\(registered.count) shortcuts registered, \(problems.count) not active")
    }

    private func apply(_ desired: [HotkeyAction: KeyCombo], problems: inout [HotkeyAction: HotkeyProblem]) {
        guard !isRecording else {
            unregisterAll()
            return
        }
        for (action, entry) in registered where desired[action] != entry.combo {
            registrar.unregister(id: entry.id)
            registered[action] = nil
            actionsByID[entry.id] = nil
        }
        for (action, combo) in desired.sorted(by: { $0.key < $1.key }) where registered[action] == nil {
            let id = nextID
            nextID += 1
            let status = registrar.register(combo, id: id)
            if status == noErr {
                registered[action] = (id, combo)
                actionsByID[id] = action
            } else {
                problems[action] = .registrationFailed(status)
                log.error("cannot register \(KeyComboFormatter.string(for: combo)) for \(action): \(status)")
            }
        }
    }

    private func unregisterAll() {
        for entry in registered.values { registrar.unregister(id: entry.id) }
        registered.removeAll()
        actionsByID.removeAll()
    }

    var registeredActions: [HotkeyAction: KeyCombo] { registered.mapValues(\.combo) }

    func id(for action: HotkeyAction) -> UInt32? { registered[action]?.id }

    // MARK: Pressing

    func fire(id: UInt32) {
        guard !isRecording, let action = actionsByID[id] else { return }
        lastFired = action
        log.info("shortcut for \(action)")
        let commands = commands
        lastRun = Task { [weak self] in
            do {
                try await commands.run(action.command, arguments: action.arguments, source: .hotkey)
            } catch {
                self?.log.error("\(action) failed: \(error.localizedDescription)")
                self?.lastError = error.localizedDescription
            }
        }
    }

    // MARK: HotkeyBindingProviding

    func shortcut(for command: CommandID, arguments: [String: String]) -> KeyCombo? {
        bindings[HotkeyAction(command, arguments: arguments)]?.combo
    }

    func setShortcut(_ combo: KeyCombo?, for command: CommandID, arguments: [String: String]) {
        let action = HotkeyAction(command, arguments: arguments)
        let defaultCombo = arguments.isEmpty ? commands.command(command)?.defaultShortcut : nil
        settings[HotkeySettings.overrides] = HotkeyResolver.setting(combo, for: action, defaultCombo: defaultCombo,
                                                                    keepEmptyRow: command == .activateItem, in: overrides)
        reload()
    }

    func problem(for command: CommandID, arguments: [String: String]) -> HotkeyProblem? {
        problems[HotkeyAction(command, arguments: arguments)]
    }

    func conflictingTitle(for combo: KeyCombo, excluding command: CommandID, arguments: [String: String]) -> String? {
        HotkeyResolver.owner(of: combo, excluding: HotkeyAction(command, arguments: arguments), in: bindings).map(title(for:))
    }

    func setRecording(_ recording: Bool) {
        guard recording != isRecording else { return }
        isRecording = recording
        log.debug(recording ? "recording: shortcuts suspended" : "recording ended")
        reload(force: true)
    }

    func displayString(for combo: KeyCombo) -> String { KeyComboFormatter.string(for: combo) }

    func title(for action: HotkeyAction) -> String {
        if action.command == .activateItem, let raw = action.arguments["owner"], let owner = OwnerID(stringValue: raw) {
            let name = itemName(owner)
            return action.arguments["button"] == ItemActivator.Button.right.rawValue
                ? String(localized: "Right-click \(name)", table: "Hotkeys")
                : String(localized: "Click \(name)", table: "Hotkeys")
        }
        return commands.command(action.command)?.localizedTitle ?? action.command.rawValue
    }

    // MARK: Per-item shortcuts

    /// `item.activate` rows the user added, in a stable order.
    var itemActions: [HotkeyAction] {
        overrides.map(\.action).filter { $0.command == .activateItem }.sorted { title(for: $0) < title(for: $1) }
    }

    static func itemAction(owner: OwnerID, button: ItemActivator.Button) -> HotkeyAction {
        HotkeyAction(.activateItem, arguments: ["owner": owner.stringValue, "button": button.rawValue])
    }

    /// Adds a per-item row without a shortcut yet (no-op if it exists).
    func addItemRow(_ action: HotkeyAction) {
        guard !overrides.contains(where: { $0.action == action }) else { return }
        settings[HotkeySettings.overrides] = overrides + [HotkeyOverride(action: action, combo: nil)]
        reload()
    }

    func removeRow(_ action: HotkeyAction) {
        settings[HotkeySettings.overrides] = overrides.filter { $0.action != action }
        reload()
    }

    // MARK: macOS shortcuts

    /// Enabled shortcuts from System Settings › Keyboard › Keyboard Shortcuts.
    nonisolated static func enabledSystemCombos() -> Set<KeyCombo> {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr,
              let entries = unmanaged?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return KeyComboRules.systemCombos(fromSymbolicHotKeys: entries)
    }
}
