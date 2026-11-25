import AppKit
import Foundation

/// Receives every `rolltop://` link (docs/CONTRACTS.md, "Links"). Installed from
/// `applicationWillFinishLaunching`, so the `GURL` event that launches Rolltop reaches it too
/// (AppKit's own handler would turn it into `application(_:open:)`, which carries no
/// sender). Each link's sender is resolved when the event arrives; links wait in a queue
/// until `deliver` is set, after every feature has started, and then go to the link gate.
final class LinkIntake: NSObject {
    /// Set once features run; until then links are queued.
    private var deliver: ((URL, LinkSender) -> Void)?
    private var queue: [(url: URL, sender: LinkSender, receivedAt: Date)] = []
    private var installed = false
    private let log = Log.logger("url")

    /// Links waiting for the features (Debug dump, tests).
    var queuedCount: Int { queue.count }

    func install() {
        guard !installed else { return }
        installed = true
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleGetURL(_:withReplyEvent:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
    }

    func uninstall() {
        guard installed else { return }
        installed = false
        NSAppleEventManager.shared().removeEventHandler(forEventClass: AEEventClass(kInternetEventClass),
                                                        andEventID: AEEventID(kAEGetURL))
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: string) else {
            log.error("link event without a URL")
            return
        }
        let attributes = LinkSenderResolver.attributes(of: event)
        let sender = LinkSenderResolver.sender(of: attributes)
        #if DEBUG
        log.notice("link sender attributes: spid \(attributes.senderPID.map(String.init) ?? "-"), "
            + "token pid \(attributes.auditTokenPID.map(String.init) ?? "-"), actual token pid \(attributes.actualAuditTokenPID.map(String.init) ?? "-"), "
            + "from \(attributes.originalAddressType ?? "-") → \(sender)")
        #endif
        receive(url, sender: sender)
    }

    /// A link from any path (the Apple event above; `application(_:open:)` gives no sender).
    func receive(_ url: URL, sender: LinkSender) {
        if let deliver {
            deliver(url, sender)
        } else {
            queue.append((url, sender, Date()))
            log.notice("link from \(sender) queued until Rolltop has started (\(queue.count) waiting)")
        }
    }

    /// Starts delivering: first the queued links, in order, then every new one.
    func startDelivering(_ deliver: @escaping (URL, LinkSender) -> Void) {
        self.deliver = deliver
        let waiting = queue
        queue.removeAll()
        for link in waiting {
            log.notice("delivering a link queued \(Int(Date().timeIntervalSince(link.receivedAt) * 1000)) ms during launch")
            deliver(link.url, link.sender)
        }
    }
}
