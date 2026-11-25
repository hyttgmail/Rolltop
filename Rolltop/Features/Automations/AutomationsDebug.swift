#if DEBUG
import AppKit
import RolltopCore
import SwiftUI

/// Debug-build commands for live tests: load rules from a file (optionally allowing their
/// scripts), remove a rule, dump the engine state, and show the pane in a plain window.
enum AutomationsDebugCommands {
    static func commands(controller: AutomationsController, context: AppContext, location: any LocationProviding,
                         placeTracker: AutomationPlaceTracker) -> [Command] {
        [
            // A simulated fix replaces the service's (use fixed public coordinates only);
            // `clear=1` goes back to the service.
            Command(id: "automations.debug-inject-location", title: "Inject Automation Location", symbol: "location",
                    arguments: [CommandArgument(name: "lat", title: "Latitude", isRequired: false),
                                CommandArgument(name: "lon", title: "Longitude", isRequired: false),
                                CommandArgument(name: "accuracy", title: "Accuracy", isRequired: false),
                                CommandArgument(name: "clear", title: "Clear", isRequired: false, allowedValues: ["1"])],
                    allowedFromURL: true) { invocation in
                if invocation.string("clear") == "1" {
                    placeTracker.inject(nil)
                    return
                }
                guard let lat = Double(try invocation.require("lat")), abs(lat) <= 90 else {
                    throw CommandError.invalidArgument("lat", invocation.string("lat") ?? "")
                }
                guard let lon = Double(try invocation.require("lon")), abs(lon) <= 180 else {
                    throw CommandError.invalidArgument("lon", invocation.string("lon") ?? "")
                }
                let accuracy = invocation.string("accuracy").flatMap(Double.init) ?? 65
                placeTracker.inject(AutomationLocationFix(latitude: lat, longitude: lon, accuracy: accuracy))
            },
            Command(id: "automations.debug-load", title: "Load Automation Rules from Path", symbol: "square.and.arrow.down",
                    arguments: [CommandArgument(name: "path", title: "Path"),
                                CommandArgument(name: "approve-scripts", title: "Allow scripts", isRequired: false,
                                                allowedValues: ["yes", "no"])],
                    allowedFromURL: true) { invocation in
                let url = try DebugFiles.inputURL(try invocation.require("path"))
                let data = try Data(contentsOf: url)
                let list = try JSONDecoder().decode(AutomationRuleList.self, from: data)
                let approve = invocation.string("approve-scripts") == "yes"
                for rule in list.rules {
                    controller.delete(id: rule.id)
                    controller.add(rule, approvingScripts: approve ? Set(rule.scriptConditions.map(\.id)) : [])
                }
            },
            Command(id: "automations.debug-remove", title: "Remove Automation Rule", symbol: "trash",
                    arguments: [CommandArgument(name: "id", title: "Rule")], allowedFromURL: true) { invocation in
                controller.delete(id: try invocation.require("id"))
            },
            Command(id: "automations.debug-dump", title: "Dump Automations", symbol: "ladybug", allowedFromURL: true) { _ in
                try dump(controller: controller, context: context, placeTracker: placeTracker)
            },
            Command(id: "automations.debug-window", title: "Show Automations Pane in a Window", symbol: "macwindow",
                    arguments: [CommandArgument(name: "edit", title: "Rule to edit", isRequired: false)],
                    allowedFromURL: true) { invocation in
                AutomationsDebugWindow.shared.show(context: context, controller: controller, location: location,
                                                   editing: invocation.string("edit"))
            },
            Command(id: "automations.debug-window-close", title: "Close Automations Pane Window", symbol: "xmark",
                    allowedFromURL: true) { _ in
                AutomationsDebugWindow.shared.close()
            },
        ]
    }

    struct Dump: Encodable {
        struct Rule: Encodable {
            let id: String
            let name: String
            let enabled: Bool
            let active: Bool
            let pending: Bool
            let raw: Bool
            let conditions: [String: Bool]
            let showItems: [String]
            let log: [String]
        }
        struct Script: Encodable {
            let conditionID: String
            let exitStatus: Int32?
            let timedOut: Bool
            let output: String
            let finishedAt: Date
        }
        let writtenAt: Date
        let paused: Bool
        let stability: Double
        let power: String
        let batteryLevel: Int?
        let charging: Bool?
        let wifiConnected: Bool
        let canReadNetworkName: Bool
        let runningAppCount: Int
        let frontmost: String?
        let displays: Int
        let builtInDisplays: Int
        let scripts: [Script]
        let approvals: Int
        let forcedVisible: [String: [String]]
        let ledgerRules: [String]
        /// "none", "service" or "injected"; never coordinates.
        let location: String
        let locationAccuracy: Double?
        let locationUpdatesRunning: Bool
        /// By place condition id: "true", "false" or "unknown".
        let places: [String: String]
        let rules: [Rule]
    }

    static func dump(controller: AutomationsController, context: AppContext, placeTracker: AutomationPlaceTracker) throws {
        let environment = controller.environment
        let stamp = ISO8601DateFormatter()
        let dump = Dump(
            writtenAt: Date(), paused: controller.isPaused, stability: controller.stability,
            power: environment.power.source.rawValue, batteryLevel: environment.power.level, charging: environment.power.isCharging,
            wifiConnected: environment.wifi.isConnected, canReadNetworkName: environment.wifi.canReadNetworkName,
            runningAppCount: environment.apps.running.count, frontmost: environment.apps.frontmost,
            displays: environment.displays.count, builtInDisplays: environment.displays.builtInCount,
            scripts: environment.scripts.map {
                Dump.Script(conditionID: $0.key, exitStatus: $0.value.exitStatus, timedOut: $0.value.timedOut,
                            output: $0.value.output, finishedAt: $0.value.finishedAt)
            },
            approvals: controller.approvals.keys.count,
            forcedVisible: context.visibility.forcedVisible.mapValues { $0.map(\.stringValue).sorted() },
            ledgerRules: controller.ledgerForDebugging.entries.map(\.ruleID),
            location: environment.location == nil ? "none" : (placeTracker.injected != nil ? "injected" : "service"),
            locationAccuracy: environment.location?.accuracy,
            locationUpdatesRunning: placeTracker.isRunning,
            places: Dictionary(uniqueKeysWithValues: controller.rules.flatMap(\.placeConditions).map { item in
                (item.id, environment.placeHolds(item.condition, id: item.id).map { $0 ? "true" : "false" } ?? "unknown")
            }),
            rules: controller.rules.map { rule in
                Dump.Rule(id: rule.id, name: rule.name, enabled: rule.isEnabled, active: controller.isActive(rule.id),
                          pending: controller.isPending(rule.id),
                          raw: AutomationEvaluator.evaluate(rule, in: environment),
                          conditions: Dictionary(uniqueKeysWithValues: rule.conditions.map {
                              ("\($0.kind.typeName):\($0.id)", controller.conditionHolds($0))
                          }),
                          showItems: rule.actions.showItems.map(\.stringValue),
                          log: (controller.logs[rule.id] ?? []).map {
                              "\(stamp.string(from: $0.date)) \($0.kind.rawValue)\($0.message.map { " \($0)" } ?? "")"
                          })
            })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Rolltop/debug/automations.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(dump).write(to: url, options: .atomic)
    }
}

/// A plain window hosting the pane at a fixed place for screenshots. Debug builds only.
final class AutomationsDebugWindow {
    static let shared = AutomationsDebugWindow()
    static let size = CGSize(width: 680, height: 780)
    private var window: NSWindow?

    func show(context: AppContext, controller: AutomationsController, location: any LocationProviding, editing: String?) {
        close()
        // An editor is shown as the window's content (not a sheet) so one window capture holds it.
        var draft: AutomationEditorDraft?
        if let editing, let template = AutomationTemplate(rawValue: editing) {
            draft = AutomationEditorDraft(rule: template.makeRule(name: AutomationText.title(of: template)), controller: controller)
            draft?.isNew = true
            draft?.linkAppToItems = template == .appFrontmost
        } else if let editing, let rule = controller.rule(id: editing) {
            draft = AutomationEditorDraft(rule: rule, controller: controller)
        }
        let size = draft == nil ? Self.size : CGSize(width: 560, height: 820)
        let view: AnyView = if let draft {
            AnyView(AutomationRuleEditor(draft: draft, context: context, controller: controller, location: location) { [weak self] in
                self?.close()
            }.frame(width: size.width, height: size.height))
        } else {
            AnyView(AutomationsSettingsView(context: context, controller: controller, location: location)
                .frame(width: size.width, height: size.height))
        }
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = String(localized: "Automations", table: "Automations")
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        if let screen = NSScreen.main {
            window.setFrameTopLeftPoint(CGPoint(x: screen.frame.minX + 80, y: screen.visibleFrame.maxY - 40))
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        self.window = window
        let frame = ScreenGeometry.topLeftRect(fromAppKit: window.frame)
        let text = "{\"x\":\(Int(frame.minX)),\"y\":\(Int(frame.minY)),\"w\":\(Int(frame.width)),\"h\":\(Int(frame.height)),\"windowNumber\":\(window.windowNumber)}"
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Rolltop/debug/automations-window.json")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: url, options: .atomic)
    }

    func close() {
        window?.close()
        window = nil
    }
}
#endif
