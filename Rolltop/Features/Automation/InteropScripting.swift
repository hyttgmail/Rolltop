import AppKit
import Foundation
import RolltopCore

// AppleScript: the command classes and objects named in `Rolltop.sdef`, and the application's
// key-value accessors. Everything goes through `InteropActions` on `AppContext.current`.

// MARK: - Objects

/// `profile` in the dictionary.
@objc(InteropScriptProfile)
nonisolated final class InteropScriptProfile: NSObject {
    @objc let uniqueID: String
    @objc let name: String

    init(_ summary: ProfileSummary) {
        uniqueID = summary.id
        name = summary.name
    }

    override var objectSpecifier: NSScriptObjectSpecifier? {
        InteropScriptCodes.specifier(key: "interopProfiles", uniqueID: uniqueID)
    }
}

/// `menu bar item` in the dictionary.
@objc(InteropScriptItem)
nonisolated final class InteropScriptItem: NSObject {
    @objc let uniqueID: String
    @objc let name: String
    @objc let bundleIdentifier: String?
    /// The `item section` enumerator code.
    @objc let section: NSNumber
    @objc let visible: Bool

    init(_ item: InteropItem) {
        uniqueID = item.owner.stringValue
        name = item.name
        bundleIdentifier = item.bundleID
        section = NSNumber(value: InteropScriptCodes.code(for: item.section))
        visible = item.isVisible
    }

    override var objectSpecifier: NSScriptObjectSpecifier? {
        InteropScriptCodes.specifier(key: "interopMenuBarItems", uniqueID: uniqueID)
    }
}

nonisolated enum InteropScriptCodes {
    /// An element of the application by unique id (`profile id "work"`).
    static func specifier(key: String, uniqueID: String) -> NSScriptObjectSpecifier? {
        guard let application = NSScriptClassDescription(for: NSApplication.self) else { return nil }
        return NSUniqueIDSpecifier(containerClassDescription: application, containerSpecifier: nil, key: key, uniqueID: uniqueID)
    }

    /// `keyASUserRecordFields` (ASRegistry.h): a record's user-defined fields.
    static let userRecordFields = fourCharCode("usrf")

    static func fourCharCode(_ string: String) -> FourCharCode {
        string.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
    }

    static func code(for section: RolltopCore.Section) -> FourCharCode {
        switch section {
        case .shown: fourCharCode("SSsh")
        case .hidden: fourCharCode("SShd")
        case .alwaysHidden: fourCharCode("SSah")
        }
    }

    /// AppleScript error numbers: no such object, or the command failed.
    static func errorNumber(for error: any Error) -> Int {
        switch error as? InteropActionError {
        case .unknownProfile?, .unknownItem?, .unknownCommand?: -1728   // errAENoSuchObject
        case .notAllowed?: -10004                                       // errAEPrivilegeError
        case .invalidArgument?: -1703                                   // errAEWrongDataType
        default: -10000                                                 // errAEEventFailed
        }
    }
}

// MARK: - Application accessors

extension NSApplication {
    /// The current actions, or nil after reporting the error on the running script command.
    private func interopActions() -> InteropActions? {
        do {
            return try InteropActions.current(source: .appleScript)
        } catch {
            InteropScriptCommand.reportOnCurrentCommand(error)
            return nil
        }
    }

    @objc var interopProfiles: [InteropScriptProfile] {
        interopActions()?.profiles.map(InteropScriptProfile.init) ?? []
    }

    @objc var interopMenuBarItems: [InteropScriptItem] {
        guard let actions = interopActions() else { return [] }
        do {
            return try actions.items().map(InteropScriptItem.init)
        } catch {
            InteropScriptCommand.reportOnCurrentCommand(error)
            return []
        }
    }

    @objc var interopCurrentProfile: InteropScriptProfile? {
        interopActions()?.activeProfile.map(InteropScriptProfile.init)
    }

    @objc var interopHiddenItemsShowing: Bool {
        interopActions()?.isHiddenPresented ?? false
    }
}

// MARK: - Commands

/// Base class: resolves the actions, suspends the Apple event while the async work runs
/// (when this is the command being executed), sets the AppleScript error on failure.
/// Cocoa scripting runs commands on the main thread; unit tests call
/// `performDefaultImplementation()` directly and await `pendingTask`.
nonisolated class InteropScriptCommand: NSScriptCommand {
    /// The work started by the last `performDefaultImplementation()`, and its result
    /// (main thread only).
    nonisolated(unsafe) private(set) var pendingTask: Task<Void, Never>?
    nonisolated(unsafe) private(set) var lastResult: Any?

    /// Subclasses do their work here.
    @MainActor
    func perform(with actions: InteropActions) async throws -> Any? { nil }

    override func performDefaultImplementation() -> Any? {
        // Cocoa scripting runs commands on the main thread.
        nonisolated(unsafe) let command = self
        MainActor.assumeIsolated { command.start() }
        return nil
    }

    @MainActor
    private func start() {
        let actions: InteropActions
        do {
            actions = try InteropActions.current(source: .appleScript)
        } catch {
            report(error)
            return
        }
        let suspends = NSScriptCommand.current() === self
        if suspends { suspendExecution() }
        pendingTask = Task {
            var result: Any?
            do {
                result = try await perform(with: actions)
            } catch {
                report(error)
            }
            lastResult = result
            if suspends { resumeExecution(withResult: result) }
        }
    }

    func report(_ error: any Error) {
        scriptErrorNumber = InteropScriptCodes.errorNumber(for: error)
        scriptErrorString = error.localizedDescription
    }

    static func reportOnCurrentCommand(_ error: any Error) {
        guard let command = NSScriptCommand.current() else { return }
        command.scriptErrorNumber = InteropScriptCodes.errorNumber(for: error)
        command.scriptErrorString = error.localizedDescription
    }

    /// The direct parameter as text (an object specifier is evaluated first).
    var directText: String? {
        var value = directParameter
        if let specifier = value as? NSScriptObjectSpecifier { value = specifier.objectsByEvaluatingSpecifier }
        if let profile = value as? InteropScriptProfile { return profile.uniqueID }
        if let item = value as? InteropScriptItem { return item.uniqueID }
        return (value as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func requireDirectText() throws -> String {
        guard let text = directText, !text.isEmpty else { throw InteropActionError.invalidArgument("") }
        return text
    }
}

@objc(InteropShowHiddenScriptCommand)
nonisolated final class InteropShowHiddenScriptCommand: InteropScriptCommand {
    @MainActor override func perform(with actions: InteropActions) async throws -> Any? {
        try await actions.showHidden()
        return nil
    }
}

@objc(InteropHideHiddenScriptCommand)
nonisolated final class InteropHideHiddenScriptCommand: InteropScriptCommand {
    @MainActor override func perform(with actions: InteropActions) async throws -> Any? {
        try await actions.hideHidden()
        return nil
    }
}

@objc(InteropToggleHiddenScriptCommand)
nonisolated final class InteropToggleHiddenScriptCommand: InteropScriptCommand {
    @MainActor override func perform(with actions: InteropActions) async throws -> Any? {
        let wasShowing = actions.isHiddenPresented
        try await actions.toggleHidden()
        return NSNumber(value: !wasShowing)
    }
}

@objc(InteropApplyProfileScriptCommand)
nonisolated final class InteropApplyProfileScriptCommand: InteropScriptCommand {
    @MainActor override func perform(with actions: InteropActions) async throws -> Any? {
        InteropScriptProfile(try await actions.applyProfile(try requireDirectText()))
    }
}

@objc(InteropOpenItemScriptCommand)
nonisolated final class InteropOpenItemScriptCommand: InteropScriptCommand {
    @MainActor override func perform(with actions: InteropActions) async throws -> Any? {
        let right = (evaluatedArguments?["RightClick"] as? NSNumber)?.boolValue ?? false
        try await actions.openItem(try requireDirectText(), button: right ? .right : .left)
        return nil
    }
}

@objc(InteropRunCommandScriptCommand)
nonisolated final class InteropRunCommandScriptCommand: InteropScriptCommand {
    @MainActor override func perform(with actions: InteropActions) async throws -> Any? {
        let arguments = try Self.arguments(from: evaluatedArguments?["Arguments"])
        try await actions.runCommand(try requireDirectText(), arguments: arguments)
        return nil
    }

    /// A record (`{owner:"…"}`: Cocoa gives a dictionary, or the raw descriptor whose user
    /// fields alternate name and value), or a list of "name=value" texts.
    static func arguments(from value: Any?) throws -> [String: String] {
        switch value {
        case nil, is NSNull:
            return [:]
        case let dictionary as [String: Any]:
            return dictionary.reduce(into: [:]) { $0[$1.key] = "\($1.value)" }
        case let list as [Any]:
            return try InteropActions.arguments(from: list.map { "\($0)" })
        case let text as String:
            return try InteropActions.arguments(from: [text])
        case let descriptor as NSAppleEventDescriptor:
            return try arguments(fromRecord: descriptor)
        default:
            throw InteropActionError.invalidArgument("\(value!)")
        }
    }

    static func arguments(fromRecord descriptor: NSAppleEventDescriptor) throws -> [String: String] {
        guard let fields = descriptor.forKeyword(InteropScriptCodes.userRecordFields), fields.numberOfItems % 2 == 0 else {
            throw InteropActionError.invalidArgument(descriptor.stringValue ?? "record")
        }
        var result: [String: String] = [:]
        var index = 1
        while index < fields.numberOfItems {
            if let key = fields.atIndex(index)?.stringValue, let value = fields.atIndex(index + 1)?.stringValue {
                result[key] = value
            }
            index += 2
        }
        return result
    }
}
