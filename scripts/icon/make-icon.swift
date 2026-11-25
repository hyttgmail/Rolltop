// Generates Rolltop's app icon as an Icon Composer document (icon.json + SVG layers) and the
// matching "Slats" menu bar glyphs as template SVG image sets. Everything is drawn from the
// geometry below: no third-party artwork, fonts or stock assets.
//
//   swift scripts/icon/make-icon.swift                      # writes the shipping assets
//
// Options:
//   --icon-out <path.icon>         default Rolltop/Resources/AppIcon.icon
//   --glyphs-out <Assets.xcassets> default Rolltop/Resources/Assets.xcassets; "none" skips them
//
// The system shapes the icon and adds the glass, the specular highlights and the shadows:
// layers are unmasked flat shapes on a 1024 pt canvas (Icon Composer's macOS canvas), and
// the background is the document fill. Group and layer order in icon.json is front to back.
import Foundation

// MARK: Colours

struct Color {
    let hex: UInt32
    init(_ hex: UInt32) { self.hex = hex }
    var json: String {
        let c = [16, 8, 0].map { Double((hex >> UInt32($0)) & 0xFF) / 255 }
        return String(format: "display-p3:%.5f,%.5f,%.5f,1.00000", c[0], c[1], c[2])
    }
}

/// A top-to-bottom gradient: lighter above, so it agrees with the system's light.
struct Gradient {
    let top: Color, bottom: Color
    init(_ top: UInt32, _ bottom: UInt32) { (self.top, self.bottom) = (Color(top), Color(bottom)) }
    var json: [String: Any] {
        ["linear-gradient": [top.json, bottom.json],
         "orientation": ["start": ["x": decimal(0.5), "y": 0], "stop": ["x": decimal(0.5), "y": 1]]]
    }
}

/// Keeps 0.45 as 0.45 in the JSON (a Double would print as 0.45000000000000001).
func decimal(_ value: Double) -> NSDecimalNumber { NSDecimalNumber(string: String(value)) }

private func n(_ value: Double) -> String {
    let rounded = (value * 1000).rounded() / 1000
    return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
}

// MARK: Shapes (SVG, y grows downwards)

enum Shape {
    case circle(cx: Double, cy: Double, r: Double)
    case capsule(x: Double, y: Double, w: Double, h: Double)
    /// The part of a circle below the horizontal line `y` (an item tucked behind a slat).
    case circleBelow(cx: Double, cy: Double, r: Double, y: Double)

    func svg(fill: String) -> String {
        switch self {
        case let .circle(cx, cy, r):
            return "<circle cx=\"\(n(cx))\" cy=\"\(n(cy))\" r=\"\(n(r))\" fill=\"\(fill)\"/>"
        case let .capsule(x, y, w, h):
            return "<rect x=\"\(n(x))\" y=\"\(n(y))\" width=\"\(n(w))\" height=\"\(n(h))\" rx=\"\(n(h / 2))\" ry=\"\(n(h / 2))\" fill=\"\(fill)\"/>"
        case let .circleBelow(cx, cy, r, y):
            let dy = y - cy
            guard abs(dy) < r else { return dy < 0 ? Shape.circle(cx: cx, cy: cy, r: r).svg(fill: fill) : "" }
            let dx = (r * r - dy * dy).squareRoot()
            return "<path d=\"M \(n(cx - dx)) \(n(y)) A \(n(r)) \(n(r)) 0 \(dy < 0 ? 1 : 0) 0 \(n(cx + dx)) \(n(y)) Z\" fill=\"\(fill)\"/>"
        }
    }
}

func svgDocument(width: Double, height: Double, _ body: [String]) -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <svg xmlns="http://www.w3.org/2000/svg" width="\(n(width))" height="\(n(height))" viewBox="0 0 \(n(width)) \(n(height))">
    \(body.map { "  " + $0 }.joined(separator: "\n"))
    </svg>

    """
}

// MARK: Icon document

struct Layer {
    let name: String
    let shape: Shape
    let fill: Gradient
    var darkFill: Gradient? = nil
    var opacity = 1.0
    /// Opacity in the clear and tinted (mono) appearances, where every layer is white.
    var monoOpacity = 1.0

    var json: [String: Any] {
        var fills: [[String: Any]] = [["value": fill.json]]
        if let darkFill { fills.append(["appearance": "dark", "value": darkFill.json]) }
        fills.append(["appearance": "tinted", "value": ["solid": "extended-gray:1.00000,1.00000"]])
        return ["name": name, "image-name": "\(name).svg", "glass": true, "fill-specializations": fills,
                "opacity-specializations": [["value": decimal(opacity)],
                                            ["appearance": "tinted", "value": decimal(monoOpacity)] as [String: Any]]]
    }
}

struct Group {
    let name: String
    let layers: [Layer]
    let shadow: String              // "neutral" or "layer-color"
    var blur: Double? = nil

    var json: [String: Any] {
        var out: [String: Any] = ["name": name, "layers": layers.map(\.json), "lighting": "individual",
                                  "shadow": ["kind": shadow, "opacity": decimal(0.5)] as [String: Any],
                                  "translucency": ["enabled": false, "value": decimal(0.5)] as [String: Any]]
        if let blur { out["blur-material"] = decimal(blur) }
        return out
    }
}

/// Slats: a rolltop of three overlapping glass slats, drawn down over three menu bar items.
/// The lowest slat is clear enough to show the items' colours through it; below it they are
/// in plain sight. Items put away, and how they come back.
enum AppIcon {
    static let background = Gradient(0x4B9BFF, 0x0F4FE2)

    static let groups: [Group] = {
        let top = 222.0, step = 136.0, height = 160.0
        let fills = [Gradient(0xB4D2FF, 0x98C0FF), Gradient(0xFFFFFF, 0xDFEBFF), Gradient(0xFFFFFF, 0xEAF2FF)]
        let darkFills = [Gradient(0x3F78D8, 0x3568C4), Gradient(0x8CC0FF, 0x5B9DF8), Gradient(0x8CC0FF, 0x4D92F5)]
        let opacities = [1, 1, 0.46], mono = [0.5, 0.85, 0.55]
        let slats = (0..<3).reversed().map { i in   // each slat overlaps the one above it
            Layer(name: "slat-\(i + 1)", shape: .capsule(x: 180, y: top + Double(i) * step, w: 664, h: height),
                  fill: fills[i], darkFill: darkFills[i], opacity: opacities[i], monoOpacity: mono[i])
        }
        let colours = [Gradient(0xFFE04A, 0xFFA800), Gradient(0xFF8AA5, 0xFF2F62), Gradient(0x7AF0D0, 0x0FB890)]
        let items = zip([288.0, 512, 736], colours).enumerated().map { i, item in
            Layer(name: "item-\(i + 1)", shape: .circle(cx: item.0, cy: 696, r: 104), fill: item.1)
        }
        return [Group(name: "Slats", layers: slats, shadow: "neutral", blur: 0.4),
                Group(name: "Items", layers: items, shadow: "layer-color")]
    }()

    static func write(to url: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        let assets = url.appendingPathComponent("Assets")
        try fm.createDirectory(at: assets, withIntermediateDirectories: true)
        for layer in groups.flatMap(\.layers) {
            try svgDocument(width: 1024, height: 1024, [layer.shape.svg(fill: "#FFFFFF")])
                .write(to: assets.appendingPathComponent("\(layer.name).svg"), atomically: true, encoding: .utf8)
        }
        let document: [String: Any] = [
            "fill-specializations": [["value": background.json], ["appearance": "dark", "value": "system-dark"] as [String: Any]],
            "groups": groups.map(\.json),
            "supported-platforms": ["squares": ["macOS"]],
        ]
        try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
            .write(to: url.appendingPathComponent("icon.json"))
    }
}

// MARK: Menu bar glyphs

/// The same motif as an 18 x 16 pt template (the size of the system's own items). Collapsed:
/// two slats with the items tucked behind them, only their lower edges showing. Revealed:
/// one slat left, the items in full below it. Slat edges sit on whole points, so they stay sharp at 1x.
enum Glyph {
    static let width = 18.0, height = 16.0
    static let slatHeight = 4.0, gap = 1.0, itemR = 2.3
    static let xs = [3.6, 9.0, 14.4]

    static func svg(revealed: Bool) -> String {
        func slat(_ y: Double) -> Shape { .capsule(x: 1, y: y, w: width - 2, h: slatHeight) }
        let shapes: [Shape]
        if revealed {
            shapes = [slat(3)] + xs.map { .circle(cx: $0, cy: 11.2, r: itemR) }
        } else {
            let second = 1 + slatHeight + gap
            let line = second + slatHeight + gap
            shapes = [slat(1), slat(second)] + xs.map { .circleBelow(cx: $0, cy: line + 0.5, r: itemR, y: line) }
        }
        return svgDocument(width: width, height: height, shapes.map { $0.svg(fill: "#000000") })
    }

    static func write(to catalog: URL) throws {
        let fm = FileManager.default
        for (name, revealed) in [("StatusSlatsCollapsed", false), ("StatusSlatsRevealed", true)] {
            let set = catalog.appendingPathComponent("\(name).imageset")
            if fm.fileExists(atPath: set.path) { try fm.removeItem(at: set) }
            try fm.createDirectory(at: set, withIntermediateDirectories: true)
            try svg(revealed: revealed).write(to: set.appendingPathComponent("\(name).svg"), atomically: true, encoding: .utf8)
            let contents: [String: Any] = [
                "images": [["filename": "\(name).svg", "idiom": "universal"]],
                "info": ["author": "xcode", "version": 1] as [String: Any],
                "properties": ["preserves-vector-representation": true, "template-rendering-intent": "template"] as [String: Any],
            ]
            try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
                .write(to: set.appendingPathComponent("Contents.json"))
        }
    }
}

// MARK: Main

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
var iconOut = root.appendingPathComponent("Rolltop/Resources/AppIcon.icon")
var glyphsOut: URL? = root.appendingPathComponent("Rolltop/Resources/Assets.xcassets")
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let flag = args.removeFirst()
    guard let value = args.first else { FileHandle.standardError.write(Data("missing value for \(flag)\n".utf8)); exit(2) }
    args.removeFirst()
    switch flag {
    case "--icon-out": iconOut = URL(fileURLWithPath: value)
    case "--glyphs-out": glyphsOut = value == "none" ? nil : URL(fileURLWithPath: value)
    default: FileHandle.standardError.write(Data("unknown option \(flag)\n".utf8)); exit(2)
    }
}
do {
    try AppIcon.write(to: iconOut)
    print("wrote \(iconOut.path)")
    if let glyphsOut {
        try Glyph.write(to: glyphsOut)
        print("wrote StatusSlatsCollapsed / StatusSlatsRevealed into \(glyphsOut.path)")
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
