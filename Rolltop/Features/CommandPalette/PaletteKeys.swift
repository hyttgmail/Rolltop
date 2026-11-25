import AppKit

/// Which mouse button an item row is clicked with.
nonisolated enum PaletteClick: String, Sendable, Equatable {
    case left
    case right
}

/// Key handling of the palette. Pure, so it is tested with plain values and with real
/// `NSEvent`s delivered to the panel.
nonisolated enum PaletteKeys {
    enum Action: Equatable, Sendable {
        /// Move the selection by this many rows.
        case move(Int)
        /// Run the selected row; `.right` right-clicks an item.
        case runSelected(PaletteClick)
        /// ⌘Return: run the selected row's second action, or the row itself when it has none.
        case runSelectedSecond
        /// Run the n-th row (0-based) of the results (⌘1…⌘9).
        case runIndex(Int)
        case close
        /// Consumed without effect (⌘Q, ⌘, and Tab while the panel is open).
        case swallow
    }

    /// Virtual key codes (kVK_*).
    enum Code {
        static let returnKey: UInt16 = 36
        static let keypadEnter: UInt16 = 76
        static let escape: UInt16 = 53
        static let tab: UInt16 = 48
        static let down: UInt16 = 125
        static let up: UInt16 = 126
        static let pageDown: UInt16 = 121
        static let pageUp: UInt16 = 116
        static let n: UInt16 = 45
        static let p: UInt16 = 35
        static let w: UInt16 = 13
        static let q: UInt16 = 12
        static let comma: UInt16 = 43
        /// ⌘1…⌘9 on the number row, in order.
        static let digits: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
    }

    /// The action for a key down, nil to let the search field have it (text, editing keys,
    /// ⌘A/C/V/X/Z through the Edit menu). While an input method is composing
    /// (`hasMarkedText`), every key belongs to it: Return and the arrows pick candidates.
    /// `pageRows`: rows moved by Page Up/Down.
    static func action(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, characters: String?,
                       hasMarkedText: Bool, pageRows: Int = 8) -> Action? {
        if hasMarkedText { return nil }
        let flags = modifiers.intersection([.command, .control, .option, .shift])
        let letter = characters?.lowercased()
        func isKey(_ code: UInt16, _ character: String) -> Bool { keyCode == code || letter == character }

        if flags.contains(.command) {
            if flags == .command, let index = Code.digits.firstIndex(of: keyCode) { return .runIndex(index) }
            if flags == .command, isKey(Code.w, "w") { return .close }
            if isKey(Code.q, "q") || isKey(Code.comma, ",") { return .swallow }
            if keyCode == Code.returnKey || keyCode == Code.keypadEnter {
                return flags == .command ? .runSelectedSecond : .runSelected(.left)
            }
            return nil
        }
        switch keyCode {
        case Code.returnKey, Code.keypadEnter:
            return .runSelected(flags.contains(.shift) || flags.contains(.control) ? .right : .left)
        case Code.escape:
            return .close
        case Code.down:
            return .move(1)
        case Code.up:
            return .move(-1)
        case Code.pageDown:
            return .move(pageRows)
        case Code.pageUp:
            return .move(-pageRows)
        case Code.tab:
            return .swallow
        default:
            break
        }
        if flags == .control {
            if isKey(Code.n, "n") { return .move(1) }
            if isKey(Code.p, "p") { return .move(-1) }
        }
        return nil
    }
}
