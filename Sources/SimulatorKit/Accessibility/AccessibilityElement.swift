import Foundation
@preconcurrency import ApplicationServices

/// A Swift wrapper around AXUIElement providing convenient access to accessibility attributes.
public struct AccessibilityElement: @unchecked Sendable {
    public let element: AXUIElement

    public init(element: AXUIElement) {
        self.element = element
    }

    private func getAttribute<T>(_ attribute: String) -> T? {
        var value: AnyObject?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else { return nil }
        return value as? T
    }

    public var role: String? {
        getAttribute(kAXRoleAttribute as String)
    }

    public var label: String? {
        if let label: String = getAttribute("AXLabel") {
            return label
        }
        if let description: String = getAttribute(kAXDescriptionAttribute as String) {
            return description
        }
        return nil
    }

    public var title: String? {
        getAttribute(kAXTitleAttribute as String)
    }

    public var value: String? {
        if let stringValue: String = getAttribute(kAXValueAttribute as String) {
            return stringValue
        }
        if let numberValue: NSNumber = getAttribute(kAXValueAttribute as String) {
            return numberValue.stringValue
        }
        return nil
    }

    public var identifier: String? {
        getAttribute(kAXIdentifierAttribute as String)
    }

    public var frame: CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?

        AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef)
        AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef)

        guard let posValue = positionRef, let sizeValue = sizeRef else { return nil }

        var point = CGPoint.zero
        var cgSize = CGSize.zero

        AXValueGetValue(posValue as! AXValue, .cgPoint, &point)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &cgSize)

        return CGRect(origin: point, size: cgSize)
    }

    public var children: [AccessibilityElement] {
        var childrenRef: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
        guard error == .success, let children = childrenRef as? [AXUIElement] else {
            return []
        }
        return children.map { AccessibilityElement(element: $0) }
    }

    public var childrenInNavigationOrder: [AccessibilityElement]? {
        var childrenRef: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, "AXChildrenInNavigationOrder" as CFString, &childrenRef)
        guard error == .success, let children = childrenRef as? [AXUIElement] else {
            return nil
        }
        return children.map { AccessibilityElement(element: $0) }
    }

    public var hint: String? {
        getAttribute(kAXHelpAttribute as String)
    }

    public var traits: [String]? {
        if let traitsValue: String = getAttribute("AXTraits") {
            return [traitsValue]
        }
        if let traitsValue: NSNumber = getAttribute("AXTraits") {
            let decoded = TraitDecoder.decode(traitsValue.uint64Value)
            return decoded.isEmpty ? nil : decoded
        }
        return nil
    }

    /// Returns the accessibility element at the given screen position via hit-test.
    public func hitTest(x: CGFloat, y: CGFloat) -> AccessibilityElement? {
        var resultRef: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(element, Float(x), Float(y), &resultRef)
        guard error == .success, let result = resultRef else { return nil }
        return AccessibilityElement(element: result)
    }
}
