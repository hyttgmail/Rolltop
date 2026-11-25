#if DEBUG
import Foundation
import RolltopCore

/// Files of Debug commands: JSON dumps go to `~/Library/Application Support/Rolltop/debug/`,
/// inputs (rules, profiles) come from absolute `.json` paths a live test passes.
enum DebugFiles {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Rolltop/debug", directoryHint: .isDirectory)
    }

    /// Writes `value` as pretty, key-sorted JSON (ISO 8601 dates) to `debug/<name>`.
    static func writeJSON(_ value: some Encodable, name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: directory.appending(path: name), options: .atomic)
    }

    /// An absolute path to a `.json` file passed as a command argument.
    static func inputURL(_ path: String) throws -> URL {
        guard path.hasPrefix("/"), path.hasSuffix(".json"), !path.contains("/../") else {
            throw CommandError.invalidArgument("path", path)
        }
        return URL(filePath: path)
    }
}

/// `debug.dump-state`: a JSON snapshot for live tests, written to
/// `~/Library/Application Support/Rolltop/debug/state.json`.
enum DebugState {
    struct Snapshot: Encodable {
        struct Activator: Encodable {
            let activeOwner: String?
            let lastOutcome: String?
        }

        struct Clock: Encodable {
            let sessionActive: Bool
            let sessionCount: Int
            let lastOutcome: String?
            let restoreMode: String
        }

        let writtenAt: Date
        let launch: LaunchInfo
        let presentation: String
        let concealShown: Bool
        let restrictionAvailable: Bool
        let restrictionHeld: Bool
        let applying: Bool
        let generation: Int
        let plannedAllowList: AllowList
        let appliedAllowList: AllowList
        let concealedPresentOwners: [String]
        let temporaryAllows: [String]
        let forcedVisible: [String: [String]]
        let suspensions: [String]
        let interactions: [String]
        let lastError: String?
        let lastErrorDate: Date?
        let permissions: [String: Bool]
        let layout: Layout
        let presentOwners: [String]
        let knownBundleIDCount: Int
        let catalogLastRefresh: Date?
        let catalogRefreshMilliseconds: Int
        let catalog: [CatalogEntry]
        let drawn: DrawnSnapshot
        let activator: Activator
        let clock: Clock
        let features: [String]
        let commands: [String]
    }

    static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "Rolltop/debug/state.json")
    }

    static func write(_ context: AppContext) throws {
        let engine = context.visibility
        let input = engine.currentInput()
        let snapshot = Snapshot(
            writtenAt: Date(),
            launch: context.launchInfo,
            presentation: engine.level.rawValue,
            concealShown: engine.concealShown,
            restrictionAvailable: engine.isAvailable,
            restrictionHeld: engine.isRestrictionHeld,
            applying: engine.isApplying,
            generation: engine.generation,
            plannedAllowList: engine.plannedAllowList,
            appliedAllowList: engine.appliedAllowList,
            concealedPresentOwners: AllowListPlanner.concealedPresentOwners(input).map(\.stringValue),
            temporaryAllows: engine.temporarilyAllowedOwners.map(\.stringValue).sorted(),
            forcedVisible: engine.forcedVisible.mapValues { $0.map(\.stringValue).sorted() },
            suspensions: engine.suspensions.values.sorted(),
            interactions: engine.interactions.values.sorted(),
            lastError: engine.lastError,
            lastErrorDate: engine.lastErrorDate,
            permissions: Dictionary(uniqueKeysWithValues: Permissions.Kind.allCases.map { ($0.rawValue, context.permissions.isGranted($0)) }),
            layout: context.layout.layout,
            presentOwners: context.catalog.presentOwners.map(\.stringValue).sorted(),
            knownBundleIDCount: context.catalog.knownBundleIDs.count,
            catalogLastRefresh: context.catalog.lastRefresh,
            catalogRefreshMilliseconds: Int(context.catalog.lastRefreshDuration * 1000),
            catalog: context.catalog.entries,
            drawn: context.catalog.drawn,
            activator: .init(activeOwner: context.activator.activeOwner?.stringValue, lastOutcome: context.activator.lastOutcome),
            clock: .init(sessionActive: context.clockBridge.isSessionActive, sessionCount: context.clockBridge.sessionCount,
                         lastOutcome: context.clockBridge.lastOutcome, restoreMode: context.clockBridge.restoreMode.rawValue),
            features: FeatureRegistry.all.map { $0.id.rawValue },
            commands: context.commands.commands.map(\.id.rawValue))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        Log.logger("debug").info("state written to \(url.path)")
    }
}
#endif
