import Foundation
import ObjectiveC
import AXPTranslationBridge

/// Bridges to Apple's private AccessibilityPlatformTranslation framework to read
/// the iOS accessibility tree via AXPTranslator + SimDevice XPC, with no macOS
/// accessibility permissions required.
///
/// The approach mirrors idb's FBSimulatorAccessibilityCommands:
/// 1. Get AXPTranslator.sharedInstance
/// 2. Set ourselves as bridgeTokenDelegate (we implement AXPTranslationTokenDelegateHelper)
/// 3. Call frontmostApplicationWithDisplayId: / objectAtPoint: to get AXPTranslationObject
/// 4. Convert to AXPMacPlatformElement via macPlatformElementFromTranslation:
/// 5. Walk accessibilityChildren recursively, extracting properties
///
/// The delegate callback bridges SimDevice.sendAccessibilityRequestAsync (async)
/// to the synchronous block AXPTranslator expects, using DispatchGroup.
public final class AXPAccessibilityBridge: NSObject, @unchecked Sendable {

    private let bridge: PrivateFrameworkBridge
    private let translator: AnyObject   // AXPTranslator
    private let delegate: AnyObject     // AXPTranslationDispatcher (our NSObject subclass)
    private let device: AnyObject       // SimDevice

    public init(udid: String) throws {
        self.bridge = PrivateFrameworkBridge.shared
        try bridge.ensureAXPLoaded()

        self.translator = try bridge.getAXPTranslatorSharedInstance()
        self.device = try bridge.lookUpDevice(udid: udid)

        // Create our delegate that bridges AXPTranslator callbacks to SimDevice
        let del = AXPTranslationDispatcher(device: self.device, bridge: self.bridge)
        self.delegate = del

        super.init()

        // Set the translator's bridgeTokenDelegate to our dispatcher
        (translator as AnyObject).setValue(del, forKey: "bridgeTokenDelegate")
        // Enable tokenized delegation
        (translator as AnyObject).setValue(true, forKey: "supportsDelegateTokens")
    }

    // MARK: - Public API

    /// Returns the full accessibility tree from the frontmost application as an array of TreeNodes.
    public func accessibilityElements() throws -> [TreeNode] {
        let token = UUID().uuidString
        (delegate as! AXPTranslationDispatcher).registerDevice(forToken: token)
        defer { (delegate as! AXPTranslationDispatcher).unregisterToken(token) }

        guard let translation = performTranslation(
            selector: "frontmostApplicationWithDisplayId:bridgeDelegateToken:",
            arg1: UInt32(0),
            arg2: token
        ) else {
            throw AXPBridgeError.noTranslationObject
        }

        // Set the token on the translation object
        (translation as AnyObject).setValue(token, forKey: "bridgeDelegateToken")

        guard let element = macPlatformElement(from: translation) else {
            throw AXPBridgeError.noMacPlatformElement
        }

        (element as AnyObject).value(forKey: "translation").map {
            ($0 as AnyObject).setValue(token, forKey: "bridgeDelegateToken")
        }

        return [serializeElement(element, token: token)]
    }

    /// Returns the accessibility element at the given iOS coordinates.
    public func accessibilityElementAtPoint(x: Double, y: Double) throws -> TreeNode {
        let token = UUID().uuidString
        (delegate as! AXPTranslationDispatcher).registerDevice(forToken: token)
        defer { (delegate as! AXPTranslationDispatcher).unregisterToken(token) }

        let point = CGPoint(x: x, y: y)

        guard let translation = performPointTranslation(point: point, token: token) else {
            throw AXPBridgeError.noElementAtPoint(x: x, y: y)
        }

        (translation as AnyObject).setValue(token, forKey: "bridgeDelegateToken")

        guard let element = macPlatformElement(from: translation) else {
            throw AXPBridgeError.noMacPlatformElement
        }

        (element as AnyObject).value(forKey: "translation").map {
            ($0 as AnyObject).setValue(token, forKey: "bridgeDelegateToken")
        }

        return serializeElement(element, token: token)
    }

    // MARK: - Private helpers

    /// Calls [translator frontmostApplicationWithDisplayId:bridgeDelegateToken:]
    private func performTranslation(selector: String, arg1: UInt32, arg2: String) -> AnyObject? {
        let sel = NSSelectorFromString(selector)
        guard let method = class_getInstanceMethod(type(of: translator as AnyObject), sel) else {
            return nil
        }

        typealias TransFn = @convention(c) (AnyObject, Selector, UInt32, NSString) -> AnyObject?
        let imp = method_getImplementation(method)
        let fn = unsafeBitCast(imp, to: TransFn.self)
        return fn(translator, sel, arg1, arg2 as NSString)
    }

    /// Calls [translator objectAtPoint:displayId:bridgeDelegateToken:]
    private func performPointTranslation(point: CGPoint, token: String) -> AnyObject? {
        let sel = NSSelectorFromString("objectAtPoint:displayId:bridgeDelegateToken:")
        guard let method = class_getInstanceMethod(type(of: translator as AnyObject), sel) else {
            return nil
        }

        typealias PointFn = @convention(c) (AnyObject, Selector, CGPoint, UInt32, NSString) -> AnyObject?
        let imp = method_getImplementation(method)
        let fn = unsafeBitCast(imp, to: PointFn.self)
        return fn(translator, sel, point, 0, token as NSString)
    }

    /// Calls [translator macPlatformElementFromTranslation:]
    private func macPlatformElement(from translation: AnyObject) -> AnyObject? {
        let sel = NSSelectorFromString("macPlatformElementFromTranslation:")
        guard let method = class_getInstanceMethod(type(of: translator as AnyObject), sel) else {
            return nil
        }

        typealias MacElemFn = @convention(c) (AnyObject, Selector, AnyObject) -> AnyObject?
        let imp = method_getImplementation(method)
        let fn = unsafeBitCast(imp, to: MacElemFn.self)
        return fn(translator, sel, translation)
    }

    /// Recursively serializes an AXPMacPlatformElement into a TreeNode.
    private func serializeElement(_ element: AnyObject, token: String) -> TreeNode {
        // Extract properties via KVC / selectors
        let role = stringProperty(element, "accessibilityRole")
        let label = stringProperty(element, "accessibilityLabel")
        let title = stringProperty(element, "accessibilityTitle")
        let value = valueProperty(element, "accessibilityValue")
        let identifier = stringProperty(element, "accessibilityIdentifier")
        let hint = stringProperty(element, "accessibilityHelp")

        // Frame
        let frameInfo: TreeNode.FrameInfo?
        let frameSel = NSSelectorFromString("accessibilityFrame")
        if element.responds(to: frameSel) {
            let frame = callFrameMethod(element, selector: frameSel)
            frameInfo = TreeNode.FrameInfo(
                x: Double(frame.origin.x),
                y: Double(frame.origin.y),
                width: Double(frame.size.width),
                height: Double(frame.size.height)
            )
        } else {
            frameInfo = nil
        }

        // Traits
        let traits: [String]?
        let traitsSel = NSSelectorFromString("accessibilityAttributeValue:")
        if element.responds(to: traitsSel) {
            let traitsObj = element.perform(traitsSel, with: "AXTraits" as NSString)?.takeUnretainedValue()
            if let num = traitsObj as? NSNumber {
                let decoded = TraitDecoder.decode(num.uint64Value)
                traits = decoded.isEmpty ? nil : decoded
            } else {
                traits = nil
            }
        } else {
            traits = nil
        }

        // Children
        var childNodes: [TreeNode] = []
        let childrenSel = NSSelectorFromString("accessibilityChildren")
        if element.responds(to: childrenSel),
           let children = element.perform(childrenSel)?.takeUnretainedValue() as? [AnyObject] {
            for child in children {
                // Set bridgeDelegateToken on each child's translation
                if let translation = (child as AnyObject).value(forKey: "translation") as AnyObject? {
                    translation.setValue(token, forKey: "bridgeDelegateToken")
                }
                childNodes.append(serializeElement(child, token: token))
            }
        }

        return TreeNode(
            role: role,
            label: label,
            title: title,
            value: value,
            identifier: identifier,
            hint: hint,
            traits: traits,
            frame: frameInfo,
            children: childNodes
        )
    }

    private func stringProperty(_ obj: AnyObject, _ selector: String) -> String? {
        let sel = NSSelectorFromString(selector)
        guard obj.responds(to: sel) else { return nil }
        return obj.perform(sel)?.takeUnretainedValue() as? String
    }

    private func valueProperty(_ obj: AnyObject, _ selector: String) -> String? {
        let sel = NSSelectorFromString(selector)
        guard obj.responds(to: sel) else { return nil }
        guard let val = obj.perform(sel)?.takeUnretainedValue() else { return nil }
        if let str = val as? String { return str }
        if let num = val as? NSNumber { return num.stringValue }
        return nil
    }

    /// Calls an ObjC method returning NSRect (CGRect) via NSValue.
    private func callFrameMethod(_ obj: AnyObject, selector: Selector) -> CGRect {
        guard let method = class_getInstanceMethod(type(of: obj as AnyObject), selector) else {
            return .zero
        }
        typealias FrameFn = @convention(c) (AnyObject, Selector) -> CGRect
        let imp = method_getImplementation(method)
        let fn = unsafeBitCast(imp, to: FrameFn.self)
        return fn(obj, selector)
    }

    // MARK: - Errors

    public enum AXPBridgeError: Error, LocalizedError {
        case noTranslationObject
        case noMacPlatformElement
        case noElementAtPoint(x: Double, y: Double)

        public var errorDescription: String? {
            switch self {
            case .noTranslationObject:
                return "No accessibility translation object returned. The simulator may not have an active app."
            case .noMacPlatformElement:
                return "Could not convert translation to platform element"
            case .noElementAtPoint(let x, let y):
                return "No accessibility element found at coordinates (\(x), \(y))"
            }
        }
    }
}

// MARK: - AXPTranslationDispatcher

/// Implements AXPTranslationTokenDelegateHelper by bridging AXPTranslator's synchronous
/// delegate callbacks to SimDevice.sendAccessibilityRequestAsync via DispatchGroup.
///
/// This is an NSObject subclass so it can be set as the translator's bridgeTokenDelegate.
/// The protocol methods are invoked by the AXP framework via ObjC message dispatch.
final class AXPTranslationDispatcher: NSObject, @unchecked Sendable {
    private let bridge: PrivateFrameworkBridge
    private let lock = NSLock()
    private var tokenToDevice: [String: AnyObject] = [:]  // token -> SimDevice
    private let defaultDevice: AnyObject  // SimDevice

    init(device: AnyObject, bridge: PrivateFrameworkBridge) {
        self.defaultDevice = device
        self.bridge = bridge
        super.init()
    }

    func registerDevice(forToken token: String) {
        lock.lock()
        defer { lock.unlock() }
        tokenToDevice[token] = defaultDevice
    }

    func unregisterToken(_ token: String) {
        lock.lock()
        defer { lock.unlock() }
        tokenToDevice.removeValue(forKey: token)
    }

    private func device(forToken token: String) -> AnyObject? {
        lock.lock()
        defer { lock.unlock() }
        return tokenToDevice[token]
    }

    // MARK: - AXPTranslationTokenDelegateHelper

    /// Returns a synchronous callback block that bridges to SimDevice.sendAccessibilityRequestAsync.
    @objc func accessibilityTranslationDelegateBridgeCallbackWithToken(_ token: NSString) -> Any {
        let device = self.device(forToken: token as String)

        let callback: @convention(block) (AnyObject) -> AnyObject = { [weak self] (request: AnyObject) -> AnyObject in
            guard let self = self, let dev = device else {
                // Return empty response
                if let cls: AnyClass = objc_lookUpClass("AXPTranslatorResponse") {
                    let sel = NSSelectorFromString("emptyResponse")
                    if let resp = (cls as AnyObject).perform(sel)?.takeUnretainedValue() {
                        return resp
                    }
                }
                return NSNull()
            }

            do {
                return try self.bridge.sendAccessibilityRequest(request, toDevice: dev)
            } catch {
                if let cls: AnyClass = objc_lookUpClass("AXPTranslatorResponse") {
                    let sel = NSSelectorFromString("emptyResponse")
                    if let resp = (cls as AnyObject).perform(sel)?.takeUnretainedValue() {
                        return resp
                    }
                }
                return NSNull()
            }
        }

        return callback
    }

    /// Identity transform — frames from AXPMacPlatformElement are already in iOS simulator coordinates.
    @objc func accessibilityTranslationConvertPlatformFrameToSystem(_ rect: CGRect, withToken token: NSString) -> CGRect {
        return rect
    }

    /// Root parent — return nil (we don't traverse upward).
    @objc func accessibilityTranslationRootParentWithToken(_ token: NSString) -> AnyObject? {
        return nil
    }
}
