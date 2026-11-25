import Foundation
import Observation
import RolltopCore

/// Where Rolltop stands with one of the two files. Persisted (transient) so a later launch
/// reads only after the user allowed it once.
nonisolated enum LayoutEditorAccessState: String, Codable, Sendable {
    case notAsked = "not-asked"
    /// The marker: set by the consent row's click before the first protected call. Found at
    /// launch (Rolltop quit while waiting), it counts as timed out.
    case asking
    /// Reads through cfprefsd work.
    case allowedPreferences = "allowed-preferences"
    /// Reading the file itself works (cfprefsd did not answer).
    case allowedFile = "allowed-file"
    case refused
    case timedOut = "timed-out"
    /// The user picked the file in an open panel; reads go through its bookmark.
    case chosenFile = "chosen-file"

    var canRead: Bool { self == .allowedPreferences || self == .allowedFile || self == .chosenFile }
}

/// The blocking calls behind one file (a fake in tests, an in-memory store under
/// `layout-editor.debug-inject`).
nonisolated protocol LayoutEditorFileReading: Sendable {
    func readPreferences(_ file: MenuBarProtectedFile) -> MenuBarFileRead
    func readFile(_ file: MenuBarProtectedFile) -> MenuBarFileRead
    func readBookmark(_ bookmark: Data, file: MenuBarProtectedFile) -> MenuBarFileRead
    func writeLayout(_ changes: [String: Double]) -> MenuBarFileWrite
}

nonisolated struct LayoutEditorSystemFiles: LayoutEditorFileReading {
    func readPreferences(_ file: MenuBarProtectedFile) -> MenuBarFileRead { MenuBarFileIO.readPreferences(file) }
    func readFile(_ file: MenuBarProtectedFile) -> MenuBarFileRead { MenuBarFileIO.readFile(at: file.url, key: file.key) }
    func readBookmark(_ bookmark: Data, file: MenuBarProtectedFile) -> MenuBarFileRead {
        MenuBarFileIO.readBookmark(bookmark, key: file.key)
    }
    func writeLayout(_ changes: [String: Double]) -> MenuBarFileWrite { MenuBarFileIO.writeLayout(changes) }
}

enum LayoutEditorAccessSettings {
    static func state(_ file: MenuBarProtectedFile) -> SettingsKey<String> {
        SettingsKey("rolltop.layout-editor.access-\(file.rawValue)", default: LayoutEditorAccessState.notAsked.rawValue)
    }

    static func bookmark(_ file: MenuBarProtectedFile) -> SettingsKey<Data> {
        SettingsKey("rolltop.layout-editor.bookmark-\(file.rawValue)", default: Data())
    }
}

/// One file's access: asks only from the consent row's click, records what macOS did, and
/// reads only once allowed. Every call runs off the main thread with a timeout.
@Observable
final class LayoutEditorFileAccess {
    let file: MenuBarProtectedFile
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored var reader: any LayoutEditorFileReading
    /// While `debug-inject` runs: the state shown instead of the persisted one (never stored).
    /// Observed, so views that read `canRead` follow an injection.
    var injectedState: LayoutEditorAccessState?
    /// How long `request()` waits for a person to answer a dialog.
    @ObservationIgnored var requestTimeout: Duration = .seconds(90)
    /// How long a read after access was allowed may take.
    @ObservationIgnored var readTimeout: Duration = .seconds(5)
    /// Bumped when the state changes, so views and the consent row refresh.
    private(set) var revision = 0
    private(set) var isAsking = false
    /// The last "Choose File…" outcome when it did not work, for the editor.
    private(set) var chooseProblem: String?

    init(file: MenuBarProtectedFile, settings: SettingsStore, reader: any LayoutEditorFileReading = LayoutEditorSystemFiles()) {
        self.file = file
        self.settings = settings
        self.reader = reader
        settings.markTransient(LayoutEditorAccessSettings.state(file))
        settings.markTransient(LayoutEditorAccessSettings.bookmark(file))
    }

    var state: LayoutEditorAccessState {
        _ = revision
        if let injectedState { return injectedState }
        let stored = LayoutEditorAccessState(rawValue: settings[LayoutEditorAccessSettings.state(file)]) ?? .notAsked
        // A marker without an outcome: Rolltop quit (or crashed) while waiting.
        if stored == .asking, !isAsking { return .timedOut }
        return stored
    }

    var canRead: Bool { state.canRead }

    private func setState(_ new: LayoutEditorAccessState) {
        settings[LayoutEditorAccessSettings.state(file)] = new.rawValue
        revision += 1
    }

    /// The consent row's status. Never touches the file.
    var consentStatus: ConsentStatus {
        if isAsking {
            return .cannotAskNow(String(localized: "Waiting for your answer in the macOS dialog…", table: "LayoutEditor"))
        }
        switch state {
        case .notAsked: return .notAsked
        case .allowedPreferences, .allowedFile, .chosenFile: return .allowed
        case .refused, .timedOut, .asking: return .notAllowed
        }
    }

    // MARK: Asking (only from the consent row's click)

    /// Sets the marker, then reads both ways at once (cfprefsd and the file itself), each
    /// on its own thread, waiting up to `requestTimeout` for the user to answer a dialog.
    /// Writes what each call returned, with timings, to the trace. A success that arrives
    /// after the timeout still allows access.
    func request() async {
        guard !isAsking else { return }
        isAsking = true
        setState(.asking)
        let started = Date()
        let reader = reader, file = file
        let latePreferences: @Sendable (MenuBarFileRead) -> Void = { [weak self] result in
            guard case .value = result else { return }
            Task { @MainActor in self?.acceptLate(result, as: .allowedPreferences) }
        }
        let lateFile: @Sendable (MenuBarFileRead) -> Void = { [weak self] result in
            guard result.succeeded else { return }
            Task { @MainActor in self?.acceptLate(result, as: .allowedFile) }
        }
        async let viaPreferences = Self.timed(timeout: requestTimeout, label: "prefs-\(file.rawValue)", late: latePreferences) {
            reader.readPreferences(file)
        }
        async let viaFile = Self.timed(timeout: requestTimeout, label: "file-\(file.rawValue)", late: lateFile) {
            reader.readFile(file)
        }
        let (prefs, plain) = await (viaPreferences, viaFile)
        let outcome = Self.decide(file: file, preferences: prefs.result, file: plain.result)
        isAsking = false
        setState(outcome)
        writeTrace(LayoutEditorAccessTrace(file: file.rawValue, action: "request", startedAt: started, outcome: outcome.rawValue, calls: [
            .init(call: "CFPreferencesCopyValue(path domain)", result: prefs.result?.name ?? "timed out", seconds: prefs.seconds),
            .init(call: "Data(contentsOf:)", result: plain.result?.name ?? "timed out", seconds: plain.seconds),
        ]))
    }

    /// The outcome of the two reads (nil = timed out). cfprefsd wins when both work, since
    /// writes go through it. For the allow list a read file without the key still counts.
    nonisolated static func decide(file: MenuBarProtectedFile, preferences: MenuBarFileRead?, file plain: MenuBarFileRead?) -> LayoutEditorAccessState {
        if case .value? = preferences { return .allowedPreferences }
        if let plain, plain.succeeded { return .allowedFile }
        if preferences == nil || plain == nil { return .timedOut }
        return .refused
    }

    private func acceptLate(_ result: MenuBarFileRead, as new: LayoutEditorAccessState) {
        guard !state.canRead || (new == .allowedPreferences && state == .allowedFile), !isAsking else { return }
        setState(new)
        writeTrace(LayoutEditorAccessTrace(file: file.rawValue, action: "late-success", startedAt: Date(), outcome: state.rawValue,
                                           calls: [.init(call: "late result", result: result.name, seconds: 0)]))
    }

    /// "Choose File…": an open panel at the file's folder; only that file is accepted; its
    /// bookmark is kept and read once to check that it works.
    func chooseFile() async {
        chooseProblem = nil
        let message = String(localized: "Choose “\(file.fileName)” to let Rolltop read it.", table: "LayoutEditor")
        let (url, choseOther) = await MenuBarFileIO.chooseFile(file, message: message)
        guard let url else {
            if choseOther {
                chooseProblem = String(localized: "That isn’t “\(file.fileName)”. Choose that file in the folder the panel opens.",
                                       table: "LayoutEditor")
            }
            revision += 1
            return
        }
        guard let bookmark = MenuBarFileIO.bookmark(for: url) else {
            chooseProblem = String(localized: "Rolltop couldn’t keep access to the file you chose.", table: "LayoutEditor")
            revision += 1
            return
        }
        settings[LayoutEditorAccessSettings.bookmark(file)] = bookmark
        let started = Date()
        let reader = reader, file = file
        let read = await Self.timed(timeout: readTimeout, label: "bookmark-\(file.rawValue)", late: nil) {
            reader.readBookmark(bookmark, file: file)
        }
        if let result = read.result, result.succeeded {
            setState(.chosenFile)
        } else {
            chooseProblem = String(localized: "Rolltop couldn’t read the file even after you chose it.", table: "LayoutEditor")
            revision += 1
        }
        writeTrace(LayoutEditorAccessTrace(file: file.rawValue, action: "choose-file", startedAt: started, outcome: state.rawValue,
                                           calls: [.init(call: "bookmark read", result: read.result?.name ?? "timed out", seconds: read.seconds)]))
    }

    // MARK: Reading (only once allowed)

    /// Reads the key the way that worked. Nil before access was allowed (nothing is
    /// touched) or when the read timed out.
    func read() async -> MenuBarFileRead? {
        let state = state
        guard state.canRead else { return nil }
        let reader = reader, file = file
        let bookmark = settings[LayoutEditorAccessSettings.bookmark(file)]
        return await Self.timed(timeout: readTimeout, label: "read-\(file.rawValue)", late: nil) {
            switch state {
            case .allowedPreferences: reader.readPreferences(file)
            case .chosenFile: reader.readBookmark(bookmark, file: file)
            default: reader.readFile(file)
            }
        }.result
    }

    /// Writes new weights (order table only), bounded.
    func write(_ changes: [String: Double]) async -> MenuBarFileWrite {
        guard file == .layout, state.canRead else { return .refused("no access") }
        let reader = reader
        return await MenuBarBoundedCall.run(timeout: readTimeout, label: "write-layout") { reader.writeLayout(changes) }
            ?? .refused("timed out")
    }

    nonisolated private static func timed(timeout: Duration, label: String, late: (@Sendable (MenuBarFileRead) -> Void)?,
                                          _ work: @escaping @Sendable () -> MenuBarFileRead) async -> (result: MenuBarFileRead?, seconds: Double) {
        let start = Date()
        let result = await MenuBarBoundedCall.run(timeout: timeout, label: label, work, late: late)
        return (result, Date().timeIntervalSince(start))
    }

    // MARK: Trace

    /// `~/Library/Application Support/Rolltop/debug/layout-editor-access-<file>.json`, also in
    /// Release: the only way to learn afterwards what macOS did.
    @ObservationIgnored var traceDirectory: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first?.appending(path: "Rolltop/debug", directoryHint: .isDirectory)

    private func writeTrace(_ trace: LayoutEditorAccessTrace) {
        guard let directory = traceDirectory, injectedState == nil else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? encoder.encode(trace).write(to: directory.appending(path: "layout-editor-access-\(file.rawValue).json"), options: .atomic)
    }
}

nonisolated struct LayoutEditorAccessTrace: Codable {
    struct Call: Codable {
        let call: String
        let result: String
        let seconds: Double
    }

    let file: String
    let action: String
    let startedAt: Date
    let outcome: String
    let calls: [Call]
}
