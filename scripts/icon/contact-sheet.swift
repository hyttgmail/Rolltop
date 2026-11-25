// Lays PNG files out on one sheet so icon renders can be compared side by side.
//
//   swift scripts/icon/contact-sheet.swift <out.png> <columns> <cell-px> [--bg light|dark|split] <label=path[@zoom]> …
//
// Each image is drawn at its own pixel size (times `zoom`, nearest neighbour, so 16 and
// 32 px renders can be judged pixel by pixel) and centred in its cell, with the label
// underneath. `--bg split` paints the left half of every cell light and the right half dark.
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 4, let columns = Int(arguments[1]), let cell = Int(arguments[2]) else {
    FileHandle.standardError.write(Data("usage: contact-sheet.swift <out.png> <columns> <cell-px> [--bg light|dark|split] <label=path[@zoom]> …\n".utf8))
    exit(2)
}
let output = URL(fileURLWithPath: arguments[0])
var rest = Array(arguments.dropFirst(3))
var background = "light"
if rest.first == "--bg", rest.count >= 2 {
    background = rest[1]
    rest.removeFirst(2)
}

struct Entry { let label: String; let image: CGImage; let zoom: Int }
let entries: [Entry] = rest.map { spec in
    let parts = spec.split(separator: "=", maxSplits: 1).map(String.init)
    var pathPart = parts.count == 2 ? parts[1] : parts[0]
    var zoom = 1
    if let at = pathPart.lastIndex(of: "@"), let z = Int(pathPart[pathPart.index(after: at)...]) {
        zoom = z
        pathPart = String(pathPart[..<at])
    }
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: pathPart) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        FileHandle.standardError.write(Data("cannot read \(pathPart)\n".utf8))
        exit(1)
    }
    return Entry(label: parts.count == 2 ? parts[0] : URL(fileURLWithPath: pathPart).lastPathComponent, image: image, zoom: zoom)
}

let labelHeight = 28
let rows = (entries.count + columns - 1) / columns
let width = columns * cell
let height = rows * (cell + labelHeight)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
let light = CGColor(srgbRed: 0.93, green: 0.93, blue: 0.94, alpha: 1)
let dark = CGColor(srgbRed: 0.13, green: 0.13, blue: 0.15, alpha: 1)
context.setFillColor(background == "dark" ? dark : light)
context.fill(CGRect(x: 0, y: 0, width: width, height: height))

for (index, entry) in entries.enumerated() {
    let column = index % columns
    let row = index / columns
    // CoreGraphics has its origin at the bottom left.
    let cellRect = CGRect(x: column * cell, y: height - (row + 1) * (cell + labelHeight) + labelHeight, width: cell, height: cell)
    if background == "split" {
        context.setFillColor(dark)
        context.fill(CGRect(x: cellRect.midX, y: cellRect.minY - CGFloat(labelHeight), width: cellRect.width / 2,
                            height: cellRect.height + CGFloat(labelHeight)))
    }
    let w = CGFloat(entry.image.width * entry.zoom)
    let h = CGFloat(entry.image.height * entry.zoom)
    let scale = min(1, min(cellRect.width - 8, cellRect.height - 8) / max(w, h))
    let drawn = CGRect(x: (cellRect.midX - w * scale / 2).rounded(), y: (cellRect.midY - h * scale / 2).rounded(),
                       width: w * scale, height: h * scale)
    context.interpolationQuality = entry.zoom > 1 ? .none : .high
    context.draw(entry.image, in: drawn)

    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13, weight: .medium),
        .foregroundColor: background == "dark" ? NSColor.white : NSColor.black,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: entry.label, attributes: attributes))
    let bounds = CTLineGetBoundsWithOptions(line, [])
    context.textPosition = CGPoint(x: cellRect.minX + 6, y: cellRect.minY - CGFloat(labelHeight) + (CGFloat(labelHeight) - bounds.height) / 2 + 3)
    CTLineDraw(line, context)
}

guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(destination, image, nil)
exit(CGImageDestinationFinalize(destination) ? 0 : 1)
