#if DEBUG
import AppKit
import RolltopCore

/// Debug evidence: every item image `services[.itemImages]` serves now, drawn on a light
/// and a dark surface (templates tinted with that surface's label colour), next to the
/// stored capture on mid grey. Written by `capture.debug-contact-sheet`.
enum CaptureContactSheet {
    struct Row: Codable {
        var owner: String
        var index: Int
        var name: String
        var source: String
        var isTemplate: Bool
        var pointSize: [Double]
    }

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "Rolltop/debug", directoryHint: .isDirectory)
    }

    /// Writes `capture-contact-sheet.png` and `.json`; returns the PNG URL.
    @discardableResult
    static func write(context: AppContext, provider: CapturedItemImageProvider, extraOwners: [OwnerID] = []) throws -> URL {
        var keys: [(OwnerID, Int, String)] = []
        var seen = Set<String>()
        for entry in context.catalog.entries {
            guard let owner = entry.owner, !entry.isOwn else { continue }
            for index in 0..<max(1, entry.itemCount) where seen.insert("\(owner.stringValue)#\(index)").inserted {
                keys.append((owner, index, entry.displayName))
            }
        }
        for owner in extraOwners where seen.insert("\(owner.stringValue)#0").inserted {
            keys.append((owner, 0, context.catalog.displayName(for: owner)))
        }

        let service = context.services[.itemImages]
        let rowHeight: CGFloat = 30, labelWidth: CGFloat = 320, cellWidth: CGFloat = 150
        let size = CGSize(width: labelWidth + cellWidth * 3, height: rowHeight * CGFloat(keys.count + 1))
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw CommandError.failed("bitmap")
        }
        rep.size = size
        var rows: [Row] = []
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        CGRect(origin: .zero, size: size).fill()
        let font = NSFont.systemFont(ofSize: 11)
        func text(_ string: String, at point: CGPoint, color: NSColor = .black) {
            (string as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
        }
        let top = size.height - rowHeight
        text("item", at: CGPoint(x: 8, y: top + 9))
        text("light surface", at: CGPoint(x: labelWidth + 8, y: top + 9))
        text("dark surface", at: CGPoint(x: labelWidth + cellWidth + 8, y: top + 9))
        text("stored capture", at: CGPoint(x: labelWidth + cellWidth * 2 + 8, y: top + 9))
        for (row, (owner, index, name)) in keys.enumerated() {
            let y = top - rowHeight * CGFloat(row + 1)
            let source = provider.source(for: owner, itemIndex: index)
            let image = service.image(for: owner, itemIndex: index, height: 18)
            text("\(name) [\(owner.stringValue)#\(index)] \(source.rawValue)", at: CGPoint(x: 8, y: y + 9))
            let surfaces: [(NSColor, NSColor)] = [(NSColor(white: 0.93, alpha: 1), .black), (NSColor(white: 0.16, alpha: 1), .white)]
            for (column, (background, label)) in surfaces.enumerated() {
                let cell = CGRect(x: labelWidth + cellWidth * CGFloat(column), y: y, width: cellWidth, height: rowHeight)
                background.setFill()
                cell.fill()
                if let image { draw(image, centeredIn: cell, tint: image.isTemplate ? label : nil) }
            }
            let rawCell = CGRect(x: labelWidth + cellWidth * 2, y: y, width: cellWidth, height: rowHeight)
            NSColor(white: 0.5, alpha: 1).setFill()
            rawCell.fill()
            if let entry = provider.cache.entry(for: ItemImageKey(owner: owner, index: index)) {
                let raw = NSImage(cgImage: entry.image, size: CGSize(width: CGFloat(entry.record.pixelWidth) / entry.record.scale,
                                                                       height: CGFloat(entry.record.pixelHeight) / entry.record.scale))
                draw(raw, centeredIn: rawCell, tint: nil)
            }
            rows.append(Row(owner: owner.stringValue, index: index, name: name, source: source.rawValue,
                            isTemplate: image?.isTemplate ?? false,
                            pointSize: [Double(image?.size.width ?? 0), Double(image?.size.height ?? 0)]))
        }
        NSGraphicsContext.restoreGraphicsState()

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = directory.appending(path: "capture-contact-sheet.png")
        guard let data = rep.representation(using: .png, properties: [:]) else { throw CommandError.failed("png") }
        try data.write(to: png, options: .atomic)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: directory.appending(path: "capture-contact-sheet.json"), options: .atomic)
        return png
    }

    private static func draw(_ image: NSImage, centeredIn cell: CGRect, tint: NSColor?) {
        let rect = CGRect(x: cell.midX - image.size.width / 2, y: cell.midY - image.size.height / 2,
                          width: image.size.width, height: image.size.height)
        guard let tint else {
            image.draw(in: rect)
            return
        }
        let tinted = NSImage(size: image.size, flipped: false) { bounds in
            image.draw(in: bounds)
            tint.set()
            bounds.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: rect)
    }
}
#endif
