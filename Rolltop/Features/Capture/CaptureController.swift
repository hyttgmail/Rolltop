import AppKit
import Foundation
import RolltopCore

/// Decides when to capture the menu bar and feeds the cache.
///
/// Captures when the set of drawn items or a frame changes (not on mere re-reads), at most
/// once per `minimumInterval`, never while a restriction change is in flight or settling,
/// while an item interaction is active, or while a menu is open (a highlighted slot would be
/// cached). Re-reads list B right before and after capturing and discards the pass when
/// anything moved. Idle otherwise. Never runs without the setting and the Screen Recording
/// grant (so it can never prompt).
final class CaptureController {
    struct Report: Codable, Sendable {
        var startedAt: Date
        var durationMS: Int
        var slots: Int
        var captured: Int
        var changed: Int
        var displays: [UInt32]
        var transparent: [Bool]
        var outcome: String
    }

    var minimumInterval: Duration = .seconds(1)
    var settleAfterRestriction: Duration = .milliseconds(900)
    private(set) var lastReport: Report?

    private unowned let context: AppContext
    private let cache: ItemImageCache
    private let provider: CapturedItemImageProvider
    private let capturer: any MenuBarCapturing
    private var drawnObserver: ChangeObserver?
    private var restrictionObserver: ChangeObserver?
    /// The slots of the last stored capture.
    private var lastSlots: [CaptureSlot]?
    private var lastCaptureAt: ContinuousClock.Instant?
    private var lastRestrictionChange = ContinuousClock.now - .seconds(60)
    private var scheduled: Task<Void, Never>?
    private var isCapturing = false
    private var failures = 0
    private var backoffUntil: ContinuousClock.Instant?
    private var lastEligible: Bool?
    private var didInitialPrune = false
    private let log = Log.logger("capture")

    init(context: AppContext, cache: ItemImageCache, provider: CapturedItemImageProvider,
         capturer: any MenuBarCapturing = ScreenCaptureKitCapturer()) {
        self.context = context
        self.cache = cache
        self.provider = provider
        self.capturer = capturer
    }

    func start() {
        let catalog = context.catalog, permissions = context.permissions, settings = context.settings
        let visibility = context.visibility
        drawnObserver = ChangeObserver(track: {
            _ = catalog.drawn
            _ = permissions.screenRecording
            _ = settings[CaptureSettings.enabled]
        }) { [weak self] in self?.inputsChanged() }
        restrictionObserver = ChangeObserver(track: {
            _ = visibility.appliedAllowList
            _ = visibility.plannedAllowList
            _ = visibility.isApplying
            _ = visibility.temporaryAllows
        }) { [weak self] in self?.lastRestrictionChange = .now }
        inputsChanged()
    }

    func stop() {
        drawnObserver?.cancel()
        restrictionObserver?.cancel()
        scheduled?.cancel()
        scheduled = nil
    }

    /// Forget what was captured so the next change (or `capture(force:)`) captures again.
    func resetSignature() { lastSlots = nil }

    private var isEligible: Bool { context.settings[CaptureSettings.enabled] && context.permissions.screenRecording }

    private func currentSlots(_ snapshot: DrawnSnapshot) -> [CaptureSlot] {
        var listA: [OwnerID: [CGRect]] = [:]
        for entry in context.catalog.entries { if let owner = entry.owner { listA[owner] = entry.lastKnownFrames } }
        return CaptureGeometry.slots(in: snapshot, ownBundleIDs: context.ownBundleIDs, listAFrames: listA)
    }

    private func inputsChanged() {
        pruneAfterFirstRefresh()
        let eligible = isEligible
        if lastEligible != nil, lastEligible != eligible {
            // What `image(for:)` serves changed (captures ↔ app icons).
            provider.noteChanged()
        }
        lastEligible = eligible
        guard eligible else {
            scheduled?.cancel()
            scheduled = nil
            return
        }
        let slots = currentSlots(context.catalog.drawn)
        guard !slots.isEmpty, !isUnchanged(slots) else { return }
        schedule(after: .milliseconds(250))
    }

    /// Prunes once the catalog has been read, with present owners marked seen first, so a
    /// long pause never drops the images of hidden items that are still running.
    private func pruneAfterFirstRefresh() {
        guard !didInitialPrune, context.catalog.lastRefresh != nil else { return }
        didInitialPrune = true
        cache.markSeen(context.catalog.presentOwners.map(\.stringValue))
        cache.prune()
    }

    private func schedule(after delay: Duration) {
        guard scheduled == nil else { return }
        scheduled = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.scheduled = nil
            await self.attempt()
        }
    }

    private func attempt() async {
        guard isEligible else { return }
        if let wait = waitTime() {
            schedule(after: wait)
            return
        }
        guard !isUnchanged(currentSlots(context.catalog.drawn)) else { return }
        await capture(force: false)
    }

    private func isUnchanged(_ slots: [CaptureSlot]) -> Bool {
        lastSlots.map { CaptureGeometry.sameLayout($0, slots) } ?? false
    }

    private func waitTime() -> Duration? {
        let now = ContinuousClock.now
        if let backoffUntil, now < backoffUntil { return backoffUntil - now }
        if let last = lastCaptureAt, now - last < minimumInterval { return minimumInterval - (now - last) }
        if isBusy { return .milliseconds(500) }
        return nil
    }

    private var isBusy: Bool {
        let visibility = context.visibility
        return visibility.isApplying || visibility.isInteractionActive
            || ContinuousClock.now - lastRestrictionChange < settleAfterRestriction
            || Self.isMenuOpen(excluding: ProcessInfo.processInfo.processIdentifier)
    }

    /// A pop-up menu or panel (layer 101…999) is on screen.
    static func isMenuOpen(excluding ownPID: pid_t) -> Bool {
        WindowList.onScreen().contains { window in
            (WindowList.popUpMenuLayer..<1000).contains(window.layer) && window.ownerPID != ownPID
                && window.bounds.width > 4 && window.bounds.height > 4
        }
    }

    /// One capture pass. `force` skips the busy checks (Debug `capture.debug-refresh`), never the
    /// permission check.
    @discardableResult
    func capture(force: Bool) async -> Report {
        let startedAt = Date(), started = ContinuousClock.now
        func report(_ outcome: String, slots: Int = 0, captured: Int = 0, changed: Int = 0,
                    bars: [BarCapture] = []) -> Report {
            let report = Report(startedAt: startedAt, durationMS: Int((ContinuousClock.now - started) / .milliseconds(1)),
                                slots: slots, captured: captured, changed: changed,
                                displays: bars.map(\.displayID), transparent: bars.map(\.isTransparent), outcome: outcome)
            lastReport = report
            log.debug("capture: \(outcome), \(captured)/\(slots) items, \(changed) changed, \(report.durationMS) ms")
            return report
        }
        guard isEligible else { return report("not-eligible") }
        guard !isCapturing else { return report("already-capturing") }
        isCapturing = true
        defer { isCapturing = false }

        let restrictionMark = lastRestrictionChange
        let before = currentSlots(await context.catalog.refreshDrawn())
        guard !before.isEmpty else { return report("nothing-drawn") }
        if !force, isBusy {
            schedule(after: .milliseconds(500))
            return report("busy", slots: before.count)
        }
        var bars: [UInt32: CGRect] = [:]
        for display in context.catalog.drawn.displays where before.contains(where: { $0.displayID == display.displayID }) {
            bars[display.displayID] = display.barFrame
        }
        let captures: [BarCapture]
        // Every pass that reaches ScreenCaptureKit counts for the throttle, discarded or not.
        defer { lastCaptureAt = .now }
        do {
            captures = try await capturer.captureBars(bars)
        } catch {
            failures += 1
            let seconds = min(60, 1 << min(failures, 6))
            backoffUntil = .now + .seconds(seconds)
            log.error("capture failed (\(failures)×, retry in \(seconds) s): \(error.localizedDescription)")
            schedule(after: .seconds(seconds))
            return report("error: \(error.localizedDescription)", slots: before.count)
        }
        let slots = before
        let items = await Task.detached(priority: .utility) {
            CapturePipeline.extract(slots: slots, bars: captures)
        }.value

        // Discard when the bar moved meanwhile: a crop could hold a neighbour.
        let after = currentSlots(await context.catalog.refreshDrawn())
        if !CaptureGeometry.sameLayout(before, after) {
            let moved = Set(CaptureGeometry.signature(of: before)).symmetricDifference(CaptureGeometry.signature(of: after)).sorted()
            log.debug("capture discarded, slots moved: \(moved.prefix(6).joined(separator: " | "))")
            schedule(after: .milliseconds(500))
            return report("discarded-moved", slots: before.count, bars: captures)
        }
        guard lastRestrictionChange == restrictionMark, !context.visibility.isApplying else {
            schedule(after: .milliseconds(500))
            return report("discarded-restriction-changed", slots: before.count, bars: captures)
        }
        failures = 0
        backoffUntil = nil
        let changed = cache.store(items)
        lastSlots = before
        cache.markSeen(context.catalog.presentOwners.map(\.stringValue))
        if !changed.isEmpty { provider.noteChanged() }
        return report("ok", slots: before.count, captured: items.count, changed: changed.count, bars: captures)
    }
}
