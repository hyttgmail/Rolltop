import CoreGraphics
import Foundation
import RolltopCore

/// Identity of one item image: owner plus the item's index in the owner's `AXExtrasMenuBar`
/// (the index `ItemActivator.activate` takes).
nonisolated struct ItemImageKey: Hashable, Sendable, Codable, CustomStringConvertible {
    var owner: String
    var index: Int

    init(owner: OwnerID, index: Int) {
        self.owner = owner.stringValue
        self.index = index
    }

    init(ownerString: String, index: Int) {
        self.owner = ownerString
        self.index = index
    }

    var description: String { "\(owner)#\(index)" }

    /// File name in the disk cache: owner with every character outside `[A-Za-z0-9.-]`
    /// replaced by `_`, a short hash of the exact owner (so `a:b` and `a_b` differ), the index.
    var fileName: String {
        let safe = String(owner.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") ? $0 : "_" })
        return "\(safe)-\(Self.fnv1a(owner))-\(index).png"
    }

    static func fnv1a(_ string: String) -> String {
        var hash: UInt32 = 0x811C_9DC5
        for byte in string.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return String(hash, radix: 16)
    }
}

/// One drawn slot to capture.
nonisolated struct CaptureSlot: Sendable, Equatable {
    var key: ItemImageKey
    var displayID: UInt32
    /// Global top-left points.
    var frame: CGRect
}

nonisolated enum CaptureGeometry {
    /// The slot's rect in the pixels of a capture of `captureFrame` (both in global top-left
    /// points). Nil when the slot is outside the capture. The scale is
    /// `imageWidth / captureFrame.width`, which also covers builds that report frames in pixels.
    static func cropRect(slot: CGRect, captureFrame: CGRect, imageSize: CGSize) -> CGRect? {
        guard captureFrame.width > 0, captureFrame.height > 0 else { return nil }
        let sx = imageSize.width / captureFrame.width
        let sy = imageSize.height / captureFrame.height
        let rect = CGRect(x: (slot.minX - captureFrame.minX) * sx, y: (slot.minY - captureFrame.minY) * sy,
                          width: slot.width * sx, height: slot.height * sy).integral
        let clipped = rect.intersection(CGRect(origin: .zero, size: imageSize))
        guard !clipped.isNull, clipped.width >= 2, clipped.height >= 2 else { return nil }
        return clipped
    }

    /// Maps an owner's drawn slots to item indices. All items of one app hide and show
    /// together, so when the counts match the k-th slot from the left is the item whose
    /// list-A frame is k-th from the left; otherwise slots are numbered left to right.
    static func itemIndices(slotMinXs: [CGFloat], listAMinXs: [CGFloat]) -> [Int] {
        let slotOrder = slotMinXs.indices.sorted { slotMinXs[$0] < slotMinXs[$1] }
        var result = [Int](repeating: 0, count: slotMinXs.count)
        if slotMinXs.count == listAMinXs.count {
            let itemOrder = listAMinXs.indices.sorted { listAMinXs[$0] < listAMinXs[$1] }
            for (rank, slot) in slotOrder.enumerated() { result[slot] = itemOrder[rank] }
        } else {
            for (rank, slot) in slotOrder.enumerated() { result[slot] = rank }
        }
        return result
    }

    /// The owner a drawn slot belongs to, when it is assignable and not Rolltop's own.
    static func owner(of slot: DrawnSlotRecord, ownBundleIDs: Set<String>) -> OwnerID? {
        if let identifier = slot.axIdentifier {
            return SystemModule(axIdentifier: identifier).map(OwnerID.system)
        }
        guard let bundle = slot.ownerBundleID, !ownBundleIDs.contains(bundle) else { return nil }
        return .app(bundle)
    }

    /// Every visible slot of assignable owners, keyed by item.
    /// - Parameter listAFrames: per owner, the list-A frames (`CatalogEntry.lastKnownFrames`).
    static func slots(in snapshot: DrawnSnapshot, ownBundleIDs: Set<String>,
                      listAFrames: [OwnerID: [CGRect]]) -> [CaptureSlot] {
        var result: [CaptureSlot] = []
        for display in snapshot.displays {
            var byOwner: [OwnerID: [DrawnSlotRecord]] = [:]
            var order: [OwnerID] = []
            for slot in display.slots where !slot.isOverflowed {
                guard let owner = owner(of: slot, ownBundleIDs: ownBundleIDs) else { continue }
                if byOwner[owner] == nil { order.append(owner) }
                byOwner[owner, default: []].append(slot)
            }
            for owner in order {
                let slots = byOwner[owner] ?? []
                let indices = itemIndices(slotMinXs: slots.map(\.frame.minX),
                                          listAMinXs: (listAFrames[owner] ?? []).map(\.minX))
                for (slot, index) in zip(slots, indices) {
                    result.append(CaptureSlot(key: ItemImageKey(owner: owner, index: index),
                                              displayID: display.displayID, frame: slot.frame))
                }
            }
        }
        return result
    }

    /// Whether two reads show the same items at (nearly) the same place. MenuBarAgent
    /// reports some slots a few points apart between reads (the clock alternates between
    /// x = 2149 and 2151 on this machine), so frames may differ by `tolerance` points.
    /// Read times are ignored, so re-reading an unchanged bar changes nothing.
    static func sameLayout(_ a: [CaptureSlot], _ b: [CaptureSlot], tolerance: CGFloat = 3) -> Bool {
        guard a.count == b.count else { return false }
        func ordered(_ slots: [CaptureSlot]) -> [CaptureSlot] {
            slots.sorted { ($0.key.description, $0.displayID, $0.frame.minX) < ($1.key.description, $1.displayID, $1.frame.minX) }
        }
        for (x, y) in zip(ordered(a), ordered(b)) {
            guard x.key == y.key, x.displayID == y.displayID,
                  abs(x.frame.minX - y.frame.minX) <= tolerance, abs(x.frame.minY - y.frame.minY) <= tolerance,
                  abs(x.frame.width - y.frame.width) <= tolerance, abs(x.frame.height - y.frame.height) <= tolerance
            else { return false }
        }
        return true
    }

    /// Readable form of a slot list for logs.
    static func signature(of slots: [CaptureSlot]) -> [String] {
        slots.map { slot in
            let f = slot.frame
            return "\(slot.key)@\(slot.displayID):\(Int(f.minX.rounded())),\(Int(f.minY.rounded())),\(Int(f.width.rounded())),\(Int(f.height.rounded()))"
        }.sorted()
    }
}
