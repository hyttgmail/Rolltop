import AppKit
import Foundation
import Testing
@testable import Rolltop

/// A temporary folder outside the user's home; removed by the test.
private func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "RolltopShelfTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func mode(_ url: URL) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)))?[.posixPermissions] as? Int
}

@Suite(.serialized) struct ShelfStoreTests {
    @Test func writesOwnerOnlyAndRoundTrips() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ShelfStore(root: folder.appending(path: "Shelf", directoryHint: .isDirectory))
        let clip = ShelfClip(id: UUID(), kind: .text, text: "hello", firstCopied: Date(timeIntervalSince1970: 1_800_000_000),
                             lastCopied: Date(timeIntervalSince1970: 1_800_000_000), fingerprint: "f")
        store.saveClips([clip])
        store.saveImage(Data([1, 2, 3]), name: "a.png")
        store.saveFiles([ShelfFileItem(id: UUID(), path: "/tmp/x", bookmark: nil, isDirectory: false, addedAt: Date())])
        store.flush()
        #expect(mode(store.root) == 0o700)
        #expect(mode(store.clipboardURL) == 0o600)
        #expect(mode(store.imageURL("a.png")) == 0o600)
        #expect(mode(store.filesURL) == 0o600)
        #expect(store.loadClips() == [clip])
        #expect(store.loadFiles().map(\.path) == ["/tmp/x"])

        // Rewriting keeps the mode (atomic writes replace the file).
        store.saveClips([clip, clip])
        store.flush()
        #expect(mode(store.clipboardURL) == 0o600)

        store.wipeClipboard()
        store.wipeFiles()
        store.flush()
        #expect(!FileManager.default.fileExists(atPath: store.root.path(percentEncoded: false)))
    }
}

/// Minimal dragging info for the drop handler.
private final class FakeDrag: NSObject, NSDraggingInfo {
    let pasteboard: NSPasteboard
    init(pasteboard: NSPasteboard) { self.pasteboard = pasteboard }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { [.copy, .link, .generic] }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

@Suite(.serialized) struct ShelfControllerTests {
    @Test func everySectionOffRunsNothingAndStoresNothing() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let context = try TestContext.make()
        let controller = ShelfController(context: context, storageRoot: folder.appending(path: "Shelf"))
        controller.start()
        defer { controller.stop() }
        #expect(controller.config.enabledSections.isEmpty)
        #expect(controller.runningActivities.isEmpty)
        // Turning on hover alone (no section) still runs nothing.
        context.settings[ShelfSettings.openOnHover] = true
        controller.reconcile()
        #expect(controller.runningActivities.isEmpty)
    }

    @Test func clipboardOnAPrivatePasteboardRecordsAndTurningItOffDeletesTheHistory() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let name = "com.alphapengwang.rolltop.tests.shelf.\(UUID().uuidString)"
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(name))
        defer { pasteboard.releaseGlobally() }
        let context = try TestContext.make()
        let controller = ShelfController(context: context, storageRoot: folder.appending(path: "Shelf"))
        controller.debug.pasteboardName = name
        controller.debug.pollInterval = 60
        controller.debug.clipboardEnabled = true
        controller.start()
        defer { controller.stop() }
        #expect(controller.runningActivities == [.clipboardMonitor])

        for value in ["one", "two", "one", "https://example.com/x"] {
            pasteboard.clearContents()
            pasteboard.setString(value, forType: .string)
            controller.debugPollNow()
        }
        #expect(controller.history.clips.map(\.preview) == ["https://example.com/x", "one", "two"])
        #expect(controller.history.clips.first?.kind == .url)

        controller.pause(minutes: 5)
        #expect(controller.runningActivities == [.clipboardResumeTimer])
        controller.resume()
        #expect(controller.runningActivities == [.clipboardMonitor])

        controller.debug.clipboardEnabled = false
        controller.reconcile()
        #expect(controller.history.clips.isEmpty)
        #expect(controller.runningActivities.isEmpty)
    }

    @Test func dropsAddFilesAndMissingFilesShowAsMissing() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fileA = folder.appending(path: "a.txt")
        let fileB = folder.appending(path: "b.txt")
        try Data("a".utf8).write(to: fileA)
        try Data("b".utf8).write(to: fileB)
        let context = try TestContext.make()
        let controller = ShelfController(context: context, storageRoot: folder.appending(path: "Shelf"))
        controller.debug.filesEnabled = true
        controller.debug.openOnDrag = false
        controller.start()
        defer { controller.stop() }

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.alphapengwang.rolltop.tests.drag.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([fileA as NSURL, fileB as NSURL, URL(string: "https://example.com")! as NSURL])
        let view = ShelfDropView(controller: controller)
        let drag = FakeDrag(pasteboard: pasteboard)
        #expect(view.draggingEntered(drag) == .link)   // a reference: never .move
        #expect(controller.isDropTargeted)
        #expect(view.performDragOperation(drag))
        #expect(controller.files.items.map(\.name).sorted() == ["a.txt", "b.txt"])
        #expect(controller.filePresence.values.allSatisfy { $0 == .present })

        try FileManager.default.removeItem(at: fileB)
        controller.refreshPresence()
        let missing = controller.files.items.filter { controller.filePresence[$0.id] == .missing }.map(\.name)
        #expect(missing == ["b.txt"])

        // Dragging out removes the item only when the option is on and the drop was accepted.
        let a = try #require(controller.files.items.first { $0.name == "a.txt" })
        controller.dragOutEnded(a.id, accepted: true)
        #expect(controller.files.items.count == 2)
        context.settings[ShelfSettings.filesRemoveAfterDrag] = true
        controller.dragOutEnded(a.id, accepted: false)
        #expect(controller.files.items.count == 2)
        controller.dragOutEnded(a.id, accepted: true)
        #expect(controller.files.items.map(\.name) == ["b.txt"])
    }

    @Test func filesExpireOnTheirTimer() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "soon.txt")
        try Data("x".utf8).write(to: file)
        let context = try TestContext.make()
        let controller = ShelfController(context: context, storageRoot: folder.appending(path: "Shelf"))
        controller.debug.filesEnabled = true
        controller.debug.openOnDrag = false
        controller.debug.fileLifetime = .some(0.3)
        controller.start()
        defer { controller.stop() }
        controller.addFiles([file])
        #expect(controller.runningActivities == [.fileExpiryTimer])
        try await Task.sleep(for: .milliseconds(900))
        #expect(controller.files.items.isEmpty)
        #expect(controller.runningActivities.isEmpty)
    }

    @Test func noCalendarPromptWithoutAClick() throws {
        let context = try TestContext.make()
        let controller = ShelfController(context: context, storageRoot: FileManager.default.temporaryDirectory.appending(path: "unused-\(UUID())"))
        controller.debug.upNextEnabled = true
        controller.debug.eventSource = ShelfSampleEventSource(access: .notDetermined, samples: ShelfSampleEventSource.sampleEvents(now: Date()))
        controller.refreshEvents()
        #expect(controller.calendarAccess == .notDetermined)
        #expect(controller.upNext.isEmpty)
        controller.debug.eventSource = ShelfSampleEventSource(access: .granted, samples: ShelfSampleEventSource.sampleEvents(now: Date()))
        controller.refreshEvents()
        #expect(!controller.upNext.timed.isEmpty)
        #expect(controller.upNext.timed.contains { $0.meetingLink?.service == .zoom })
    }

    @Test func paletteRowsUseOpaqueIDsAndNeedAQuery() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let name = "com.alphapengwang.rolltop.tests.shelf.\(UUID().uuidString)"
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(name))
        defer { pasteboard.releaseGlobally() }
        let context = try TestContext.make()
        let controller = ShelfController(context: context, storageRoot: folder.appending(path: "Shelf"))
        controller.debug.pasteboardName = name
        controller.debug.pollInterval = 60
        controller.debug.clipboardEnabled = true
        controller.start()
        defer { controller.stop() }
        pasteboard.clearContents()
        pasteboard.setString("secret-free sample", forType: .string)
        controller.debugPollNow()
        #expect(ShelfPaletteRows.rows(controller: controller, query: "").isEmpty)
        let rows = ShelfPaletteRows.rows(controller: controller, query: "sample")
        #expect(rows.count == 1)
        #expect(rows.first?.id == controller.history.clips.first?.id.uuidString)
        #expect(rows.first?.id.contains("sample") == false)
    }
}

@Suite(.serialized) struct ShelfPaletteProviderTests {
    @Test func registersWithThePaletteAndAnswersOnlyWhileHistoryIsOn() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "RolltopShelfTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let name = "com.alphapengwang.rolltop.tests.shelf.\(UUID().uuidString)"
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(name))
        defer { pasteboard.releaseGlobally() }
        let context = try TestContext.make()
        let controller = ShelfController(context: context, storageRoot: folder)
        ShelfPaletteRows.register(controller: controller, context: context)
        let provider = try #require(context.services[.paletteResultProviders].providers.first { $0.id == "shelf.clipboard" })
        #expect(provider.results(for: "anything").isEmpty)

        controller.debug.pasteboardName = name
        controller.debug.pollInterval = 60
        controller.debug.clipboardEnabled = true
        controller.start()
        defer { controller.stop() }
        pasteboard.clearContents()
        pasteboard.setString("palette sample", forType: .string)
        controller.debugPollNow()
        let rows = provider.results(for: "palette")
        #expect(rows.map(\.title) == ["palette sample"])
        #expect(provider.results(for: "").isEmpty)
    }
}

@Suite(.serialized) struct ShelfDebugResetTests {
    /// A Debug reset never wipes the user's folder; it wipes only a Debug storage folder.
    @Test func debugResetLeavesTheUsersDataAlone() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "RolltopShelfTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let userFolder = folder.appending(path: "User", directoryHint: .isDirectory)
        let debugFolder = folder.appending(path: "Debug", directoryHint: .isDirectory)
        let name = "com.alphapengwang.rolltop.tests.shelf.\(UUID().uuidString)"
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(name))
        defer { pasteboard.releaseGlobally() }
        let context = try TestContext.make()
        // The user has clipboard history on, with one clip stored.
        context.settings[ShelfSettings.clipboardEnabled] = true
        let userStore = ShelfStore(root: userFolder)
        userStore.saveClips([ShelfClip(id: UUID(), kind: .text, text: "mine", firstCopied: Date(), lastCopied: Date(), fingerprint: "m")])
        userStore.flush()
        let controller = ShelfController(context: context, storageRoot: userFolder)
        controller.start()
        defer { controller.stop() }
        #expect(controller.history.clips.map(\.text) == ["mine"])

        controller.debug.pasteboardName = name
        controller.debugWipeAndReset()
        controller.reconcile()
        #expect(controller.history.clips.map(\.text) == ["mine"])
        #expect(!userStore.loadClips().isEmpty)

        // A Debug folder session is wiped by the reset, and the user's data comes back.
        controller.debugSetStorageRoot(debugFolder)
        controller.debug.pasteboardName = name
        controller.debug.pollInterval = 60
        controller.debugRebindPasteboard()
        pasteboard.clearContents()
        pasteboard.setString("test clip", forType: .string)
        controller.debugPollNow()
        #expect(controller.history.clips.map(\.text) == ["test clip"])
        controller.debugWipeAndReset()
        ShelfStore(root: debugFolder).flush()
        #expect(!FileManager.default.fileExists(atPath: debugFolder.appending(path: "clipboard.json").path(percentEncoded: false)))
        #expect(controller.history.clips.map(\.text) == ["mine"])
        #expect(userStore.loadClips().map(\.text) == ["mine"])
    }
}
