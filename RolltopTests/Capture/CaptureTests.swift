import CoreGraphics
import Foundation
import RolltopCore
import Testing
@testable import Rolltop

/// Builds RGBA premultiplied buffers for tests.
private func buffer(width: Int, height: Int, fill: (Int, Int) -> (r: Double, g: Double, b: Double, a: Double)?) -> PixelBuffer {
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            guard let c = fill(x, y) else { continue }
            let i = (y * width + x) * 4
            bytes[i] = UInt8((c.r * c.a * 255).rounded())
            bytes[i + 1] = UInt8((c.g * c.a * 255).rounded())
            bytes[i + 2] = UInt8((c.b * c.a * 255).rounded())
            bytes[i + 3] = UInt8((c.a * 255).rounded())
        }
    }
    return PixelBuffer(width: width, height: height, bytes: bytes)
}

@Suite struct CaptureGeometryTests {
    @Test func cropRectScalesPointsToPixels() {
        // Main display bar: window 2304×30 pt captured at 4608×60 px.
        let rect = CaptureGeometry.cropRect(slot: CGRect(x: 1638, y: 0, width: 32, height: 30),
                                            captureFrame: CGRect(x: 0, y: 0, width: 2304, height: 30),
                                            imageSize: CGSize(width: 4608, height: 60))
        #expect(rect == CGRect(x: 3276, y: 0, width: 64, height: 60))
    }

    @Test func cropRectOnASecondDisplayAboveTheMainOne() {
        // Built-in display at (2304, -37) in global top-left points, bar 33 pt.
        let rect = CaptureGeometry.cropRect(slot: CGRect(x: 3366, y: -37, width: 32, height: 33),
                                            captureFrame: CGRect(x: 2304, y: -37, width: 1728, height: 33),
                                            imageSize: CGSize(width: 3456, height: 66))
        #expect(rect == CGRect(x: 2124, y: 0, width: 64, height: 66))
    }

    @Test func cropRectNormalisesFramesReportedInPixels() {
        // Some builds report the window frame in pixels: the image/frame ratio is then 1.
        let rect = CaptureGeometry.cropRect(slot: CGRect(x: 100, y: 0, width: 30, height: 24),
                                            captureFrame: CGRect(x: 0, y: 0, width: 1000, height: 24),
                                            imageSize: CGSize(width: 1000, height: 24))
        #expect(rect == CGRect(x: 100, y: 0, width: 30, height: 24))
        #expect(CaptureGeometry.cropRect(slot: CGRect(x: 5000, y: 0, width: 30, height: 24),
                                         captureFrame: CGRect(x: 0, y: 0, width: 1000, height: 24),
                                         imageSize: CGSize(width: 2000, height: 48)) == nil)
    }

    @Test func itemIndicesFollowListAOrder() {
        // List A order is not left to right: item 0 is drawn rightmost.
        #expect(CaptureGeometry.itemIndices(slotMinXs: [100, 140, 180], listAMinXs: [180, 100, 140]) == [1, 2, 0])
        // Counts differ (stale list A): number left to right.
        #expect(CaptureGeometry.itemIndices(slotMinXs: [140, 100], listAMinXs: [10]) == [1, 0])
    }

    @Test func slotsSkipOverflowedManagedAndOwnItems() {
        let slots = [
            DrawnSlotRecord(displayID: 4, frame: CGRect(x: 100, y: 0, width: 30, height: 30), ownerPID: 1, ownerBundleID: "com.a", axIdentifier: nil),
            DrawnSlotRecord(displayID: 4, frame: CGRect(x: 130, y: 0, width: 30, height: 30), ownerPID: 1, ownerBundleID: "com.a", axIdentifier: nil),
            DrawnSlotRecord(displayID: 4, frame: CGRect(x: 160, y: 0, width: 30, height: 30), ownerPID: 2, ownerBundleID: "com.alphapengwang.rolltop", axIdentifier: nil),
            DrawnSlotRecord(displayID: 4, frame: CGRect(x: 190, y: 0, width: 20, height: 30), ownerPID: 3, ownerBundleID: nil, axIdentifier: "com.apple.menuextra.airdrop"),
            DrawnSlotRecord(displayID: 4, frame: CGRect(x: 210, y: 0, width: 20, height: 30), ownerPID: 3, ownerBundleID: nil, axIdentifier: "com.apple.menuextra.wifi"),
            DrawnSlotRecord(displayID: 4, frame: CGRect(x: 500, y: 0, width: 20, height: 30), ownerPID: 4, ownerBundleID: "com.over", axIdentifier: nil, isOverflowed: true),
        ]
        let snapshot = DrawnSnapshot(displays: [DisplayBarRecord(displayID: 4, isMain: true, barFrame: CGRect(x: 0, y: 0, width: 2304, height: 30),
                                                                 chevronFrame: nil, chevronExpanded: false, slots: slots)],
                                     capturedAt: Date(), isReadable: true)
        let result = CaptureGeometry.slots(in: snapshot, ownBundleIDs: ["com.alphapengwang.rolltop"],
                                           listAFrames: [.app("com.a"): [CGRect(x: 130, y: 0, width: 30, height: 30), CGRect(x: 100, y: 0, width: 30, height: 30)]])
        #expect(result.map(\.key.description) == ["com.a#1", "com.a#0", "system:wifi#0"])
    }

    @Test func signatureIgnoresReadTimeAndSubpointJitter() {
        let a = [CaptureSlot(key: ItemImageKey(ownerString: "com.a", index: 0), displayID: 4, frame: CGRect(x: 100.2, y: 0, width: 30, height: 30))]
        let b = [CaptureSlot(key: ItemImageKey(ownerString: "com.a", index: 0), displayID: 4, frame: CGRect(x: 99.9, y: 0, width: 30, height: 30))]
        let moved = [CaptureSlot(key: ItemImageKey(ownerString: "com.a", index: 0), displayID: 4, frame: CGRect(x: 130, y: 0, width: 30, height: 30))]
        #expect(CaptureGeometry.signature(of: a) == CaptureGeometry.signature(of: b))
        #expect(CaptureGeometry.signature(of: a) != CaptureGeometry.signature(of: moved))
    }

    @Test func sameLayoutToleratesJitterButNotMoves() {
        func slot(_ x: CGFloat, _ owner: String = "system:clock") -> CaptureSlot {
            CaptureSlot(key: ItemImageKey(ownerString: owner, index: 0), displayID: 4, frame: CGRect(x: x, y: 0, width: 133, height: 30))
        }
        // The clock alternates between 2149 and 2151 on this machine.
        #expect(CaptureGeometry.sameLayout([slot(2149), slot(1500, "com.a")], [slot(1500, "com.a"), slot(2151)]))
        #expect(!CaptureGeometry.sameLayout([slot(2149)], [slot(2120)]))
        #expect(!CaptureGeometry.sameLayout([slot(2149)], [slot(2149), slot(1500, "com.a")]))
        #expect(!CaptureGeometry.sameLayout([slot(1500, "com.a")], [slot(1500, "com.b")]))
    }

    @Test func cacheFileNamesAreSafeAndDistinct() {
        let a = ItemImageKey(ownerString: "system:wifi", index: 0)
        let b = ItemImageKey(ownerString: "system_wifi", index: 0)
        #expect(!a.fileName.contains(":") && !a.fileName.contains("/"))
        #expect(a.fileName != b.fileName)
        #expect(ItemImageKey(ownerString: "com.a", index: 1).fileName.hasSuffix("-1.png"))
    }
}

@Suite struct ImageAnalysisTests {
    @Test func whiteMonochromeIsTemplateLike() {
        let icon = buffer(width: 10, height: 10) { x, y in (x > 2 && x < 8) ? (1, 1, 1, y == 0 ? 0.3 : 1) : nil }
        let traits = ImageAnalysis.traits(of: icon)
        #expect(traits.isTemplateLike)
        #expect(traits.lightForeground)
        #expect(traits.maxAlpha == 1)
    }

    @Test func colouredIsNotTemplateLike() {
        let icon = buffer(width: 10, height: 10) { x, _ in x < 5 ? (1, 0.1, 0.1, 1) : (1, 1, 1, 1) }
        #expect(!ImageAnalysis.traits(of: icon).isTemplateLike)
    }

    @Test func trimKeepsOnePixelOfPadding() throws {
        let icon = buffer(width: 20, height: 10) { x, y in (x >= 5 && x < 9 && y >= 3 && y < 7) ? (0, 0, 0, 1) : nil }
        let trimmed = try #require(ImageAnalysis.trimmed(icon))
        #expect(trimmed.width == 6 && trimmed.height == 6)
        #expect(ImageAnalysis.trimmed(buffer(width: 4, height: 4) { _, _ in nil }) == nil)
    }

    @Test func templateMaskNormalisesADimmedCapture() {
        // Inactive display: the icon is drawn at 40 % alpha; the mask comes out opaque.
        let dimmed = buffer(width: 4, height: 1) { x, _ in x < 2 ? (1, 1, 1, 0.4) : nil }
        let mask = ImageAnalysis.templateMask(dimmed, lightForeground: true)
        #expect(mask.alpha(0, 0) == 255)
        #expect(mask.alpha(3, 0) == 0)
    }

    @Test func pipelinePrefersTheDisplayWithMorePixels() throws {
        func bar(_ displayID: UInt32, alpha: Double, x: Int) -> BarCapture {
            let pixels = buffer(width: 200, height: 20) { px, py in (px >= x && px < x + 10 && py > 4 && py < 16) ? (1, 1, 1, alpha) : nil }
            return BarCapture(displayID: displayID, frame: CGRect(x: displayID == 1 ? 1000 : 0, y: 0, width: 100, height: 10),
                              image: try! #require(pixels.makeImage()), isTransparent: true)
        }
        let key = ItemImageKey(ownerString: "com.a", index: 0)
        let slots = [
            CaptureSlot(key: key, displayID: 4, frame: CGRect(x: 40, y: 0, width: 15, height: 10)),
            CaptureSlot(key: key, displayID: 1, frame: CGRect(x: 1040, y: 0, width: 15, height: 10)),
            CaptureSlot(key: ItemImageKey(ownerString: "com.empty", index: 0), displayID: 4, frame: CGRect(x: 0, y: 0, width: 10, height: 10)),
        ]
        let items = CapturePipeline.extract(slots: slots, bars: [bar(4, alpha: 1, x: 82), bar(1, alpha: 0.4, x: 82)])
        #expect(items.count == 1)   // the empty crop is dropped
        let item = try #require(items.first)
        #expect(item.displayID == 4)
        #expect(item.scale == 2)
        #expect(item.pixels.width == 12)
    }

    @Test func servedSizeKeepsMenuBarProportions() {
        // A 16×16 pt capture served at 18 pt: natural size, centred on an 18 pt canvas.
        let natural = ItemImageSizing.layout(contentPoints: CGSize(width: 16, height: 16), requestedHeight: 18)
        #expect(natural.canvas == CGSize(width: 16, height: 18))
        #expect(natural.content == CGRect(x: 0, y: 1, width: 16, height: 16))
        // Served at 36 pt: twice as large.
        #expect(ItemImageSizing.layout(contentPoints: CGSize(width: 16, height: 16), requestedHeight: 36).content.height == 32)
        // Taller than the request: shrunk to fit.
        #expect(ItemImageSizing.layout(contentPoints: CGSize(width: 20, height: 24), requestedHeight: 18).content.height == 18)
    }
}

@Suite struct ItemImageCacheTests {
    private func record(_ owner: String, index: Int = 0, bytes: Int = 100, capturedAt: Date) -> CacheRecord {
        CacheRecord(key: ItemImageKey(ownerString: owner, index: index),
                    traits: ImageTraits(isTemplateLike: true, lightForeground: true, coverage: 50, maxAlpha: 1),
                    scale: 2, pixelWidth: 10, pixelHeight: 10, capturedAt: capturedAt, bytes: bytes)
    }

    @Test func prunesOwnersNotSeenFor30Days() {
        let now = Date(timeIntervalSince1970: 100 * 86400)
        var index = CacheIndex()
        index.records = [record("com.old", capturedAt: now - 40 * 86400), record("com.recent", capturedAt: now - 40 * 86400),
                         record("com.unseen", capturedAt: now - 31 * 86400)]
        index.ownerLastSeen = ["com.old": now - 31 * 86400, "com.recent": now - 86400]
        let removed = CachePruner.keysToRemove(index, now: now)
        #expect(removed == [ItemImageKey(ownerString: "com.old", index: 0), ItemImageKey(ownerString: "com.unseen", index: 0)])
    }

    @Test func prunesLeastRecentlySeenBeyondTheBounds() {
        let now = Date(timeIntervalSince1970: 100 * 86400)
        var index = CacheIndex()
        index.records = (0..<5).map { record("com.app\($0)", bytes: 1000, capturedAt: now) }
        for i in 0..<5 { index.ownerLastSeen["com.app\(i)"] = now - Double(i) * 3600 }
        let limits = CachePruner.Limits(maxAge: 30 * 86400, maxEntries: 3, maxBytes: 10_000)
        #expect(CachePruner.keysToRemove(index, now: now, limits: limits)
                == [ItemImageKey(ownerString: "com.app3", index: 0), ItemImageKey(ownerString: "com.app4", index: 0)])
        let byBytes = CachePruner.Limits(maxAge: 30 * 86400, maxEntries: 100, maxBytes: 2500)
        #expect(CachePruner.keysToRemove(index, now: now, limits: byBytes).count == 3)
    }

    @Test func storesOnDiskAndServesAfterReload() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "rolltop-cache-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let pixels = buffer(width: 12, height: 12) { x, y in (x > 1 && x < 10 && y > 1 && y < 10) ? (1, 1, 1, 1) : nil }
        let key = ItemImageKey(ownerString: "com.a", index: 0)
        let cache = ItemImageCache(directory: directory)
        let item = CapturedItem(key: key, pixels: pixels, scale: 2, traits: ImageAnalysis.traits(of: pixels), displayID: 4)
        #expect(cache.store([item]) == [key])
        #expect(cache.store([item]).isEmpty)   // unchanged pixels: no rewrite
        cache.flush()
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: key.fileName).path))

        let reloaded = ItemImageCache(directory: directory)
        let entry = try #require(reloaded.entry(for: key))
        #expect(entry.isTemplate)
        let image = entry.nsImage(height: 18)
        #expect(image.isTemplate)
        #expect(image.size == CGSize(width: 6, height: 18))
        reloaded.removeAll()
        reloaded.flush()
        #expect(reloaded.entry(for: key) == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}
