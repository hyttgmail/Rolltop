import AppKit
import CoreServices
import Foundation

/// The real Apple Events side: finds a running player's pid, asks the permission without
/// prompting (or with, from the consent row only), and sends events addressed by pid in the
/// "do not prompt for user consent" mode. Every call blocks; run it off the main thread.
nonisolated struct MediaAppleEventTransport: MediaAETransporting {
    /// kAEDoNotPromptForUserConsent: a second guard behind the permission check.
    private static let doNotPrompt = NSAppleEventDescriptor.SendOptions(rawValue: 0x0002_0000)

    func runningPID(of player: NowPlayingPlayer) -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleID)
            .first { !$0.isTerminated }?.processIdentifier
    }

    func permission(pid: pid_t, ask: Bool) -> Int32 {
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        guard let desc = target.aeDesc else { return -600 }
        let wildcard = Self.code("****")
        return AEDeterminePermissionToAutomateTarget(desc, wildcard, wildcard, ask)
    }

    func send(_ request: MediaAERequest, to pid: pid_t, timeout: TimeInterval) -> MediaAEReply {
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        let event: NSAppleEventDescriptor
        switch request {
        case .get(let steps):
            event = NSAppleEventDescriptor.appleEvent(withEventClass: Self.code("core"), eventID: Self.code("getd"),
                                                      targetDescriptor: target, returnID: AEReturnID(kAutoGenerateReturnID),
                                                      transactionID: AETransactionID(kAnyTransactionID))
            event.setParam(Self.specifier(steps), forKeyword: Self.code("----"))
        case .command(let eventClass, let eventID):
            event = NSAppleEventDescriptor.appleEvent(withEventClass: Self.code(eventClass), eventID: Self.code(eventID),
                                                      targetDescriptor: target, returnID: AEReturnID(kAutoGenerateReturnID),
                                                      transactionID: AETransactionID(kAnyTransactionID))
        }
        do {
            let reply = try event.sendEvent(options: [.waitForReply, .neverInteract, Self.doNotPrompt], timeout: timeout)
            if let errorNumber = reply.paramDescriptor(forKeyword: Self.code("errn")), errorNumber.int32Value != 0 {
                return .failure(errorNumber.int32Value)
            }
            guard let value = reply.paramDescriptor(forKeyword: Self.code("----")) else { return MediaAEReply(status: 0) }
            var result = MediaAEReply(status: 0)
            switch value.descriptorType {
            case Self.code("enum"): result.enumCode = Self.string(value.enumCodeValue)
            case Self.code("utxt"), Self.code("TEXT"), Self.code("utf8"): result.string = value.stringValue
            default:
                result.string = value.stringValue
                result.data = value.data.isEmpty ? nil : value.data
            }
            return result
        } catch {
            return .failure(Int32(truncatingIfNeeded: (error as NSError).code))
        }
    }

    /// Object specifier from the application down (`current track › artwork 1 › raw data`).
    static func specifier(_ steps: [MediaAEStep]) -> NSAppleEventDescriptor {
        var container = NSAppleEventDescriptor.null()
        for step in steps {
            guard let spec = NSAppleEventDescriptor.record().coerce(toDescriptorType: code("obj ")) else { break }
            switch step {
            case .property(let property):
                spec.setDescriptor(NSAppleEventDescriptor(typeCode: code("prop")), forKeyword: code("want"))
                spec.setDescriptor(NSAppleEventDescriptor(enumCode: code("prop")), forKeyword: code("form"))
                spec.setDescriptor(NSAppleEventDescriptor(typeCode: code(property)), forKeyword: code("seld"))
            case .element(let elementClass, let index):
                spec.setDescriptor(NSAppleEventDescriptor(typeCode: code(elementClass)), forKeyword: code("want"))
                spec.setDescriptor(NSAppleEventDescriptor(enumCode: code("indx")), forKeyword: code("form"))
                spec.setDescriptor(NSAppleEventDescriptor(int32: index), forKeyword: code("seld"))
            }
            spec.setDescriptor(container, forKeyword: code("from"))
            container = spec
        }
        return container
    }

    static func code(_ s: String) -> FourCharCode {
        s.utf8.prefix(4).reduce(0) { $0 << 8 | FourCharCode($1) }
    }

    static func string(_ code: FourCharCode) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, encoding: .macOSRoman) ?? ""
    }
}
