import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import RolltopCore
import Synchronization

/// A display as CoreGraphics sees it (global top-left coordinates).
nonisolated struct DisplayGeometry: Sendable, Equatable {
    var displayID: CGDirectDisplayID
    var bounds: CGRect
    var isMain: Bool

    static func current() -> [DisplayGeometry] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        let main = CGMainDisplayID()
        return ids.prefix(Int(count)).map { DisplayGeometry(displayID: $0, bounds: CGDisplayBounds($0), isMain: $0 == main) }
    }
}

/// Reads list A (every app's `AXExtrasMenuBar`) and list B (MenuBarAgent's drawn
/// slots), see docs/PLATFORM.md §2. Blocking calls: run them off the main thread.
/// The `async` wrappers do that on a private concurrent queue.
nonisolated enum AXInventory {
    /// First pass, all apps concurrently.
    static let messagingTimeout: Float = 0.25
    /// Second pass for apps that timed out.
    static let retryTimeout: Float = 0.5
    static let agentTimeout: Float = 1.0
    static let overflowIdentifierPrefix = "menu-bar-overflow-indicator"
    static let overflowExpandedIdentifier = "menu-bar-overflow-indicator-expanded"

    private static let queue = DispatchQueue(label: "com.alphapengwang.rolltop.ax", qos: .userInitiated, attributes: .concurrent)

    // MARK: Running apps

    /// Apps that may own status items: skips XPC services and app extensions.
    static func runningApps() -> [RunningAppRecord] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard !app.isTerminated else { return nil }
            if let ext = app.bundleURL?.pathExtension, ext == "xpc" || ext == "appex" { return nil }
            let resolved = app.bundleURL?.resolvingSymlinksInPath().standardizedFileURL.path
            return RunningAppRecord(pid: app.processIdentifier,
                                    bundleID: app.bundleIdentifier,
                                    name: app.localizedName,
                                    bundlePath: resolved,
                                    runsOutsideApplications: RunningAppRecord.isOutsideApplications(resolvedPath: resolved))
        }
    }

    static func agentPID(in apps: [RunningAppRecord]) -> pid_t? {
        apps.first { $0.bundleID == menuBarAgentBundleID }?.pid
    }

    // MARK: List A

    /// Reads every app's `AXExtrasMenuBar` concurrently with a short timeout, then the
    /// apps that timed out once more with a longer one. Order follows `apps`.
    static func readExtras(of apps: [RunningAppRecord], excluding ownPID: pid_t) -> [AppExtrasRecord] {
        let targets = apps.filter { $0.pid != ownPID }
        let results = Mutex([AppExtrasRecord?](repeating: nil, count: targets.count))
        DispatchQueue.concurrentPerform(iterations: targets.count) { index in
            let record = readExtras(of: targets[index], timeout: messagingTimeout)
            results.withLock { $0[index] = record }
        }
        let retry = results.withLock { current in current.indices.filter { current[$0]?.status == .timedOut } }
        if !retry.isEmpty {
            DispatchQueue.concurrentPerform(iterations: retry.count) { position in
                let index = retry[position]
                let record = readExtras(of: targets[index], timeout: retryTimeout)
                results.withLock { $0[index] = record }
            }
        }
        return results.withLock { $0.compactMap { $0 } }
    }

    static func readExtras(of app: RunningAppRecord, timeout: Float) -> AppExtrasRecord {
        let element = AX.application(app.pid, timeout: timeout)
        let (barError, barValue) = AX.copy(element, AX.extrasMenuBarAttribute)
        if barError == .cannotComplete {
            return AppExtrasRecord(pid: app.pid, bundleID: app.bundleID, status: .timedOut, items: [])
        }
        guard barError == .success, let barValue, CFGetTypeID(barValue) == AXUIElementGetTypeID() else {
            // An app element without even a role has switched Accessibility off.
            let refused = AX.attributeNames(element).map { !$0.contains(kAXRoleAttribute as String) } ?? false
            return AppExtrasRecord(pid: app.pid, bundleID: app.bundleID, status: refused ? .refused : .read, items: [])
        }
        let bar = barValue as! AXUIElement
        let (childrenError, childrenValue) = AX.copy(bar, kAXChildrenAttribute)
        if childrenError == .cannotComplete {
            return AppExtrasRecord(pid: app.pid, bundleID: app.bundleID, status: .timedOut, items: [])
        }
        let children = (childrenValue as? [AXUIElement]) ?? []
        let isAgent = app.bundleID == menuBarAgentBundleID
        let items = children.enumerated().map { index, child -> ExtraItemRecord in
            let hosted = isAgent ? AX.hostedIdentifier(child) : nil
            let described = hosted?.item ?? child
            return ExtraItemRecord(index: index,
                                   frame: AX.frame(child) ?? .zero,
                                   axIdentifier: hosted?.identifier,
                                   title: AX.string(described, kAXTitleAttribute),
                                   detail: AX.string(described, kAXDescriptionAttribute))
        }
        return AppExtrasRecord(pid: app.pid, bundleID: app.bundleID, status: .read, items: items)
    }

    // MARK: List B

    /// MenuBarAgent's windows (one per display) and the slots it actually lays out.
    static func readDrawn(agentPID: pid_t?, bundleByPID: [pid_t: String], displays: [DisplayGeometry]) -> DrawnSnapshot {
        guard let agentPID else { return DrawnSnapshot(displays: [], capturedAt: Date(), isReadable: false) }
        let agent = AX.application(agentPID, timeout: agentTimeout)
        let (error, value) = AX.copy(agent, kAXWindowsAttribute)
        guard error == .success, let windows = value as? [AXUIElement] else {
            return DrawnSnapshot(displays: [], capturedAt: Date(), isReadable: false)
        }
        var bars: [DisplayBarRecord] = []
        for window in windows {
            guard let windowFrame = AX.frame(window) else { continue }
            let display = displays.first { $0.bounds.contains(CGPoint(x: windowFrame.midX, y: windowFrame.minY + 1)) }
            let displayID = display?.displayID ?? 0
            var chevron: CGRect?
            var chevronExpanded = false
            var rawSlots: [(frame: CGRect, pid: pid_t?, identifier: String?)] = []
            for child in AX.children(window) {
                let role = AX.role(child)
                if let identifier = AX.identifier(child), identifier.hasPrefix(overflowIdentifierPrefix) {
                    chevron = AX.frame(child)
                    chevronExpanded = identifier == overflowExpandedIdentifier
                    continue
                }
                guard role == kAXGroupRole as String, let frame = AX.frame(child) else { continue }
                guard let first = AX.children(child).first else { continue }
                let ownerPID = AX.pid(first)
                if ownerPID == agentPID {
                    rawSlots.append((frame, agentPID, AX.hostedIdentifier(first)?.identifier))
                } else {
                    rawSlots.append((frame, ownerPID, nil))
                }
            }
            let slots = rawSlots.map { raw in
                DrawnSlotRecord(displayID: displayID,
                                frame: raw.frame,
                                ownerPID: raw.pid,
                                ownerBundleID: raw.identifier == nil ? raw.pid.flatMap { bundleByPID[$0] } : nil,
                                axIdentifier: raw.identifier,
                                isOverflowed: OverflowClassifier.isOverflowed(slot: raw.frame, chevron: chevron))
            }.sorted { $0.frame.minX < $1.frame.minX }
            bars.append(DisplayBarRecord(displayID: displayID, isMain: display?.isMain ?? false, barFrame: windowFrame,
                                         chevronFrame: chevron, chevronExpanded: chevronExpanded, slots: slots))
        }
        bars.sort { ($0.isMain ? 0 : 1, $0.barFrame.minX) < ($1.isMain ? 0 : 1, $1.barFrame.minX) }
        return DrawnSnapshot(displays: bars, capturedAt: Date(), isReadable: true)
    }

    // MARK: Pressable handles

    /// The pressable element of an app's `index`-th item, read fresh.
    static func appItemHandle(pid: pid_t, index: Int) -> ItemHandle? {
        let app = AX.application(pid, timeout: 0.5)
        guard let bar = AX.element(app, AX.extrasMenuBarAttribute) else { return nil }
        let items = AX.children(bar)
        guard items.indices.contains(index) else { return nil }
        let item = items[index]
        for target in [item] + AX.children(item) where AX.actions(target).contains(kAXPressAction as String) {
            return ItemHandle(element: target, ownerPID: pid, frame: AX.frame(target) ?? AX.frame(item))
        }
        return ItemHandle(element: item, ownerPID: pid, frame: AX.frame(item))
    }

    /// The pressable element of a MenuBarAgent-hosted extra (`com.apple.menuextra.*`).
    static func hostedItemHandle(agentPID: pid_t, identifier: String) -> ItemHandle? {
        let agent = AX.application(agentPID, timeout: 0.5)
        guard let bar = AX.element(agent, AX.extrasMenuBarAttribute) else { return nil }
        for child in AX.children(bar) {
            if let hosted = AX.hostedIdentifier(child), hosted.identifier == identifier {
                return ItemHandle(element: hosted.item, ownerPID: agentPID, frame: AX.frame(hosted.item))
            }
        }
        return nil
    }

    // MARK: Async wrappers

    static func readExtras(of apps: [RunningAppRecord], excluding ownPID: pid_t) async -> [AppExtrasRecord] {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: readExtras(of: apps, excluding: ownPID)) }
        }
    }

    static func readDrawn(agentPID: pid_t?, bundleByPID: [pid_t: String], displays: [DisplayGeometry]) async -> DrawnSnapshot {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: readDrawn(agentPID: agentPID, bundleByPID: bundleByPID, displays: displays)) }
        }
    }

    static func onQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }
}
