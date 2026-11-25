import Foundation
import RolltopCore
import Testing
@testable import Rolltop

/// The order table and allow list behind a fake: nothing here touches the real files.
private final class LayoutEditorFakeFiles: LayoutEditorFileReading, @unchecked Sendable {
    private let lock = NSLock()
    private var table: [String: Double]
    private var log: [String] = []
    private var writeLog: [[String: Double]] = []
    let preferencesDelay: Double
    let preferencesSucceeds: Bool

    init(table: [String: Double], preferencesDelay: Double = 0, preferencesSucceeds: Bool = true) {
        self.table = table
        self.preferencesDelay = preferencesDelay
        self.preferencesSucceeds = preferencesSucceeds
    }

    var calls: [String] { lock.withLock { log } }
    var writes: [[String: Double]] { lock.withLock { writeLog } }

    private func value() -> MenuBarFileRead {
        let current = lock.withLock { table }
        return .value(try! PropertyListSerialization.data(fromPropertyList: current, format: .binary, options: 0))
    }

    func readPreferences(_ file: MenuBarProtectedFile) -> MenuBarFileRead {
        lock.withLock { log.append("prefs") }
        if preferencesDelay > 0 { Thread.sleep(forTimeInterval: preferencesDelay) }
        return preferencesSucceeds ? value() : .noValue
    }

    func readFile(_ file: MenuBarProtectedFile) -> MenuBarFileRead {
        lock.withLock { log.append("file") }
        return .failed("NSCocoaErrorDomain 257")
    }

    func readBookmark(_ bookmark: Data, file: MenuBarProtectedFile) -> MenuBarFileRead { value() }

    func writeLayout(_ changes: [String: Double]) -> MenuBarFileWrite {
        lock.withLock {
            writeLog.append(changes)
            table.merge(changes) { $1 }
        }
        return .written
    }
}

@Suite struct LayoutEditorOrderTests {
    let table: [String: Double] = ["module:Clock": 0, "module:BentoBox-0": 133, "module:WiFi": 191,
                                   "status:com.example.a::Item-0": 300, "status:com.example.b::Item-0": 400]

    private func settings() -> SettingsStore {
        SettingsStore(defaults: UserDefaults(suiteName: "layout-editor-tests-\(UUID().uuidString)")!)
    }

    @Test func nothingIsReadBeforeTheUserAsked() async {
        let files = LayoutEditorFakeFiles(table: table)
        let access = LayoutEditorFileAccess(file: .layout, settings: settings(), reader: files)
        access.traceDirectory = nil
        #expect(access.consentStatus == .notAsked)
        #expect(await access.read() == nil)
        #expect(await access.write(["module:WiFi": 1]) != .written)
        #expect(files.calls.isEmpty)
    }

    @Test func aTimeoutCountsUntilALateAnswerAllows() async throws {
        let files = LayoutEditorFakeFiles(table: table, preferencesDelay: 0.4)
        let access = LayoutEditorFileAccess(file: .layout, settings: settings(), reader: files)
        access.traceDirectory = nil
        access.requestTimeout = .milliseconds(100)
        await access.request()
        #expect(access.state == .timedOut)
        #expect(access.consentStatus == .notAllowed)
        try await Task.sleep(for: .milliseconds(700))
        #expect(access.state == .allowedPreferences)
        #expect(access.consentStatus == .allowed)
    }

    @Test func aRefusalIsRecordedWhenBothReadsFail() async {
        let files = LayoutEditorFakeFiles(table: table, preferencesSucceeds: false)
        let access = LayoutEditorFileAccess(file: .layout, settings: settings(), reader: files)
        access.traceDirectory = nil
        await access.request()
        #expect(access.state == .refused)
        #expect(Set(files.calls) == ["prefs", "file"])
    }

    @Test func aWriteThatDoesNotLandIsRolledBack() async throws {
        let files = LayoutEditorFakeFiles(table: table)
        let store = settings()
        let order = LayoutEditorOrderModel(orderAccess: LayoutEditorFileAccess(file: .layout, settings: store, reader: files),
                                           allowListAccess: LayoutEditorFileAccess(file: .allowList, settings: store, reader: files))
        order.orderAccess.traceDirectory = nil
        await order.orderAccess.request()
        #expect(order.orderAccess.state == .allowedPreferences)
        let backups = FileManager.default.temporaryDirectory.appending(path: "layout-editor-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: backups) }
        order.backupDirectory = backups
        // List B never changes: b, a, Wi-Fi, Control Center, clock.
        let drawn: [OwnerID] = [.app("com.example.b"), .app("com.example.a"), .system(.wifi), .system(.controlCenter), .system(.clock)]
        order.drawnOrder = { [drawn] }
        order.nudge = { true }
        order.verifyWindow = .milliseconds(200)
        order.settleDelay = .zero

        let report = await order.move(.system(.wifi), before: .app("com.example.a"))
        #expect(report.landed == false)
        #expect(report.rolledBack)
        #expect(order.message != nil)
        #expect(files.writes.count == 2)
        #expect(files.writes.first?.keys.sorted() == ["module:WiFi"])
        #expect(files.writes.last == ["module:WiFi": 191])
        #expect(FileManager.default.fileExists(atPath: backups.appending(path: LayoutEditorOrderModel.backupName).path(percentEncoded: false)))
    }
}
