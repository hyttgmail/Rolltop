import AppKit
import Carbon.HIToolbox
import RolltopCore
import SwiftUI

/// Click to record a shortcut; Escape cancels, Delete clears, the × button clears too.
/// Shows the combination with the standard glyphs. Refuses combinations without ⌘, ⌥ or ⌃
/// (function keys excepted) and whatever `validate` refuses (e.g. a conflict).
final class ShortcutRecorderView: NSView {
    var combo: KeyCombo? {
        didSet {
            guard combo != oldValue else { return }
            needsDisplay = true
            setAccessibilityValue(displayText)
        }
    }

    var onChange: ((KeyCombo?) -> Void)?
    /// Returns a refusal message, or nil to accept.
    var validate: ((KeyCombo) -> String?)?
    var onRecordingChange: ((Bool) -> Void)?

    private(set) var isRecording = false {
        didSet {
            guard isRecording != oldValue else { return }
            needsDisplay = true
            onRecordingChange?(isRecording)
        }
    }

    private var liveModifiers: KeyModifiers = []
    private var message: String?
    private var messageTask: Task<Void, Never>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(String(localized: "Shortcut", table: "Hotkeys"))
        setAccessibilityHelp(String(localized: "Click, then type a shortcut. Escape cancels, Delete clears.", table: "Hotkeys"))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 24) }

    /// Where the centred text's baseline sits, so the control lines up with row labels.
    nonisolated static func baselineOffset(height: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        return ((height - (font.ascender - font.descender)) / 2 + font.ascender).rounded()
    }

    override var firstBaselineOffsetFromTop: CGFloat {
        Self.baselineOffset(height: bounds.height > 0 ? bounds.height : intrinsicContentSize.height)
    }

    override var lastBaselineOffsetFromBottom: CGFloat {
        let height = bounds.height > 0 ? bounds.height : intrinsicContentSize.height
        return height - Self.baselineOffset(height: height)
    }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill() }

    // MARK: Recording

    func startRecording() {
        guard !isRecording else { return }
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        liveModifiers = []
        message = nil
        isRecording = true
    }

    func stopRecording() {
        liveModifiers = []
        isRecording = false
    }

    /// Debug previews: draw the recording state without taking keyboard focus.
    func showRecordingStateForPreview(modifiers: KeyModifiers) {
        liveModifiers = modifiers
        isRecording = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if combo != nil, !isRecording, clearButtonRect.contains(point) {
            commit(nil)
            return
        }
        if isRecording { stopRecording() } else { startRecording() }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        needsDisplay = true
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        return super.resignFirstResponder()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopRecording() }
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            // Space or Return start recording, like pressing a button.
            if event.keyCode == UInt16(kVK_Space) || event.keyCode == UInt16(kVK_Return) { startRecording() } else { super.keyDown(with: event) }
            return
        }
        handle(event)
    }

    /// ⌘-combinations arrive here first; keep them from triggering menu items while recording.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        handle(event)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { return super.flagsChanged(with: event) }
        liveModifiers = Self.modifiers(event.modifierFlags)
        needsDisplay = true
    }

    private func handle(_ event: NSEvent) {
        switch KeyComboRules.decide(keyCode: event.keyCode, modifiers: Self.modifiers(event.modifierFlags)) {
        case .cancel:
            stopRecording()
        case .clear:
            commit(nil)
        case .reject(let rejection):
            switch rejection {
            case .needsModifier: flash(String(localized: "Add ⌘, ⌥ or ⌃", table: "Hotkeys"))
            case .modifierOnly: break
            }
        case .accept(let candidate):
            if let refusal = validate?(candidate) {
                flash(refusal)
            } else {
                commit(candidate)
            }
        }
    }

    private func commit(_ newCombo: KeyCombo?) {
        stopRecording()
        combo = newCombo
        onChange?(newCombo)
    }

    private func flash(_ text: String) {
        message = text
        needsDisplay = true
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.message = nil
            self?.needsDisplay = true
        }
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> KeyModifiers {
        var result: KeyModifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.shift) { result.insert(.shift) }
        return result
    }

    // MARK: Drawing

    private var displayText: String {
        combo.map(KeyComboFormatter.string(for:)) ?? String(localized: "Record shortcut", table: "Hotkeys")
    }

    private var clearButtonRect: NSRect {
        NSRect(x: bounds.maxX - 22, y: bounds.midY - 8, width: 16, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.setFill()
        shape.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        shape.lineWidth = isRecording ? 2 : 1
        shape.stroke()

        let text: String
        let color: NSColor
        if let message {
            text = message
            color = .systemRed
        } else if isRecording {
            text = liveModifiers.isEmpty ? String(localized: "Type shortcut", table: "Hotkeys") : KeyComboFormatter.modifierGlyphs(liveModifiers)
            color = .secondaryLabelColor
        } else if let combo {
            text = KeyComboFormatter.string(for: combo)
            color = .labelColor
        } else {
            text = String(localized: "Record shortcut", table: "Hotkeys")
            color = .placeholderTextColor
        }
        let font = message == nil && combo != nil && !isRecording
            ? NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            : NSFont.systemFont(ofSize: message == nil ? NSFont.systemFontSize : NSFont.smallSystemFontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        let showsClear = combo != nil && !isRecording && message == nil
        let textRect = bounds.insetBy(dx: 8, dy: 0).divided(atDistance: showsClear ? 18 : 0, from: .maxXEdge).remainder
        let size = (text as NSString).size(withAttributes: attributes)
        let drawRect = NSRect(x: textRect.minX, y: textRect.midY - size.height / 2, width: textRect.width, height: size.height)
        (text as NSString).draw(in: drawRect, withAttributes: attributes)

        if showsClear, let image = NSImage(systemSymbolName: "xmark.circle.fill",
                                           accessibilityDescription: String(localized: "Clear", table: "Hotkeys")) {
            let configured = image.withSymbolConfiguration(.init(paletteColors: [.tertiaryLabelColor])) ?? image
            configured.draw(in: clearButtonRect)
        }
    }
}

/// SwiftUI wrapper around `ShortcutRecorderView`.
struct ShortcutRecorder: NSViewRepresentable {
    @Binding var combo: KeyCombo?
    var validate: (KeyCombo) -> String? = { _ in nil }
    var onRecordingChange: (Bool) -> Void = { _ in }
    /// Debug previews only: draw as if recording with these modifiers held.
    var previewRecordingModifiers: KeyModifiers?

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let view = ShortcutRecorderView(frame: NSRect(x: 0, y: 0, width: 150, height: 24))
        view.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        return view
    }

    func updateNSView(_ view: ShortcutRecorderView, context: Context) {
        view.combo = combo
        view.validate = validate
        view.onRecordingChange = onRecordingChange
        view.onChange = { newValue in combo = newValue }
        if let modifiers = previewRecordingModifiers { view.showRecordingStateForPreview(modifiers: modifiers) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ShortcutRecorderView, context: Context) -> CGSize? {
        CGSize(width: 150, height: 24)
    }
}

extension View {
    /// Aligns a `ShortcutRecorder` with the text baseline of its row's label.
    func recorderBaseline() -> some View {
        alignmentGuide(.firstTextBaseline) { ShortcutRecorderView.baselineOffset(height: $0.height) }
            .alignmentGuide(.lastTextBaseline) { ShortcutRecorderView.baselineOffset(height: $0.height) }
    }
}

/// A recorder bound to an action through the `.hotkeyBindings` service, with its status
/// line (conflict, macOS shortcut, registration failure). Other features may embed it.
struct HotkeyRecorderField: View {
    let context: AppContext
    let action: HotkeyAction

    var body: some View {
        let service = context.services[.hotkeyBindings]
        let _ = service.revision
        let problem = service.problem(for: action.command, arguments: action.arguments)
        VStack(alignment: .trailing, spacing: 2) {
            ShortcutRecorder(
                combo: Binding(get: { service.shortcut(for: action.command, arguments: action.arguments) },
                               set: { service.setShortcut($0, for: action.command, arguments: action.arguments) }),
                validate: { combo in
                    service.conflictingTitle(for: combo, excluding: action.command, arguments: action.arguments)
                        .map { String(localized: "Used by “\($0)”", table: "Hotkeys") }
                },
                onRecordingChange: { service.setRecording($0) })
            .recorderBaseline()
            if let problem {
                Text(problem.message(title: service.title(for:)))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 260, alignment: .trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
