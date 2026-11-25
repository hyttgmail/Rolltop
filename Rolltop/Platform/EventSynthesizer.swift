import ApplicationServices
import CoreGraphics
import Foundation

/// Synthetic mouse clicks and the paste keystroke. Posting events needs Device Control and
/// Data Access (Accessibility).
nonisolated enum EventSynthesizer {
    enum Button: String, Sendable {
        case left
        case right
    }

    /// Stamped into `eventSourceUserData` of every event Rolltop posts, so our own event
    /// monitors can ignore them ('RLTP').
    static let tag: Int64 = 0x524C_5450

    static func isSynthesized(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == tag
    }

    static var pointerLocation: CGPoint? { CGEvent(source: nil)?.location }

    /// Builds a tagged down/up pair: private event source, no modifiers, click state 1.
    static func clickEvents(at point: CGPoint, button: Button) -> [CGEvent]? {
        guard let source = CGEventSource(stateID: .privateState) else { return nil }
        let (downType, upType, cgButton): (CGEventType, CGEventType, CGMouseButton) = switch button {
        case .left: (.leftMouseDown, .leftMouseUp, .left)
        case .right: (.rightMouseDown, .rightMouseUp, .right)
        }
        guard let down = CGEvent(mouseEventSource: source, mouseType: downType, mouseCursorPosition: point, mouseButton: cgButton),
              let up = CGEvent(mouseEventSource: source, mouseType: upType, mouseCursorPosition: point, mouseButton: cgButton) else { return nil }
        for event in [down, up] {
            event.flags = []
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.setIntegerValueField(.eventSourceUserData, value: tag)
        }
        return [down, up]
    }

    /// Posts a click at `point` (global top-left) and, when asked, puts the pointer back
    /// where it was. Blocks for ~60 ms: call off the main thread.
    @discardableResult
    static func click(at point: CGPoint, button: Button, restorePointer: Bool = true) -> Bool {
        guard let events = clickEvents(at: point, button: button) else { return false }
        let saved = restorePointer ? pointerLocation : nil
        events[0].post(tap: .cghidEventTap)
        usleep(30_000)
        events[1].post(tap: .cghidEventTap)
        if let saved, saved != point {
            usleep(30_000)
            CGWarpMouseCursorPosition(saved)
        }
        return true
    }

    // MARK: - Paste (⌘V)

    /// One key event of a synthesized keystroke, without the event itself (testable).
    struct KeyStroke: Equatable, Sendable {
        var keyCode: CGKeyCode
        var flags: CGEventFlags
        var isKeyDown: Bool
    }

    /// `kVK_ANSI_V`: the V key's virtual key code (ANSI layout position; ⌘V follows the
    /// key position like the system's own paste shortcut).
    static let pasteKeyCode: CGKeyCode = 9

    /// ⌘V as posted: V down then V up, both carrying only the Command flag. No separate
    /// Command key events are posted, so no modifier stays pressed afterwards.
    static let pasteKeyStrokes: [KeyStroke] = [
        KeyStroke(keyCode: pasteKeyCode, flags: .maskCommand, isKeyDown: true),
        KeyStroke(keyCode: pasteKeyCode, flags: .maskCommand, isKeyDown: false),
    ]

    /// Builds tagged keyboard events for `strokes` from `source` (nil: no source). Posts nothing.
    static func keyEvents(for strokes: [KeyStroke], source: CGEventSource?) -> [CGEvent]? {
        var events: [CGEvent] = []
        for stroke in strokes {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: stroke.keyCode, keyDown: stroke.isKeyDown) else {
                return nil
            }
            event.flags = stroke.flags
            event.setIntegerValueField(.eventSourceUserData, value: tag)
            events.append(event)
        }
        return events
    }

    /// Posts one ⌘V to the frontmost app. Returns false without posting when Rolltop is not
    /// trusted for Device Control and Data Access (`AXIsProcessTrusted`) or the events
    /// cannot be created.
    ///
    /// Caller's precondition: Rolltop's own surface (Shelf, palette) is already closed and the
    /// app the user was working in is frontmost again (`TransientSurfaceCoordinator` hands
    /// activation back when a surface closes by the user's choice); otherwise the paste
    /// lands in Rolltop. The clipboard already holds what should be pasted.
    ///
    /// Events come from a `.combinedSessionState` source that suppresses the user's local
    /// keyboard events for the suppression interval (mouse and system-defined events still
    /// pass), carry `.maskCommand` themselves, and go to `.cgSessionEventTap`, the approach
    /// clipboard managers use. PLATFORM §10 explains why Rolltop's clicks are flag-less; a key
    /// event has to carry the flag, and no Command key-down is ever posted.
    ///
    /// **Unverified on this Mac until the user tries it.** No test, probe or Debug command
    /// may call it: tests never post keys on this Mac.
    @discardableResult
    static func postPaste() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        source.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents, .permitSystemDefinedEvents],
                                                          state: .eventSuppressionStateSuppressionInterval)
        guard let events = keyEvents(for: pasteKeyStrokes, source: source) else { return false }
        for event in events { event.post(tap: .cgSessionEventTap) }
        return true
    }
}
