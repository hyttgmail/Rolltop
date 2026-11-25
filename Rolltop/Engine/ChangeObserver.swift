import Foundation
import Observation

/// Runs `onChange` on the main actor after any `@Observable` property read inside
/// `track` changes, then tracks again. Changes within one main-actor turn coalesce
/// into one call. Keep the returned object alive; `cancel()` or deinit stops it.
///
///     observer = ChangeObserver(track: { _ = engine.level }) { [weak self] in self?.update() }
final class ChangeObserver {
    private let track: () -> Void
    private let onChange: () -> Void
    private var isActive = true

    init(track: @escaping () -> Void, onChange: @escaping () -> Void) {
        self.track = track
        self.onChange = onChange
        register()
    }

    func cancel() { isActive = false }

    private func register() {
        guard isActive else { return }
        withObservationTracking { track() } onChange: { [weak self] in
            Task { @MainActor in self?.fire() }
        }
    }

    private func fire() {
        guard isActive else { return }
        onChange()
        register()
    }
}
