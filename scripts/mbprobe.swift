// mbprobe: prints, as JSON, what MenuBarAgent actually draws per display (owner, x,
// width, system id, overflowed) and whether the overflow chevron is present. The
// verification tool for live tests. Independent of the app's own reader on purpose.
//
//   scripts/mbprobe [--compact] [--wait-present OWNER]... [--wait-absent OWNER]... [--timeout SECONDS]
//
// OWNER is a bundle id, a `com.apple.menuextra.*` identifier or `pid:<n>`. With --wait-*,
// polls every 100 ms until every condition holds on at least one display (present = a
// visible, non-overflowed slot), prints the final snapshot and exits 0, or exits 1 at the
// timeout (default 3 s). Needs Accessibility (run from a terminal that has it).
import AppKit
import ApplicationServices

func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}
func children(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute as String) as? [AXUIElement]) ?? [] }
func string(_ e: AXUIElement, _ name: String) -> String? { (attr(e, name) as? String).flatMap { $0.isEmpty ? nil : $0 } }
func pidOf(_ e: AXUIElement) -> pid_t? { var p: pid_t = 0; return AXUIElementGetPid(e, &p) == .success ? p : nil }
func frame(_ e: AXUIElement) -> CGRect? {
    guard let pv = attr(e, kAXPositionAttribute as String), let sv = attr(e, kAXSizeAttribute as String) else { return nil }
    var p = CGPoint.zero, s = CGSize.zero
    AXValueGetValue(pv as! AXValue, .cgPoint, &p)
    AXValueGetValue(sv as! AXValue, .cgSize, &s)
    return CGRect(origin: p, size: s)
}

let systemIDs: [String: Int] = [
    "com.apple.menuextra.battery": 0, "com.apple.menuextra.bluetooth": 1, "com.apple.menuextra.clock": 2,
    "com.apple.menuextra.sound": 5, "com.apple.menuextra.wifi": 6, "com.apple.menuextra.controlcenter": 8,
]

struct Slot: Encodable {
    let owner: String
    let pid: Int32?
    let systemID: Int?
    let x: Int
    let width: Int
    let overflowed: Bool
}

struct Display: Encodable {
    let displayID: UInt32
    let main: Bool
    let barX: Int
    let barWidth: Int
    let overflowChevron: Bool
    let chevronExpanded: Bool
    let slots: [Slot]
}

struct Snapshot: Encodable {
    let time: String
    let axTrusted: Bool
    let readable: Bool
    let displays: [Display]
    /// Owners with a visible slot on at least one display, sorted.
    let drawn: [String]
}

func snapshot() -> Snapshot {
    let apps = NSWorkspace.shared.runningApplications
    let bundles = Dictionary(apps.compactMap { app in app.bundleIdentifier.map { (app.processIdentifier, $0) } }, uniquingKeysWith: { a, _ in a })
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    let mainID = CGMainDisplayID()
    let time = ISO8601DateFormatter().string(from: Date())
    guard let agent = apps.first(where: { $0.bundleIdentifier == "com.apple.MenuBarAgent" })?.processIdentifier else {
        return Snapshot(time: time, axTrusted: AXIsProcessTrusted(), readable: false, displays: [], drawn: [])
    }
    let element = AXUIElementCreateApplication(agent)
    AXUIElementSetMessagingTimeout(element, 1.0)
    guard let windows = attr(element, kAXWindowsAttribute as String) as? [AXUIElement] else {
        return Snapshot(time: time, axTrusted: AXIsProcessTrusted(), readable: false, displays: [], drawn: [])
    }
    var displays: [Display] = []
    for window in windows {
        guard let wf = frame(window) else { continue }
        let displayID = ids.first { CGDisplayBounds($0).contains(CGPoint(x: wf.midX, y: wf.minY + 1)) } ?? 0
        var chevron: CGRect?
        var expanded = false
        var raw: [(owner: String, pid: pid_t?, systemID: Int?, frame: CGRect)] = []
        for child in children(window) {
            if let id = string(child, "AXIdentifier"), id.hasPrefix("menu-bar-overflow-indicator") {
                chevron = frame(child)
                expanded = id.hasSuffix("-expanded")
                continue
            }
            guard string(child, kAXRoleAttribute as String) == (kAXGroupRole as String), let f = frame(child),
                  let first = children(child).first else { continue }
            let pid = pidOf(first)
            if pid == agent {
                let id = string(first, "AXIdentifier") ?? children(first).compactMap { string($0, "AXIdentifier") }.first ?? "agent:unknown"
                raw.append((id, pid, systemIDs[id], f))
            } else if let pid {
                let bundle = bundles[pid] ?? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
                raw.append((bundle ?? "pid:\(pid)", pid, nil, f))
            }
        }
        let slots = raw.sorted { $0.frame.minX < $1.frame.minX }.map { r -> Slot in
            let overflowed = chevron.map { min(r.frame.maxX, $0.maxX) - max(r.frame.minX, $0.minX) > 1 } ?? false
            return Slot(owner: r.owner, pid: r.pid, systemID: r.systemID, x: Int(r.frame.minX), width: Int(r.frame.width), overflowed: overflowed)
        }
        displays.append(Display(displayID: displayID, main: displayID == mainID, barX: Int(wf.minX), barWidth: Int(wf.width),
                                overflowChevron: chevron != nil, chevronExpanded: expanded, slots: slots))
    }
    displays.sort { ($0.main ? 0 : 1, $0.barX) < ($1.main ? 0 : 1, $1.barX) }
    let drawn = Set(displays.flatMap { $0.slots.filter { !$0.overflowed }.map(\.owner) }).sorted()
    return Snapshot(time: time, axTrusted: AXIsProcessTrusted(), readable: true, displays: displays, drawn: drawn)
}

var compact = false
var present: [String] = []
var absent: [String] = []
var timeout = 3.0
var args = CommandLine.arguments.dropFirst().makeIterator()
while let arg = args.next() {
    switch arg {
    case "--compact": compact = true
    case "--wait-present": present.append(args.next() ?? "")
    case "--wait-absent": absent.append(args.next() ?? "")
    case "--timeout": timeout = Double(args.next() ?? "") ?? timeout
    default:
        FileHandle.standardError.write(Data("unknown argument \(arg)\n".utf8))
        exit(2)
    }
}

let encoder = JSONEncoder()
encoder.outputFormatting = compact ? [.sortedKeys] : [.prettyPrinted, .sortedKeys]
let started = Date()
var result = snapshot()
var satisfied = true
if !present.isEmpty || !absent.isEmpty {
    while true {
        let drawn = Set(result.drawn)
        satisfied = present.allSatisfy(drawn.contains) && absent.allSatisfy { !drawn.contains($0) }
        if satisfied || Date().timeIntervalSince(started) >= timeout { break }
        // Spin the run loop so NSWorkspace's app list stays current.
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        result = snapshot()
    }
}
print(String(decoding: try encoder.encode(result), as: UTF8.self))
if !present.isEmpty || !absent.isEmpty {
    let elapsed = Int(Date().timeIntervalSince(started) * 1000)
    FileHandle.standardError.write(Data("mbprobe: \(satisfied ? "conditions met" : "TIMEOUT") after \(elapsed) ms\n".utf8))
}
exit(satisfied ? 0 : 1)
