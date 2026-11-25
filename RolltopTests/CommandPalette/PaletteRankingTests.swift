import Foundation
import RolltopCore
import Testing
@testable import Rolltop

@Suite struct PaletteMatchingTests {
    private func tier(_ query: String, _ text: String, subsequence: Bool = true) -> PaletteMatchTier? {
        PaletteMatcher.match(PaletteQuery(query), in: PaletteSearchText(text), allowsSubsequence: subsequence)
    }

    @Test func tiersFromExactToSubsequence() {
        #expect(tier("rolltop bar", "Rolltop Bar") == .exact)
        #expect(tier("rolltop", "Rolltop Bar") == .prefix)
        #expect(tier("bar", "Rolltop Bar") == .wordPrefix)
        #expect(tier("menu items", "Search Menu Bar Items") == .wordPrefix)
        #expect(tier("smb", "Search Menu Bar Items") == .acronym)
        #expect(tier("sbitm", "Search Menu Bar Items") == .subsequence)
        #expect(tier("xyz", "Search Menu Bar Items") == nil)
    }

    @Test func caseDiacriticsAndPunctuationAreIgnored() {
        #expect(tier("CAFE", "Café") == .exact)
        #expect(tier("wifi", "Wi\u{2011}Fi") == .exact)
        #expect(tier("ｒｏｌｌｔｏｐ", "Rolltop") == .exact)   // full-width
        #expect(tier("eclair", "Éclair menu") == .prefix)
    }

    @Test func camelCaseAndDigitsSplitWords() {
        #expect(PaletteSearchText.split("RolltopFixtureB") == ["rolltop", "fixture", "b"])
        #expect(PaletteSearchText.split("iStat Menus 7") == ["i", "stat", "menus", "7"])
        #expect(tier("fix", "RolltopFixture") == .wordPrefix)
        #expect(tier("rf", "RolltopFixture") == .acronym)
    }

    @Test func subsequenceStartsAtAWordAndIsOffForAlternates() {
        // First letter must start a word: "ix" does not start one in "RolltopFixture".
        #expect(tier("ixt", "RolltopFixture") == nil)
        #expect(tier("fxt", "RolltopFixture") == .subsequence)
        #expect(tier("fxt", "RolltopFixture", subsequence: false) == nil)
    }

    @Test func pinyinOfChineseNames() throws {
        let latin = try #require(PalettePinyin.latin("微信"))
        #expect(latin == "wei xin")
        #expect(PalettePinyin.latin("Rolltop") == nil)
        let candidate = PaletteCandidate(key: "item:com.tencent.xinWeChat", kind: .item, title: "微信",
                                         alternates: ["com.tencent.xinWeChat"])
        let ranked = { (query: String) in
            PaletteRanker.rank([candidate], query: PaletteQuery(query), usage: PaletteUsage(), now: Date()).first?.tier
        }
        #expect(ranked("wx") == .acronym)
        #expect(ranked("weixin") == .exact)
        #expect(ranked("wei") == .prefix)
        #expect(ranked("微") == .prefix)
        #expect(ranked("tencent") == .wordPrefix)   // bundle id
    }
}

@Suite struct PaletteRankerTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func titles(_ candidates: [PaletteCandidate], _ query: String, usage: PaletteUsage = PaletteUsage()) -> [String] {
        PaletteRanker.rank(candidates, query: PaletteQuery(query), usage: usage, now: now).map { candidates[$0.index].title }
    }

    @Test func tierBeatsTypeAndTitleBeatsAlternates() {
        let candidates = [
            PaletteCandidate(key: "c1", kind: .command, title: "Hide Items"),
            PaletteCandidate(key: "i1", kind: .item, title: "Bartender Helper"),
            PaletteCandidate(key: "i2", kind: .item, title: "Hidden Gems"),
            PaletteCandidate(key: "i3", kind: .item, title: "Hide Out"),
            PaletteCandidate(key: "s1", kind: .setting, title: "Open Reveal settings", alternates: ["hide"]),
        ]
        // "hide": exact through the settings row's alternate; a prefix of "Hide Out" (item)
        // and "Hide Items" (command): same tier, items first; only a subsequence of
        // "Hidden Gems"; no match in "Bartender Helper".
        #expect(titles(candidates, "hide") == ["Open Reveal settings", "Hide Out", "Hide Items", "Hidden Gems"])
    }

    @Test func typePriorityThenUsageBreakTies() {
        let candidates = [
            PaletteCandidate(key: "command:a", kind: .command, title: "Work command"),
            PaletteCandidate(key: "profile:b", kind: .profile, title: "Work profile"),
            PaletteCandidate(key: "item:c", kind: .item, title: "Work item one"),
            PaletteCandidate(key: "item:d", kind: .item, title: "Work item two"),
        ]
        #expect(titles(candidates, "work") == ["Work item one", "Work item two", "Work profile", "Work command"])
        var usage = PaletteUsage()
        usage.record("item:d", at: now)
        usage.record("command:a", at: now)
        usage.record("command:a", at: now)
        // Usage reorders within a type, never across types.
        #expect(titles(candidates, "work", usage: usage) == ["Work item two", "Work item one", "Work profile", "Work command"])
    }

    @Test func providedRowsAreRankedWithTheRestAndKeptWhenUnmatched() {
        let candidates = [
            PaletteCandidate(key: "provider:clip:1", kind: .provided, title: "https://example.com/fixture"),
            PaletteCandidate(key: "provider:clip:2", kind: .provided, title: "Some copied text"),
            PaletteCandidate(key: "item:x", kind: .item, title: "Fixture"),
        ]
        // The provider returned both rows for "fix": the matched one ranks by tier, the
        // unmatched one stays, last.
        #expect(titles(candidates, "fix") == ["Fixture", "https://example.com/fixture", "Some copied text"])
    }

    @Test func emptyQueryListsHiddenItemsThenRecents() {
        let candidates = [
            PaletteCandidate(key: "item:shown", kind: .item, title: "Shown"),
            PaletteCandidate(key: "item:always", kind: .item, title: "Always", emptyQueryOrder: 1000),
            PaletteCandidate(key: "item:hidden", kind: .item, title: "Hidden", emptyQueryOrder: 0),
            PaletteCandidate(key: "command:x", kind: .command, title: "Command"),
            PaletteCandidate(key: "provider:p:1", kind: .provided, title: "Provided"),
        ]
        var usage = PaletteUsage()
        usage.record("command:x", at: now.addingTimeInterval(-60))
        usage.record("item:shown", at: now)
        usage.record("item:hidden", at: now)
        let order = PaletteRanker.emptyQuery(candidates, usage: usage, now: now).map { candidates[$0].title }
        #expect(order == ["Hidden", "Always", "Shown", "Command", "Provided"])
    }

    @Test func emptyQueryFallsBackToAllItems() {
        let candidates = [
            PaletteCandidate(key: "item:a", kind: .item, title: "A"),
            PaletteCandidate(key: "command:x", kind: .command, title: "Command"),
            PaletteCandidate(key: "item:b", kind: .item, title: "B"),
        ]
        #expect(PaletteRanker.emptyQuery(candidates, usage: PaletteUsage(), now: now) == [0, 2])
    }
}

@Suite struct PaletteUsageTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test func frequencyDecaysWithAge() {
        var usage = PaletteUsage()
        usage.record("a", at: now.addingTimeInterval(-PaletteUsage.halfLife))
        usage.record("a", at: now.addingTimeInterval(-PaletteUsage.halfLife))
        usage.record("b", at: now)
        // Two uses a half-life ago weigh as much as one use now.
        #expect(abs(usage.score(for: "a", at: now) - 1) < 0.0001)
        #expect(abs(usage.score(for: "b", at: now) - 1) < 0.0001)
        usage.record("a", at: now)
        #expect(usage.score(for: "a", at: now) > usage.score(for: "b", at: now))
        #expect(usage.score(for: "never", at: now) == 0)
        #expect(usage.recentKeys(at: now).first == "a")
        #expect(usage.entries["a"]?.count == 3)
    }

    @Test func keepsAtMostTheLimitAndClears() {
        var usage = PaletteUsage()
        for index in 0...PaletteUsage.limit {
            usage.record("k\(index)", at: now.addingTimeInterval(Double(index)))
        }
        #expect(usage.entries.count == PaletteUsage.limit)
        #expect(usage.entries["k0"] == nil)   // the weakest (oldest) went
        usage.clear()
        #expect(usage.isEmpty)
    }

    @Test func storeKeepsHistoryLocalOnly() throws {
        let context = try TestContext.make()
        let store = PaletteUsageStore(settings: context.settings)
        store.record("item:com.alphapengwang.rolltop-fixture", at: now)
        let reloaded = PaletteUsageStore(settings: context.settings)
        #expect(reloaded.usage.entries.keys.sorted() == ["item:com.alphapengwang.rolltop-fixture"])
        // Runtime state: never exported, never part of a profile.
        #expect(context.settings.exportAll()[PaletteSettings.usage.name] == nil)
        reloaded.clear()
        #expect(store.usage.isEmpty)
    }
}
