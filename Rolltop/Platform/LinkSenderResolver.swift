import AppKit
import Darwin
import Foundation

/// Reads who sent an Apple event (a `GURL` link event) from its attributes. Used by the
/// core link intake when the event arrives (`App/LinkIntake.swift`).
///
/// macOS puts the sender's pid (`keySenderPIDAttr`) and audit token
/// (`keySenderAuditTokenAttr`) on every event; when LaunchServices forwards a URL on an
/// app's behalf it may override them with that app's (`keyActualSenderAuditToken` keeps
/// the real one). A pid that resolves to a running app gives its bundle id; any other
/// live process gives its executable path; nothing gives `unknown`.
enum LinkSenderResolver {
    /// Raw attributes, logged by Debug builds to document what macOS provides.
    struct Attributes: Codable, Equatable, Sendable {
        var senderPID: Int32?
        var auditTokenPID: Int32?
        var actualAuditTokenPID: Int32?
        var originalAddressType: String?
    }

    static func attributes(of event: NSAppleEventDescriptor) -> Attributes {
        var result = Attributes()
        if let pid = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value, pid > 0 {
            result.senderPID = pid
        }
        result.auditTokenPID = event.attributeDescriptor(forKeyword: AEKeyword(keySenderAuditTokenAttr)).flatMap(pid(fromAuditToken:))
        result.actualAuditTokenPID = event.attributeDescriptor(forKeyword: AEKeyword(keyActualSenderAuditToken)).flatMap(pid(fromAuditToken:))
        if let from = event.attributeDescriptor(forKeyword: AEKeyword(keyOriginalAddressAttr)) {
            result.originalAddressType = fourCharacterCode(from.descriptorType)
        }
        return result
    }

    /// The sender: the audit token's pid when present (it names the app LaunchServices
    /// acted for), else the sender pid.
    static func sender(of attributes: Attributes, ownPID: Int32 = ProcessInfo.processInfo.processIdentifier) -> LinkSender {
        guard let pid = attributes.auditTokenPID ?? attributes.senderPID else { return .unknown }
        return resolve(pid: pid, ownPID: ownPID)
    }

    static func resolve(pid: Int32, ownPID: Int32) -> LinkSender {
        if pid == ownPID { return LinkSender(kind: .rolltop, bundleID: Bundle.main.bundleIdentifier, name: "Rolltop", pid: pid) }
        if let app = NSRunningApplication(processIdentifier: pid), let bundleID = app.bundleIdentifier {
            return LinkSender(kind: .app, bundleID: bundleID, name: app.localizedName,
                                     path: app.bundleURL?.path, pid: pid)
        }
        if let path = executablePath(of: pid) {
            return LinkSender(kind: .tool, path: path, pid: pid)
        }
        return LinkSender(kind: .unknown, pid: pid)
    }

    /// `audit_token_t` is eight 32-bit words; word 5 is the pid.
    nonisolated static func pid(fromAuditToken descriptor: NSAppleEventDescriptor) -> Int32? {
        let data = descriptor.data
        guard data.count >= 32 else { return nil }
        let pid = data.withUnsafeBytes { $0.load(fromByteOffset: 20, as: Int32.self) }
        return pid > 0 ? pid : nil
    }

    nonisolated static func executablePath(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    nonisolated static func fourCharacterCode(_ code: DescType) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
