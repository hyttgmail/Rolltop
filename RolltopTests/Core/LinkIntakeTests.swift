import Foundation
import RolltopCore
import Testing
@testable import Rolltop

/// The core link intake and the default gate (docs/CONTRACTS.md, "Links").
@MainActor
@Suite struct LinkIntakeTests {
    @Test func linksWaitUntilFeaturesStartThenArriveInOrder() {
        let intake = LinkIntake()
        let tool = LinkSender(kind: .tool, path: "/usr/bin/open", pid: 7)
        intake.receive(URL(string: "rolltop://show")!, sender: tool)
        intake.receive(URL(string: "rolltop://hide")!, sender: .unknown)
        #expect(intake.queuedCount == 2)
        var delivered: [String] = []
        intake.startDelivering { url, sender in delivered.append("\(url.host() ?? "") \(sender.kind.rawValue)") }
        #expect(delivered == ["show tool", "hide unknown"])
        #expect(intake.queuedCount == 0)
        intake.receive(URL(string: "rolltop://toggle")!, sender: tool)
        #expect(delivered.last == "toggle tool", "after start, links go straight to the gate")
    }

    @Test func defaultGateRunsOnlyDisplayCommandsThatAllowLinks() async throws {
        let context = try TestContext.make()
        var ran: [String] = []
        for (id, effect, allows) in [("test.show", CommandEffect.display, true), ("test.tweak", .changesSettings, true),
                                     ("test.local", .display, false)] {
            context.commands.register(Command(id: CommandID(id), title: "T", symbol: "x", allowedFromURL: allows,
                                              effect: effect) { _ in ran.append(id) })
        }
        let gate = context.services[.linkGate]
        #expect(gate is CoreLinkGate)
        for id in ["test.show", "test.tweak", "test.local"] {
            gate.handle(URL(string: "rolltop://command/\(id)")!, sender: .unknown)
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(ran == ["test.show"])
    }
}

@Suite struct LaunchInfoTests {
    @Test func shellLaunchesAdoptedByLaunchdAreStillShellLaunches() {
        let id = "com.alphapengwang.rolltop"
        // `open -g -a` from a shell: the caller's SHLVL and TERM come along (measured).
        #expect(LaunchInfo.launchedByLaunchServices(parentPID: 1, environment: [
            "SHLVL": "3", "TERM": "xterm-256color", "__CFBundleIdentifier": id,
            "XPC_SERVICE_NAME": "application.com.alphapengwang.rolltop.41782216.41782221"], bundleID: id))
        // nohup from a terminal, shell gone: the terminal's values.
        #expect(!LaunchInfo.launchedByLaunchServices(parentPID: 1, environment: [
            "SHLVL": "2", "__CFBundleIdentifier": "com.stablyai.orca", "XPC_SERVICE_NAME": "0"], bundleID: id))
        #expect(!LaunchInfo.launchedByLaunchServices(parentPID: 1, environment: [
            "XPC_SERVICE_NAME": "application.com.alphapengwang.rolltop-fixture.1.2"], bundleID: id))
        #expect(!LaunchInfo.launchedByLaunchServices(parentPID: 4242, environment: ["__CFBundleIdentifier": id], bundleID: id))
    }
}

@Suite struct HotkeysCommandGroupTests {
    @Test func commandsAreGroupedByFeatureInSidebarOrder() {
        let groups = HotkeysCommandGroup.groups([
            ("shelf.toggle", "shelf", "Shelf"), ("visibility.toggle-hidden", "visibility", "Toggle Hidden Items"),
            ("capture.clear-cache", "capture", "Clear Saved Item Images"), ("reveal.keep-revealed", "reveal", "Show Hidden Items Until"),
            ("app.quit", "app", "Quit Rolltop"), ("reveal.toggle-make-room", "reveal", "Make Room"),
        ], panes: [("reveal", 210), ("shelf", 240), ("general", 10)])
        #expect(groups.map(\.key) == ["general", "reveal", "shelf", "other"])
        #expect(groups[0].commandIDs == ["app.quit", "visibility.toggle-hidden"])
        #expect(groups[1].commandIDs == ["reveal.toggle-make-room", "reveal.keep-revealed"])
    }
}

@Suite struct CustomItemsGroupRowsTests {
    @Test func onlyMatchingGroupsAreRows() {
        #expect(CustomItemsGroupRows.matches("open fix", title: "Open group Fixtures", name: "Fixtures"))
        #expect(CustomItemsGroupRows.matches("FIXTURES", title: "Open group Fixtures", name: "Fixtures"))
        #expect(!CustomItemsGroupRows.matches("4711", title: "Open group Fixtures", name: "Fixtures"))
        #expect(!CustomItemsGroupRows.matches("Shelf settings", title: "Open group Fixtures", name: "Fixtures"))
        #expect(!CustomItemsGroupRows.matches("  ", title: "Open group Fixtures", name: "Fixtures"))
    }

    @Test func rowsNameAndIconEveryGroup() {
        let rows = CustomItemsGroupRows.rows([CustomItemGroup(id: "g1", name: "Chat", icon: .symbol("bubble.left")),
                                              CustomItemGroup(id: "g2", name: " ", icon: .emoji("🍕"))])
        #expect(rows.map(\.id) == ["g1", "g2"])
        #expect(rows[0].symbol == "bubble.left")
        #expect(rows[1].symbol == "square.grid.2x2")
        #expect(!rows[1].name.trimmingCharacters(in: .whitespaces).isEmpty)
    }
}

@Suite struct StatusMenuGroupingTests {
    @Test func loneCommandsShareAGroup() {
        typealias E = StatusMenuGrouping.Entry
        let groups = StatusMenuGrouping.groups([
            E(feature: "reveal", id: "reveal.a", showsIcon: false), E(feature: "reveal", id: "reveal.b", showsIcon: false),
            E(feature: "profiles", id: "profiles.apply-1", showsIcon: true),
            E(feature: "palette", id: "palette.toggle", showsIcon: false), E(feature: "shelf", id: "shelf.toggle", showsIcon: false),
            E(feature: "onboarding", id: "onboarding.allow-accessibility", showsIcon: false),
        ])
        #expect(groups.map { $0.map(\.id) } == [["reveal.a", "reveal.b"], ["profiles.apply-1"],
                                                 ["palette.toggle", "shelf.toggle", "onboarding.allow-accessibility"]])
    }
}
