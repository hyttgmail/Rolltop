#if DEBUG
import Foundation
import RolltopCore

/// Debug commands for the order table and the allow list. The two `debug-verify…`
/// commands run the real path and are for the main session after the user allowed access
/// (a Rolltop opened normally, not from a shell); they refuse otherwise. `debug-inject`
/// replaces both files with fixture data held in memory, so the editor can be seen and
/// driven without access; nothing then touches the real files.
enum LayoutEditorOrderDebug {
    static let fixtureA = OwnerID.app("com.alphapengwang.rolltop-fixture")
    static let fixtureB = OwnerID.app("com.alphapengwang.rolltop-fixture-b")

    static func commands(context: AppContext, order: LayoutEditorOrderModel) -> [Command] {
        [
            Command(id: "layout-editor.debug-verify-order", title: LocalizedStringResource("Verify Menu Bar Order Access", table: "LayoutEditor"),
                    symbol: "ladybug",
                    arguments: [CommandArgument(name: "phase", title: LocalizedStringResource("Phase", table: "LayoutEditor"),
                                                isRequired: true, allowedValues: ["read", "swap"])],
                    allowedFromURL: true) { invocation in
                try guardReal(context: context, access: order.orderAccess)
                if invocation.string("phase") == "swap" {
                    try DebugFiles.writeJSON(await swap(order: order), name: "layout-editor-verify-order-swap.json")
                } else {
                    try await verifyRead(order: order)
                }
            },
            Command(id: "layout-editor.debug-verify-turned-off", title: LocalizedStringResource("Verify Turned-Off Apps Access", table: "LayoutEditor"),
                    symbol: "ladybug", allowedFromURL: true) { _ in
                try guardReal(context: context, access: order.allowListAccess)
                try await verifyTurnedOff(order: order)
            },
            Command(id: "layout-editor.debug-inject", title: LocalizedStringResource("Inject Menu Bar Files", table: "LayoutEditor"),
                    symbol: "syringe",
                    arguments: [CommandArgument(name: "order", title: LocalizedStringResource("Order table", table: "LayoutEditor"), isRequired: false),
                                CommandArgument(name: "turned-off", title: LocalizedStringResource("Allow list", table: "LayoutEditor"), isRequired: false),
                                CommandArgument(name: "reset", title: LocalizedStringResource("Reset", table: "LayoutEditor"), isRequired: false)],
                    allowedFromURL: true) { invocation in
                try await inject(invocation, order: order)
            },
            Command(id: "layout-editor.debug-move", title: LocalizedStringResource("Move Item in Injected Order", table: "LayoutEditor"),
                    symbol: "arrow.left.arrow.right",
                    arguments: [CommandArgument(name: "owner", title: LocalizedStringResource("Item", table: "LayoutEditor"), isRequired: true),
                                CommandArgument(name: "before", title: LocalizedStringResource("Before", table: "LayoutEditor"), isRequired: false)],
                    allowedFromURL: true) { invocation in
                // Only over injected data: a live test must never write the real table.
                guard order.orderAccess.injectedState != nil else { throw CommandError.failed("only over injected data (layout-editor.debug-inject)") }
                guard let raw = invocation.string("owner"), let owner = OwnerID(stringValue: raw) else {
                    throw CommandError.invalidArgument("owner", invocation.string("owner") ?? "")
                }
                let before = invocation.string("before").flatMap(OwnerID.init(stringValue:))
                try DebugFiles.writeJSON(await order.move(owner, before: before), name: "layout-editor-move.json")
            },
        ]
    }

    /// The verify commands run only with access granted, over the real files, in a Rolltop
    /// opened through LaunchServices (a shell launch would attribute any prompt to the terminal).
    private static func guardReal(context: AppContext, access: LayoutEditorFileAccess) throws {
        guard access.injectedState == nil, access.canRead, context.launchInfo.launchedByLaunchServices else {
            throw CommandError.failed("needs access allowed on the consent row, real files, and a Rolltop opened normally (not from a shell)")
        }
    }

    private struct ReadSummary: Encodable {
        let phase = "read"
        let state: String
        let result: String
        let seconds: Double
        let keyCount: Int
        let fixtureWeights: [String: Double]
        let hasFixtureA: Bool
        let hasFixtureB: Bool
        let copy: String?
    }

    private static func verifyRead(order: LayoutEditorOrderModel) async throws {
        let start = Date()
        let read = await order.orderAccess.read()
        let seconds = Date().timeIntervalSince(start)
        let table = read.flatMap(LayoutEditorOrderModel.decodeTable) ?? [:]
        var copy: String?
        if case .value(let data)? = read {
            let url = DebugFiles.directory.appending(path: "layout-editor-verify-order.plist")
            try FileManager.default.createDirectory(at: DebugFiles.directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            copy = url.path(percentEncoded: false)
        }
        let fixtureKeys = MenuBarOrderKeys.keys(for: fixtureA, in: table) + MenuBarOrderKeys.keys(for: fixtureB, in: table)
        try DebugFiles.writeJSON(ReadSummary(
            state: order.orderAccess.state.rawValue, result: read?.name ?? "timed out", seconds: seconds, keyCount: table.count,
            fixtureWeights: table.filter { fixtureKeys.contains($0.key) },
            hasFixtureA: !MenuBarOrderKeys.keys(for: fixtureA, in: table).isEmpty,
            hasFixtureB: !MenuBarOrderKeys.keys(for: fixtureB, in: table).isEmpty, copy: copy),
            name: "layout-editor-verify-order.json")
    }

    private struct SwapReport: Encodable {
        let phase = "swap"
        var problem: String?
        var move: LayoutEditorMoveReport?
        var restore: String?
        var drawnAfterRestore: [String] = []
        var restoredOrderMatches: Bool?
    }

    /// Swaps the two fixtures with the real write path, checks list B, then puts their
    /// original weights back. Touches no other row (a plan that would is refused).
    private static func swap(order: LayoutEditorOrderModel) async -> SwapReport {
        var report = SwapReport()
        guard let display = (await order.drawnOrder()).first(where: { $0.contains(fixtureA) && $0.contains(fixtureB) }),
              let a = display.firstIndex(of: fixtureA), let b = display.firstIndex(of: fixtureB) else {
            report.problem = "both fixtures must be running and drawn on one display"
            return report
        }
        let (left, right) = a < b ? (fixtureA, fixtureB) : (fixtureB, fixtureA)
        let before = display.filter { $0 == fixtureA || $0 == fixtureB }
        // The right one jumps left of the left one.
        let fresh = await order.orderAccess.read()
        guard let table = fresh.flatMap(LayoutEditorOrderModel.decodeTable) else {
            report.problem = "table unreadable"
            return report
        }
        let keys = Set(MenuBarOrderKeys.keys(for: fixtureA, in: table) + MenuBarOrderKeys.keys(for: fixtureB, in: table))
        let move = await order.move(right, before: left, onlyKeys: keys)
        report.move = move
        guard move.write == "\(MenuBarFileWrite.written)", !move.rolledBack else { return report }
        report.restore = "\(await order.restore(move.previous))"
        try? await Task.sleep(for: .milliseconds(800))
        let after = (await order.drawnOrder()).first { $0.contains(fixtureA) } ?? []
        report.drawnAfterRestore = after.map(\.stringValue)
        report.restoredOrderMatches = after.filter { $0 == fixtureA || $0 == fixtureB } == before
        return report
    }

    private struct TurnedOffReport: Encodable {
        let state: String
        let result: String
        let seconds: Double
        /// Types and key names only.
        let rootType: String
        let entryShapes: [String]
        let allowedCount: Int
        let notAllowedCount: Int
        let skipped: Int
        let notAllowed: [String]
        let parser: String
    }

    private static func verifyTurnedOff(order: LayoutEditorOrderModel) async throws {
        let start = Date()
        let read = await order.allowListAccess.read()
        let seconds = Date().timeIntervalSince(start)
        var root: Any? = read?.object
        if let data = root as? Data {
            root = (try? PropertyListSerialization.propertyList(from: data, format: nil)) ?? data
        }
        let shapes = Array(((root as? [Any]) ?? []).prefix(6).map { MenuBarAllowListParser.describe($0) })
        let parsed = MenuBarAllowListParser.parse(read?.object)
        var allowed = 0, notAllowed = 0, skipped = 0
        var off: [String] = []
        var parser = ""
        switch parsed {
        case .entries(let entries, let count):
            allowed = entries.count { $0.isAllowed }
            notAllowed = entries.count { !$0.isAllowed }
            skipped = count
            off = MenuBarAllowListParser.turnedOff(entries)
            parser = "entries \(entries.count)"
        case .notRecognized(let found):
            parser = "not recognised: \(found)"
        }
        try DebugFiles.writeJSON(TurnedOffReport(
            state: order.allowListAccess.state.rawValue, result: read?.name ?? "timed out", seconds: seconds,
            rootType: MenuBarAllowListParser.describe(root, depth: 1), entryShapes: shapes, allowedCount: allowed,
            notAllowedCount: notAllowed, skipped: skipped, notAllowed: off, parser: parser),
            name: "layout-editor-verify-turned-off.json")
        await order.reload()
    }

    // MARK: Inject

    private static func inject(_ invocation: CommandInvocation, order: LayoutEditorOrderModel) async throws {
        let accesses = [order.orderAccess, order.allowListAccess]
        if invocation.string("reset") == "1" {
            for access in accesses {
                access.reader = LayoutEditorSystemFiles()
                access.injectedState = nil
            }
            order.inject(table: nil, allowList: nil)
            return
        }
        let files = LayoutEditorInjectedFiles()
        if let path = invocation.string("order") {
            files.layout = try JSONSerialization.jsonObject(with: Data(contentsOf: DebugFiles.inputURL(path))) as? [String: Any]
        }
        if let path = invocation.string("turned-off") {
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: DebugFiles.inputURL(path)))
            files.allowList = try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
        }
        order.orderAccess.reader = files
        order.orderAccess.injectedState = files.layout == nil ? .notAsked : .allowedPreferences
        order.allowListAccess.reader = files
        order.allowListAccess.injectedState = files.allowList == nil ? .notAsked : .allowedPreferences
        order.inject(table: nil, allowList: nil)
        await order.reload()
    }
}

/// Both files in memory (`layout-editor.debug-inject`). Writes change only this copy.
nonisolated final class LayoutEditorInjectedFiles: LayoutEditorFileReading, @unchecked Sendable {
    private let lock = NSLock()
    private var storedLayout: [String: Any]?
    private var storedAllowList: Data?

    var layout: [String: Any]? {
        get { lock.withLock { storedLayout } }
        set { lock.withLock { storedLayout = newValue } }
    }

    var allowList: Data? {
        get { lock.withLock { storedAllowList } }
        set { lock.withLock { storedAllowList = newValue } }
    }

    func readPreferences(_ file: MenuBarProtectedFile) -> MenuBarFileRead {
        let value: Any? = file == .layout ? layout : allowList
        guard let value, let data = try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0) else {
            return .noValue
        }
        return .value(data)
    }

    func readFile(_ file: MenuBarProtectedFile) -> MenuBarFileRead { readPreferences(file) }
    func readBookmark(_ bookmark: Data, file: MenuBarProtectedFile) -> MenuBarFileRead { readPreferences(file) }

    func writeLayout(_ changes: [String: Double]) -> MenuBarFileWrite {
        lock.withLock {
            guard var table = storedLayout else { return .refused("no injected table") }
            for (key, weight) in changes { table[key] = weight }
            storedLayout = table
            return .written
        }
    }
}
#endif
