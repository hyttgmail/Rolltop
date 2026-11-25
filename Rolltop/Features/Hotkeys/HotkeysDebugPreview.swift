#if DEBUG
import AppKit
import Carbon.HIToolbox
import RolltopCore
import SwiftUI

/// Debug-only stand-in for the settings window (which another feature builds): shows one
/// pane in a plain window so it can be captured with `screencapture -l <window id>`.
final class HotkeysDebugPreview {
    private let context: AppContext
    private let controller: HotkeyController
    private var window: NSWindow?
    private let log = Log.logger("hotkeys")

    init(context: AppContext, controller: HotkeyController) {
        self.context = context
        self.controller = controller
    }

    func show(_ pane: String) {
        if pane == "close" {
            window?.close()
            window = nil
            return
        }
        let content: AnyView
        switch pane {
        case "reveal":
            content = context.settingsPanes.pane("reveal")?.makeView() ?? AnyView(Text(verbatim: "No reveal pane"))
        case "recorder":
            content = AnyView(RecorderStatesPreview())
        default:
            content = AnyView(HotkeysSettingsView(context: context, controller: controller))
        }
        let window = window ?? makeWindow()
        self.window = window
        window.title = "Preview – \(pane)"
        window.contentView = NSHostingView(rootView: content.frame(width: 640, height: pane == "recorder" ? 400 : 1100))
        if let screen = NSScreen.screens.first {
            window.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.minX + 60, y: screen.visibleFrame.maxY - 40))
        }
        window.orderFrontRegardless()
        log.notice("debug preview \(pane): window \(window.windowNumber) frame \(NSStringFromRect(window.frame))")
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 760),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = .floating
        return window
    }
}

/// The recorder in each of its states.
private struct RecorderStatesPreview: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("Empty") { ShortcutRecorder(combo: .constant(nil)).recorderBaseline() }
                LabeledContent("Set") {
                    ShortcutRecorder(combo: .constant(KeyCombo(keyCode: UInt16(kVK_ANSI_H), modifiers: [.control, .option, .command])))
                        .recorderBaseline()
                }
                LabeledContent("Function key") {
                    ShortcutRecorder(combo: .constant(KeyCombo(keyCode: UInt16(kVK_F5), modifiers: []))).recorderBaseline()
                }
                LabeledContent("Recording, ⌥⌘ held") {
                    ShortcutRecorder(combo: .constant(nil), previewRecordingModifiers: [.option, .command]).recorderBaseline()
                }
                LabeledContent("Recording, nothing held") {
                    ShortcutRecorder(combo: .constant(nil), previewRecordingModifiers: []).recorderBaseline()
                }
            } header: {
                Text(verbatim: "Shortcut recorder states")
            }
        }
        .formStyle(.grouped)
    }
}
#endif
