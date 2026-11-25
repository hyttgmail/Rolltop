import AppKit
import Foundation
import RolltopCore
import Testing
@testable import Rolltop

/// A full `AppContext` on a throwaway defaults suite, with a restriction that never reaches
/// macOS. Nothing is started.
@MainActor
enum TestContext {
    static func make() throws -> AppContext {
        let defaults = try #require(UserDefaults(suiteName: "com.alphapengwang.rolltop.tests.\(UUID().uuidString)"))
        let own: Set<String> = ["com.alphapengwang.rolltop"]
        let permissions = Permissions()
        let settings = SettingsStore(defaults: defaults)
        let layout = LayoutStore(settings: settings)
        let catalog = ItemCatalog(layoutStore: layout, settings: settings, permissions: permissions, ownBundleIDs: own)
        let engine = VisibilityEngine(restriction: FakeRestriction(), layoutStore: layout, catalog: catalog,
                                      settings: settings, ownBundleIDs: own)
        let clock = ClockBridge(isRestricted: { false }, lift: { engine.suspend(reason: "test") },
                                restore: { engine.endSuspension($0) },
                                beginInteraction: { engine.beginInteraction($0) }, endInteraction: { engine.endInteraction($0) })
        let activator = ItemActivator(engine: engine, catalog: catalog, permissions: permissions, clockBridge: clock)
        let commands = CommandRegistry()
        let context = AppContext(settings: settings, layout: layout, catalog: catalog, visibility: engine,
                                 activator: activator, clockBridge: clock, permissions: permissions, commands: commands,
                                 settingsPanes: SettingsPaneRegistry(), services: ServiceLocator(),
                                 urlRoutes: URLRouteRegistry(), launchInfo: .current(accessibilityTrusted: false),
                                 ownBundleIDs: own, statusItemFrame: { nil })
        CoreCommands.register(in: context)
        return context
    }
}

/// Ids that features contribute must not collide: the registries silently replace a
/// repeated id, so a clash between two features would only show as a missing command or
/// pane at run time. Docs: CONTRACTS.md, "Naming".
@Suite struct RegistryNamingTests {
    @Test func featureIDsAreUnique() {
        let ids = FeatureRegistry.all.map { $0.id.rawValue }
        #expect(Set(ids).count == ids.count)
    }

    @Test func commandAndPaneIDsBelongToOneFeature() throws {
        let context = try TestContext.make()
        let coreIDs = Set(context.commands.commands.map(\.id))
        let features = FeatureRegistry.all.map { $0.init(context: context) }

        var commandOwners: [CommandID: [String]] = [:]
        var paneOwners: [String: [String]] = [:]
        var sectionOwners: [String: [String]] = [:]
        for feature in features {
            let featureID = type(of: feature).id.rawValue
            for command in feature.commands {
                commandOwners[command.id, default: []].append(featureID)
                #expect(command.id.isWellFormed, "\(command.id) is not well formed")
                #expect(command.id.rawValue.hasPrefix(featureID + "."), "\(command.id) does not start with \(featureID).")
                #expect(!coreIDs.contains(command.id), "\(command.id) replaces a core command")
                if command.id.isDebugOnly || command.id.rawValue.contains("debug") {
                    #expect(command.id.rawValue.hasPrefix(featureID + ".debug-"),
                            "Debug command \(command.id) must be named \(featureID).debug-<verb>")
                }
            }
            for pane in feature.settingsPanes {
                paneOwners[pane.id, default: []].append(featureID)
            }
            for section in feature.settingsSections {
                sectionOwners[section.id, default: []].append(featureID)
                #expect(section.id.hasPrefix(featureID + "."), "section \(section.id) does not start with \(featureID).")
            }
        }
        for (id, owners) in commandOwners {
            #expect(owners.count == 1, "command \(id) is declared by \(owners)")
        }
        for (id, owners) in paneOwners {
            #expect(owners.count == 1, "pane \(id) is declared by \(owners)")
        }
        for (id, owners) in sectionOwners {
            #expect(owners.count == 1, "section \(id) is declared by \(owners)")
        }
        let paneIDs = Set(paneOwners.keys)
        for feature in features {
            for section in feature.settingsSections {
                #expect(paneIDs.contains(section.paneID), "section \(section.id) targets unknown pane \(section.paneID)")
            }
        }
        // Core Debug commands use `debug.<verb>`.
        for id in coreIDs where id.rawValue.contains("debug") {
            #expect(id.rawValue.hasPrefix("debug."), "core Debug command \(id) must be named debug.<verb>")
        }
    }
}

/// The default item images (used whenever no capture exists) never fall back to a missing
/// symbol and keep their aspect ratio at the requested height.
@Suite struct DefaultItemImageTests {
    @Test func everySystemOwnerHasAnExistingSymbol() {
        let owners = SystemModule.allCases.map(OwnerID.system) + AppIconImageProvider.agentSymbols.keys.map(OwnerID.app)
        for owner in owners {
            let name = AppIconImageProvider.symbol(for: owner)
            #expect(name.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) } != nil,
                    "\(owner.stringValue): symbol \(name ?? "nil") does not exist")
        }
    }

    @Test func everyManagedExtraHasAnExistingSymbol() {
        let names = AppIconImageProvider.managedSymbols.map(\.symbol) + [AppIconImageProvider.managedFallbackSymbol]
        for name in names {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "symbol \(name) does not exist")
        }
        #expect(AppIconImageProvider.symbol(forManagedID: "managed:com.apple.menuextra.airdrop") == "dot.radiowaves.up.forward")
        #expect(AppIconImageProvider.symbol(forManagedID: "managed:com.apple.menuextra.something-new") == "gearshape")
    }

    @MainActor
    @Test func ownItemsAreDrawnFromTheirOwnImagesNeverTheAppIcon() throws {
        // No status item is created here: MenuBarAgent records every one it sees.
        let provider = AppIconImageProvider(ownItems: OwnStatusItemRegistry(), ownBundleIDs: ["com.alphapengwang.rolltop"])
        #expect(provider.image(for: .app("com.alphapengwang.rolltop"), itemIndex: 0, height: 18) == nil, "never the app icon")
        let symbol = try #require(NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: nil))
        symbol.isTemplate = true
        let image = try #require(OwnStatusItemRegistry.scaled(symbol, height: 18))
        #expect(image.size.height == 18)
        #expect(image.isTemplate, "the main icon stays a template, never a coloured capture")
        #expect(OwnStatusItemRegistry.mainFrame(appKit: nil, ownSlots: [CGRect(x: 10, y: 0, width: 30, height: 24),
                                                                         CGRect(x: 50, y: 0, width: 40, height: 24)],
                                                otherFrames: [CGRect(x: 50, y: 0, width: 40, height: 24)])
                == CGRect(x: 10, y: 0, width: 30, height: 24))
        #expect(OwnStatusItemRegistry.mainFrame(appKit: nil, ownSlots: [CGRect(x: 10, y: 0, width: 30, height: 24),
                                                                         CGRect(x: 50, y: 0, width: 40, height: 24)],
                                                otherFrames: []) == nil, "never another own item")
    }

    @Test func imagesAreExactlyTheRequestedHeightAndNotSquashed() throws {
        let provider = AppIconImageProvider()
        for height: CGFloat in [16, 18, 20] {
            let battery = try #require(provider.image(for: .system(.battery), itemIndex: 0, height: height))
            #expect(battery.size.height == height, "battery \(battery.size)")
            #expect(battery.size.width > height, "the battery symbol is wider than tall")
            #expect(battery.isTemplate)
            let input = try #require(provider.image(for: .app("com.apple.TextInputMenuAgent"), itemIndex: 0, height: height))
            #expect(input.size.height == height, "input \(input.size)")
            #expect(input.isTemplate)
        }
    }

    @Test func catalogNamesAreFixed() throws {
        let context = try TestContext.make()
        #expect(context.catalog.displayName(for: .system(.wifi)) == ItemNames.module(.wifi))
        #expect(context.catalog.displayName(for: .app("com.apple.TextInputMenuAgent")) == ItemNames.agent(bundleID: "com.apple.TextInputMenuAgent"))
    }
}
