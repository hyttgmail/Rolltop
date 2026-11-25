import Foundation
import Testing
@testable import RolltopCore

struct MenuBarOrderTests {
    // Anonymised from the round 1 copy of the table: larger weight = further left.
    let table: [String: Double] = [
        "module:Clock": 0, "module:BentoBox-0": 133, "module:WiFi": 191, "module:Battery": 213,
        "status:com.example.a::Item-0": 410.5, "status:com.example.b::Item-0": 410.5,
        "status:com.example.c::Item-0": 440, "status:com.example.c::other": 509.5,
        "status:com.example.c.helper::Item-0": 600, "status:Proc::Item-0": 700,
    ]

    func unit(_ owner: OwnerID) -> MenuBarOrderPlanner.Unit {
        .init(owner: owner, keys: MenuBarOrderKeys.keys(for: owner, in: table))
    }

    @Test func keysMatchTheExactOwnerNotAPrefix() {
        #expect(MenuBarOrderKeys.keys(for: .app("com.example.c"), in: table)
            == ["status:com.example.c::Item-0", "status:com.example.c::other"])
        #expect(MenuBarOrderKeys.keys(for: .system(.wifi), in: table) == ["module:WiFi"])
        #expect(MenuBarOrderKeys.keys(for: .system(.keyboard), in: table).isEmpty)
    }

    @Test func movesIntoAGapAndRenumbersNeighboursOnlyOnATie() throws {
        // Left to right: helper 600, a 410.5, battery 213, wifi 191, Control Center, clock.
        let order = [unit(.app("com.example.c.helper")), unit(.app("com.example.a")), unit(.system(.battery)),
                     unit(.system(.wifi)), unit(.system(.controlCenter)), unit(.system(.clock))]
        // Wi-Fi to the left end: only Wi-Fi changes, above 600.
        let left = try #require(MenuBarOrderPlanner.plan(table: table, order: order, moving: .system(.wifi), to: 0))
        #expect(left.keys.sorted() == ["module:WiFi"])
        #expect(left["module:WiFi"]! > 600)
        // Battery past Control Center is clamped to just left of it, between Wi-Fi and Control Center.
        let right = try #require(MenuBarOrderPlanner.plan(table: table, order: order, moving: .system(.battery), to: 9))
        #expect(right.keys.sorted() == ["module:Battery"])
        #expect(right["module:Battery"]! < 191 && right["module:Battery"]! > 133)
        // Fixed items never move.
        #expect(MenuBarOrderPlanner.plan(table: table, order: order, moving: .system(.clock), to: 0) == nil)

        // a and b tie at 410.5: putting Wi-Fi between them needs a renumbered neighbourhood.
        let tied = [unit(.app("com.example.a")), unit(.app("com.example.b")), unit(.system(.wifi)),
                    unit(.system(.controlCenter))]
        let changes = try #require(MenuBarOrderPlanner.plan(table: table, order: tied, moving: .system(.wifi), to: 1))
        #expect(Set(changes.keys).isSubset(of: ["module:WiFi", "status:com.example.a::Item-0", "status:com.example.b::Item-0"]))
        var after = table
        after.merge(changes) { $1 }
        #expect(after["status:com.example.a::Item-0"]! > after["module:WiFi"]!)
        #expect(after["module:WiFi"]! > after["status:com.example.b::Item-0"]!)
        #expect(after["status:com.example.b::Item-0"]! > 133)
    }

    @Test func landedComparesNeighboursAmongCommonOwners() {
        let planned: [OwnerID] = [.app("x"), .system(.wifi), .app("y"), .system(.clock)]
        #expect(MenuBarOrderPlanner.landed(moving: .system(.wifi), planned: planned,
                                           drawn: [.app("x"), .app("z"), .system(.wifi), .app("y"), .system(.clock)]))
        #expect(!MenuBarOrderPlanner.landed(moving: .system(.wifi), planned: planned,
                                            drawn: [.system(.wifi), .app("x"), .app("y"), .system(.clock)]))
    }
}

struct MenuBarAllowListParserTests {
    func key(_ id: String) -> [String: Any] { ["bundle": ["_0": id]] }

    @Test func parsesTheAlternatingArrayFromData() throws {
        let root: [Any] = [
            key("com.example.off"),
            ["isAllowed": false, "location": key("com.example.off"), "menuItemLocations": [key("com.example.off")]],
            key("com.example.on"), ["isAllowed": true, "location": key("com.example.on"), "menuItemLocations": []],
            ["adhocBinary": ["path": "x"]], ["isAllowed": false],
            "garbage", ["isAllowed": true],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        guard case .entries(let entries, let skipped) = MenuBarAllowListParser.parse(data) else {
            Issue.record("not parsed"); return
        }
        #expect(skipped == 1)
        #expect(entries.count == 3)
        #expect(entries[0] == .init(identity: .bundle("com.example.off"), isAllowed: false, itemLocations: ["com.example.off"]))
        #expect(entries[2].identity == .adhoc)
        #expect(MenuBarAllowListParser.turnedOff(entries) == ["com.example.off"])
    }

    @Test func otherRootsAreNotRecognised() {
        guard case .notRecognized(let found) = MenuBarAllowListParser.parse(["apps": ["com.example.secret": true]]) else {
            Issue.record("recognised"); return
        }
        #expect(found.contains("dictionary"))
        #expect(!found.contains("secret") || found.contains("com.example.secret: boolean"))
        guard case .notRecognized = MenuBarAllowListParser.parse(Data([1, 2, 3])) else { Issue.record("recognised"); return }
    }
}
