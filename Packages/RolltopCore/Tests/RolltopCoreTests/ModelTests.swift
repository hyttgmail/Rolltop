import Foundation
import Testing
@testable import RolltopCore

@Suite struct OwnerIDTests {
    @Test func stringFormRoundTrips() {
        for owner in [OwnerID.app("com.foo.bar"), .system(.wifi), .system(.controlCenter)] {
            #expect(OwnerID(stringValue: owner.stringValue) == owner)
        }
        #expect(OwnerID.system(.wifi).stringValue == "system:wifi")
        #expect(OwnerID.app("com.foo.bar").stringValue == "com.foo.bar")
    }

    @Test func rejectsMalformed() {
        #expect(OwnerID(stringValue: "") == nil)
        #expect(OwnerID(stringValue: " com.foo") == nil)
        #expect(OwnerID(stringValue: "system:toaster") == nil)
        #expect(OwnerID(stringValue: "a/b") == nil)
        #expect(OwnerID(stringValue: "has space") == nil)
    }

    @Test func codableUsesStringForm() throws {
        let data = try JSONEncoder().encode([OwnerID.system(.clock), .app("com.foo")])
        #expect(String(decoding: data, as: UTF8.self) == #"["system:clock","com.foo"]"#)
        #expect(try JSONDecoder().decode([OwnerID].self, from: data) == [.system(.clock), .app("com.foo")])
    }
}

@Suite struct SystemModuleTests {
    @Test func idsMatchPlatformTable() {
        #expect(SystemModule.battery.systemItemID == 0)
        #expect(SystemModule.bluetooth.systemItemID == 1)
        #expect(SystemModule.clock.systemItemID == 2)
        #expect(SystemModule.sound.systemItemID == 5)
        #expect(SystemModule.wifi.systemItemID == 6)
        #expect(SystemModule.controlCenter.systemItemID == 8)
        #expect(SystemModule.allCases.filter { !$0.isVerified } == [.displays, .keyboard, .screenMirroring])
    }

    @Test func axIdentifierRoundTrips() {
        for module in SystemModule.allCases {
            #expect(SystemModule(axIdentifier: module.axIdentifier) == module)
            #expect(SystemModule(name: module.name) == module)
        }
        #expect(SystemModule(axIdentifier: "com.apple.menuextra.airdrop") == nil)
    }
}

@Suite struct LayoutTests {
    @Test func codableRoundTripAndDropsBadKeys() throws {
        let layout = Layout(sections: [.app("com.foo"): .hidden, .system(.wifi): .alwaysHidden], defaultSection: .hidden)
        let data = try JSONEncoder().encode(layout)
        #expect(try JSONDecoder().decode(Layout.self, from: data) == layout)

        let raw = #"{"sections":{"com.foo":"hidden","system:toaster":"shown"},"defaultSection":"shown"}"#
        let decoded = try JSONDecoder().decode(Layout.self, from: Data(raw.utf8))
        #expect(decoded.sections == [.app("com.foo"): .hidden])
    }

    @Test func freezingKeepsCurrentEffectiveSections() {
        let layout = Layout(sections: [.app("a"): .hidden], defaultSection: .shown)
        let frozen = layout.freezingSections(of: [.app("a"), .app("b")])
        #expect(frozen.sections == [.app("a"): .hidden, .app("b"): .shown])
    }

    @Test func sectionArgumentSpellings() {
        #expect(Section(argument: "always-hidden") == .alwaysHidden)
        #expect(Section(argument: "alwaysHidden") == .alwaysHidden)
        #expect(Section(argument: "Hidden") == .hidden)
        #expect(Section(argument: "nope") == nil)
    }

    @Test func levelsRevealSections() {
        #expect(PresentationLevel.collapsed.reveals(.shown))
        #expect(!PresentationLevel.collapsed.reveals(.hidden))
        #expect(PresentationLevel.hiddenRevealed.reveals(.hidden))
        #expect(!PresentationLevel.hiddenRevealed.reveals(.alwaysHidden))
        #expect(PresentationLevel.allRevealed.reveals(.alwaysHidden))
    }

    @Test func allowListCodable() throws {
        for plan in [AllowList.unrestricted, .restricted(systemIDs: [2, 8], bundleIDs: ["a"])] {
            let data = try JSONEncoder().encode(plan)
            #expect(try JSONDecoder().decode(AllowList.self, from: data) == plan)
        }
    }
}

@Suite struct IdentifierTests {
    @Test func commandIDsAreWellFormed() {
        for id in [CommandID.toggleHidden, .toggleAll, .showHidden, .showAll, .collapse, .setSection,
                   .setDefaultSection, .activateItem, .openSettings, .quit, .dumpState] {
            #expect(id.isWellFormed, "\(id)")
        }
        #expect(!CommandID("NoDot").isWellFormed)
        #expect(!CommandID("Upper.Case").isWellFormed)
    }

    @Test func applicationsFolderRule() {
        #expect(!RunningAppRecord.isOutsideApplications(resolvedPath: "/Applications/Foo.app"))
        #expect(!RunningAppRecord.isOutsideApplications(resolvedPath: "/Applications/Utilities/Foo.app"))
        #expect(!RunningAppRecord.isOutsideApplications(resolvedPath: "/System/Library/CoreServices/X.app"))
        #expect(RunningAppRecord.isOutsideApplications(resolvedPath: "/Users/me/Applications/Foo.app"))
        #expect(RunningAppRecord.isOutsideApplications(resolvedPath: "/Users/me/Downloads/Foo.app"))
        #expect(!RunningAppRecord.isOutsideApplications(resolvedPath: nil))
    }
}
