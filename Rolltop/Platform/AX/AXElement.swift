import ApplicationServices
import CoreGraphics
import Foundation

/// Thin, thread-agnostic helpers around the C Accessibility API. Every call here
/// blocks on IPC, so callers run them off the main thread with a messaging timeout.
nonisolated enum AX {
    static let extrasMenuBarAttribute = "AXExtrasMenuBar"
    static let identifierAttribute = "AXIdentifier"
    static let showMenuAction = "AXShowMenu"

    static func application(_ pid: pid_t, timeout: Float) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, timeout)
        return element
    }

    static func copy(_ element: AXUIElement, _ attribute: String) -> (AXError, CFTypeRef?) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return (error, error == .success ? value : nil)
    }

    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        copy(element, attribute).1
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = value(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        (value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let string = value(element, attribute) as? String, !string.isEmpty else { return nil }
        return string
    }

    static func role(_ element: AXUIElement) -> String? { string(element, kAXRoleAttribute) }
    static func identifier(_ element: AXUIElement) -> String? { string(element, identifierAttribute) }

    /// Global top-left coordinates.
    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let positionValue = value(element, kAXPositionAttribute),
              let sizeValue = value(element, kAXSizeAttribute),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: position, size: size)
    }

    static func pid(_ element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    static func actions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    static func attributeNames(_ element: AXUIElement) -> [String]? {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success else { return nil }
        return names as? [String]
    }

    @discardableResult
    static func perform(_ element: AXUIElement, _ action: String) -> AXError {
        AXUIElementPerformAction(element, action as CFString)
    }

    /// The identifier of a MenuBarAgent-hosted extra: on the element or its first child.
    static func hostedIdentifier(_ element: AXUIElement) -> (identifier: String, item: AXUIElement)? {
        if let id = identifier(element) { return (id, element) }
        for child in children(element) {
            if let id = identifier(child) { return (id, child) }
        }
        return nil
    }
}

/// A pressable menu bar item. The only AX handle that leaves `Platform/`.
nonisolated final class ItemHandle: @unchecked Sendable {
    let element: AXUIElement
    let ownerPID: pid_t
    /// Frame when the handle was read, global top-left coordinates.
    let frame: CGRect?

    init(element: AXUIElement, ownerPID: pid_t, frame: CGRect?) {
        self.element = element
        self.ownerPID = ownerPID
        self.frame = frame
    }

    /// `AXPress` with a 0.5 s timeout. `.cannotComplete` may still have worked.
    func press() -> AXError {
        AXUIElementSetMessagingTimeout(element, 0.5)
        return AX.perform(element, kAXPressAction)
    }

    var supportsShowMenu: Bool { AX.actions(element).contains(AX.showMenuAction) }

    func showMenu() -> AXError {
        AXUIElementSetMessagingTimeout(element, 0.5)
        return AX.perform(element, AX.showMenuAction)
    }
}
