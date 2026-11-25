import Foundation
import RolltopCore
import Testing
@testable import Rolltop

/// Gregorian calendar in UTC so weekdays and times are fixed.
private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

/// 2026-11-20 is a Friday.
private func date(day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    utc.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
}

private func environment(at date: Date = date(day: 20, 12)) -> AutomationEnvironment {
    AutomationEnvironment(now: date, calendar: utc)
}

@Suite struct AutomationTimeTests {
    private let friday = 6, saturday = 7, sunday = 1

    @Test func sameDayRangeIsHalfOpen() {
        let window = AutomationTimeCondition(weekdays: AutomationTimeCondition.workdays, start: 9 * 60, end: 17 * 60)
        #expect(AutomationEvaluator.contains(window, date: date(day: 20, 9), calendar: utc))
        #expect(AutomationEvaluator.contains(window, date: date(day: 20, 16, 59), calendar: utc))
        #expect(!AutomationEvaluator.contains(window, date: date(day: 20, 17), calendar: utc))
        #expect(!AutomationEvaluator.contains(window, date: date(day: 20, 8, 59), calendar: utc))
        #expect(!AutomationEvaluator.contains(window, date: date(day: 21, 10), calendar: utc))   // Saturday
    }

    @Test func rangeCrossingMidnightBelongsToItsStartDay() {
        let window = AutomationTimeCondition(weekdays: [friday], start: 22 * 60, end: 2 * 60)
        #expect(!AutomationEvaluator.contains(window, date: date(day: 20, 21, 59), calendar: utc))
        #expect(AutomationEvaluator.contains(window, date: date(day: 20, 22), calendar: utc))
        #expect(AutomationEvaluator.contains(window, date: date(day: 20, 23, 59), calendar: utc))
        #expect(AutomationEvaluator.contains(window, date: date(day: 21, 0), calendar: utc))      // Sat 00:00
        #expect(AutomationEvaluator.contains(window, date: date(day: 21, 1, 59), calendar: utc))
        #expect(!AutomationEvaluator.contains(window, date: date(day: 21, 2), calendar: utc))
        #expect(!AutomationEvaluator.contains(window, date: date(day: 21, 23), calendar: utc))    // Saturday not selected
        #expect(!AutomationEvaluator.contains(window, date: date(day: 20, 1), calendar: utc))     // Fri 01:00 belongs to Thursday
    }

    @Test func weekWrapsFromSaturdayToSunday() {
        let window = AutomationTimeCondition(weekdays: [saturday], start: 23 * 60, end: 60)
        #expect(AutomationEvaluator.contains(window, date: date(day: 22, 0, 30), calendar: utc))  // Sunday 00:30
        let sundayOnly = AutomationTimeCondition(weekdays: [sunday], start: 23 * 60, end: 60)
        #expect(!AutomationEvaluator.contains(sundayOnly, date: date(day: 22, 0, 30), calendar: utc))
        #expect(AutomationEvaluator.contains(sundayOnly, date: date(day: 23, 0, 30), calendar: utc)) // Monday 00:30
    }

    @Test func equalStartAndEndCoversWholeDays() {
        let window = AutomationTimeCondition(weekdays: [friday], start: 0, end: 0)
        #expect(AutomationEvaluator.contains(window, date: date(day: 20, 0), calendar: utc))
        #expect(AutomationEvaluator.contains(window, date: date(day: 20, 23, 59), calendar: utc))
        #expect(!AutomationEvaluator.contains(window, date: date(day: 21, 0), calendar: utc))
    }

    @Test func nextMinuteBoundary() {
        let next = AutomationEvaluator.nextMinuteBoundary(after: date(day: 20, 10, 15).addingTimeInterval(12.5), calendar: utc)
        #expect(next == date(day: 20, 10, 16))
    }
}

@Suite struct AutomationConditionTests {
    @Test func powerConditions() {
        var power = AutomationPowerState(source: .battery, isCharging: false, level: 15)
        func check(_ test: AutomationPowerCondition.Test, _ percent: Int = 20) -> Bool {
            AutomationEvaluator.evaluate(AutomationPowerCondition(test: test, percent: percent), power)
        }
        #expect(check(.onBattery))
        #expect(!check(.onAC))
        #expect(check(.notCharging))
        #expect(!check(.charging))
        #expect(check(.levelBelow, 20))
        #expect(!check(.levelBelow, 15))
        #expect(!check(.levelAbove, 15))
        power = AutomationPowerState(source: .ac, isCharging: true, level: 80)
        #expect(check(.onAC))
        #expect(check(.charging))
        #expect(check(.levelAbove, 79))
        // A desktop: no battery, nothing about levels or charging holds.
        power = AutomationPowerState(source: .ac, isCharging: nil, level: nil)
        #expect(!check(.levelBelow, 99))
        #expect(!check(.levelAbove, 1))
        #expect(!check(.charging))
        #expect(!check(.notCharging))
    }

    @Test func powerSourceParsing() {
        let battery: [String: Any] = ["Type": "InternalBattery", "Current Capacity": 42, "Max Capacity": 100, "Is Charging": true]
        let state = AutomationPowerReader.parse(providingType: "AC Power", descriptions: [["Type": "UPS"], battery])
        #expect(state == AutomationPowerState(source: .ac, isCharging: true, level: 42))
        #expect(AutomationPowerReader.parse(providingType: "Battery Power", descriptions: []).source == .battery)
        #expect(AutomationPowerReader.parse(providingType: nil, descriptions: []) == AutomationPowerState())
    }

    @Test func wifiConditions() {
        let named = AutomationWiFiCondition(test: .connectedTo, networks: ["Office ", "Home"])
        var wifi = AutomationWiFiState(isConnected: true, canReadNetworkName: true, networkName: "Office")
        #expect(AutomationEvaluator.evaluate(named, wifi))
        #expect(AutomationEvaluator.evaluate(AutomationWiFiCondition(test: .connected), wifi))
        #expect(!AutomationEvaluator.evaluate(AutomationWiFiCondition(test: .notConnected), wifi))
        wifi.networkName = "office"
        #expect(!AutomationEvaluator.evaluate(named, wifi))   // names are case-sensitive
        // Without Location permission the name is unknown: treated as false.
        wifi = AutomationWiFiState(isConnected: true, canReadNetworkName: false, networkName: "Office")
        #expect(!AutomationEvaluator.evaluate(named, wifi))
        wifi = AutomationWiFiState(isConnected: false, canReadNetworkName: true, networkName: nil)
        #expect(!AutomationEvaluator.evaluate(named, wifi))
        #expect(AutomationEvaluator.evaluate(AutomationWiFiCondition(test: .notConnected), wifi))
    }

    @Test func appConditions() {
        let apps = AutomationAppsState(running: ["com.a", "com.b"], frontmost: "com.b")
        #expect(AutomationEvaluator.evaluate(AutomationAppCondition(bundleID: "com.a", test: .running), apps))
        #expect(!AutomationEvaluator.evaluate(AutomationAppCondition(bundleID: "com.a", test: .frontmost), apps))
        #expect(AutomationEvaluator.evaluate(AutomationAppCondition(bundleID: "com.b", test: .frontmost), apps))
        #expect(AutomationEvaluator.evaluate(AutomationAppCondition(bundleID: "com.c", test: .notRunning), apps))
        #expect(AutomationEvaluator.evaluate(AutomationAppCondition(bundleID: "com.a", test: .notFrontmost), apps))
        #expect(!AutomationEvaluator.evaluate(AutomationAppCondition(bundleID: "", test: .notRunning), apps))
    }

    @Test func displayConditions() {
        let laptop = AutomationDisplaysState(count: 1, builtInCount: 1)
        let desk = AutomationDisplaysState(count: 2, builtInCount: 1)
        let closedLid = AutomationDisplaysState(count: 1, builtInCount: 0)
        #expect(AutomationEvaluator.evaluate(AutomationDisplayCondition(test: .builtInOnly), laptop))
        #expect(!AutomationEvaluator.evaluate(AutomationDisplayCondition(test: .builtInOnly), desk))
        #expect(AutomationEvaluator.evaluate(AutomationDisplayCondition(test: .externalConnected), desk))
        #expect(AutomationEvaluator.evaluate(AutomationDisplayCondition(test: .externalConnected), closedLid))
        #expect(AutomationEvaluator.evaluate(AutomationDisplayCondition(test: .countAtLeast, count: 2), desk))
        #expect(!AutomationEvaluator.evaluate(AutomationDisplayCondition(test: .countExactly, count: 2), laptop))
    }

    @Test func scriptAndItemChangedConditions() {
        let script = AutomationCondition(id: "s", .script(AutomationScriptCondition(command: "true")))
        var env = environment()
        #expect(!AutomationEvaluator.evaluate(script, in: env))   // never ran
        env.scripts["s"] = AutomationScriptOutcome(finishedAt: env.now, exitStatus: 0)
        #expect(AutomationEvaluator.evaluate(script, in: env))
        env.scripts["s"] = AutomationScriptOutcome(finishedAt: env.now, exitStatus: 0, timedOut: true)
        #expect(!AutomationEvaluator.evaluate(script, in: env))
        env.scripts["s"] = AutomationScriptOutcome(finishedAt: env.now, exitStatus: 1)
        #expect(!AutomationEvaluator.evaluate(script, in: env))

        let owner = OwnerID.app("com.example.item")
        let changed = AutomationCondition(.itemChanged(AutomationItemChangedCondition(owner: owner, holdSeconds: 10)))
        #expect(!AutomationEvaluator.evaluate(changed, in: env))
        env.itemChanges[owner] = env.now.addingTimeInterval(-5)
        #expect(AutomationEvaluator.evaluate(changed, in: env))
        env.itemChanges[owner] = env.now.addingTimeInterval(-11)
        #expect(!AutomationEvaluator.evaluate(changed, in: env))
    }

    @Test func allAndAnyCombination() {
        var env = environment()
        env.power.source = .battery
        env.wifi.isConnected = true
        let onBattery = AutomationCondition(.power(.init(test: .onBattery)))
        let offline = AutomationCondition(.wifi(.init(test: .notConnected)))
        var rule = AutomationRule(name: "r", match: .all, conditions: [onBattery, offline])
        #expect(!AutomationEvaluator.evaluate(rule, in: env))
        rule.match = .any
        #expect(AutomationEvaluator.evaluate(rule, in: env))
        env.power.source = .ac
        #expect(!AutomationEvaluator.evaluate(rule, in: env))
        rule.conditions = []
        #expect(!AutomationEvaluator.evaluate(rule, in: env))   // no conditions: never active
        rule.match = .all
        #expect(!AutomationEvaluator.evaluate(rule, in: env))
    }
}

@Suite struct AutomationCodingTests {
    @Test func unknownConditionTypesRoundTripAndEvaluateFalse() throws {
        let json = """
        {"rules":[
          {"id":"r1","name":"Future","isEnabled":true,"match":"any","futureKey":1,
           "conditions":[
             {"id":"c1","type":"calendar-event","parameters":{"calendar":"Work","minutes":[5,10]}},
             {"id":"c2","type":"power","parameters":{"test":"on-battery"}},
             {"id":"c3","type":"power","parameters":{"test":"some-new-test"}},
             {"type":"time","parameters":{"weekdays":[2],"start":60,"end":120}}
           ],
           "actions":{"showItems":["system:battery","bad owner","com.example.app"],"futureAction":true}},
          {"name":"No id, skipped"},
          {"id":"r1","name":"Duplicate id, skipped"},
          {"id":"r2"}
        ]}
        """
        let list = try JSONDecoder().decode(AutomationRuleList.self, from: Data(json.utf8))
        #expect(list.rules.map(\.id) == ["r1", "r2"])
        let rule = list.rules[0]
        #expect(rule.match == .any)
        #expect(rule.conditions.count == 4)
        #expect(rule.conditions[0].kind == .unsupported(type: "calendar-event", parameters: .object([
            "calendar": .string("Work"), "minutes": .array([.number(5), .number(10)]),
        ])))
        #expect(rule.conditions[2].kind.typeName == "power")
        if case .unsupported = rule.conditions[2].kind {} else { Issue.record("an unknown power test should be kept verbatim") }
        #expect(!rule.conditions[3].id.isEmpty)
        #expect(rule.actions.showItems == [.system(.battery), .app("com.example.app")])
        #expect(!AutomationEvaluator.evaluate(rule.conditions[0], in: environment()))

        let again = try JSONDecoder().decode(AutomationRuleList.self, from: JSONEncoder().encode(list))
        #expect(again == list)
        #expect(list.rules[1].isEnabled && list.rules[1].conditions.isEmpty && list.rules[1].name.isEmpty)
    }

    @Test func templates() {
        let battery = AutomationTemplate.batteryOnBattery.makeRule(name: "Battery")
        #expect(battery.actions.showItems == [.system(.battery)])
        #expect(battery.conditions.first?.kind == .power(.init(test: .onBattery)))
        let wifi = AutomationTemplate.wifiNotConnected.makeRule(name: "Wi-Fi")
        #expect(wifi.actions.showItems == [.system(.wifi)])
        #expect(wifi.conditions.first?.kind == .wifi(.init(test: .notConnected)))
        let app = AutomationTemplate.appFrontmost.makeRule(name: "App")
        #expect(app.conditions.first?.kind == .app(.init(bundleID: "", test: .frontmost)))
    }

    @Test func scriptLimits() {
        #expect(AutomationScriptCondition(command: "x", interval: 1, timeout: 30).effectiveInterval == 5)
        #expect(AutomationScriptCondition(command: "x", interval: 1, timeout: 30).effectiveTimeout == 5)
        #expect(AutomationScriptCondition(command: "x", interval: 120, timeout: 600).effectiveTimeout == 60)
        #expect(AutomationScriptCondition(command: "x", interval: 10, timeout: 0).effectiveTimeout == 1)
    }
}

@Suite struct AutomationLenientDecodingTests {
    /// Hand-written or older rules may leave out keys that have defaults.
    @Test func missingOptionalKeysTakeDefaults() throws {
        let json = """
        {"rules":[{"id":"r","conditions":[
          {"id":"p","type":"power","parameters":{"test":"level-below"}},
          {"id":"w","type":"wifi","parameters":{"test":"connected-to"}},
          {"id":"t","type":"time","parameters":{"start":60}},
          {"id":"d","type":"displays","parameters":{"test":"count-at-least"}},
          {"id":"s","type":"script","parameters":{"command":"true"}},
          {"id":"i","type":"item-changed","parameters":{"owner":"system:wifi"}}],
          "actions":{"profile":{"profileID":"work"},"commandOnStart":{"id":"visibility.collapse"}}}]}
        """
        let rule = try #require(try JSONDecoder().decode(AutomationRuleList.self, from: Data(json.utf8)).rules.first)
        #expect(rule.conditions.map(\.kind) == [
            .power(.init(test: .levelBelow, percent: 20)),
            .wifi(.init(test: .connectedTo, networks: [])),
            .time(.init(weekdays: Array(1...7), start: 60, end: 0)),
            .displays(.init(test: .countAtLeast, count: 2)),
            .script(.init(command: "true", interval: 30, timeout: 5)),
            .itemChanged(.init(owner: .system(.wifi), holdSeconds: 10)),
        ])
        #expect(rule.actions.profile == AutomationProfileAction(profileID: "work", restorePrevious: false))
        #expect(rule.actions.commandOnStart == AutomationCommandCall(id: "visibility.collapse"))
    }
}
