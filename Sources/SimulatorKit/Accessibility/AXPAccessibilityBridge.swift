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
    private let iosPointSize: CGSize    // iOS point dimensions (e.g. 402x874)
    private var cachedRootFrame: CGRect?

    public init(udid: String) throws {
        self.bridge = PrivateFrameworkBridge.shared
        try bridge.ensureAXPLoaded()

        self.translator = try bridge.getAXPTranslatorSharedInstance()
        self.device = try bridge.lookUpDevice(udid: udid)

        // Compute iOS point size = device pixels / screen scale
        let pixelSize = bridge.screenSize(forDevice: device)
        let scale = bridge.screenScale(forDevice: device)
        self.iosPointSize = CGSize(
            width: CGFloat(pixelSize.width) / CGFloat(scale),
            height: CGFloat(pixelSize.height) / CGFloat(scale)
        )

        // Create our delegate that bridges AXPTranslator callbacks to SimDevice
        let del = AXPTranslationDispatcher(device: self.device, bridge: self.bridge)
        self.delegate = del

        super.init()

        // Set the translator's bridgeTokenDelegate to our dispatcher.
        // Note: idb does NOT set supportsDelegateTokens; the framework infers
        // token-based delegation from the presence of bridgeTokenDelegate.
        (translator as AnyObject).setValue(del, forKey: "bridgeTokenDelegate")
    }

    // MARK: - Public API

    /// Returns the full accessibility tree from the frontmost application as an array of TreeNodes.
    /// The entire operation (including recursive tree walk) is bounded by `timeout`.
    public func accessibilityElements(timeout: Duration = .seconds(10)) throws -> [TreeNode] {
        let start = ContinuousClock.now
        let deadline = start.advanced(by: timeout)
        let timeoutSeconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        let dispatcher = delegate as! AXPTranslationDispatcher

        let token = UUID().uuidString
        dispatcher.registerDevice(forToken: token, deadline: deadline)
        defer { dispatcher.unregisterToken(token) }

        try checkDeadline(deadline, timeoutSeconds: timeoutSeconds)

        guard let translation = performTranslation(
            selector: "frontmostApplicationWithDisplayId:bridgeDelegateToken:",
            arg1: UInt32(0),
            arg2: token
        ) else {
            throw AXPBridgeError.noTranslationObject
        }

        // Set the token on the translation object
        (translation as AnyObject).setValue(token, forKey: "bridgeDelegateToken")

        try checkDeadline(deadline, timeoutSeconds: timeoutSeconds)

        guard let element = macPlatformElement(from: translation) else {
            throw AXPBridgeError.noMacPlatformElement
        }

        (element as AnyObject).value(forKey: "translation").map {
            ($0 as AnyObject).setValue(token, forKey: "bridgeDelegateToken")
        }

        // Update cached root frame from this element (free — no extra XPC call)
        let frameSel = NSSelectorFromString("accessibilityFrame")
        if (element as AnyObject).responds(to: frameSel) {
            cachedRootFrame = callFrameMethod(element as AnyObject, selector: frameSel)
        }

        var elementCount = 0
        var result = [try serializeElement(element, token: token, deadline: deadline, timeoutSeconds: timeoutSeconds, elementCount: &elementCount)]

        // Fallback: if the root element has no children (common on watchOS where
        // accessibilityChildren returns empty), discover elements via grid hit-testing.
        if result.count == 1, result[0].children.isEmpty, let rootFrame = result[0].frame,
           rootFrame.width > 0, rootFrame.height > 0 {
            let discovered = gridScanChildren(
                rootFrame: CGRect(x: rootFrame.x, y: rootFrame.y, width: rootFrame.width, height: rootFrame.height),
                token: token, deadline: deadline, timeoutSeconds: timeoutSeconds, elementCount: &elementCount
            )
            if !discovered.isEmpty {
                let root = result[0]
                result = [TreeNode(
                    role: root.role, label: root.label, title: root.title, value: root.value,
                    identifier: root.identifier, hint: root.hint, traits: root.traits,
                    frame: root.frame, children: discovered
                )]
            }
        }

        let elapsed = ContinuousClock.now - start
        let elapsedMs = Int(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
        if verboseLogging {
            FileHandle.standardError.write(Data("[ios-simulator-mcp] accessibility: \(elementCount) elements in \(elapsedMs)ms\n".utf8))
        }

        // Transform frames from macOS window coords to iOS points.
        // The AX root frame (e.g. 320x480) has a different aspect ratio than the iOS
        // screen (e.g. 402x874) because the macOS window letterboxes the content.
        // Use uniform scaling (based on width) + vertical centering offset.
        if let rootFrame = result.first?.frame,
           rootFrame.width > 0, rootFrame.height > 0 {
            let uniformScale = Double(iosPointSize.width) / rootFrame.width
            let yOffset = (Double(iosPointSize.height) - rootFrame.height * uniformScale) / 2
            if verboseLogging {
                FileHandle.standardError.write(Data("[ios-simulator-mcp] frame transform: AX root \(rootFrame.width)x\(rootFrame.height) -> iOS \(iosPointSize.width)x\(iosPointSize.height) (uniformScale \(String(format: "%.3f", uniformScale)), yOffset \(String(format: "%.1f", yOffset)))\n".utf8))
            }
            return result.map { transformFrames($0, uniformScale: uniformScale, yOffset: yOffset, originX: rootFrame.x, originY: rootFrame.y) }
        }
        return result
    }

    /// Returns the accessibility element at the given iOS point coordinates.
    /// The entire operation is bounded by `timeout`.
    public func accessibilityElementAtPoint(x: Double, y: Double, timeout: Duration = .seconds(10)) throws -> TreeNode {
        let start = ContinuousClock.now
        let deadline = start.advanced(by: timeout)
        let timeoutSeconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        let dispatcher = delegate as! AXPTranslationDispatcher

        let token = UUID().uuidString
        dispatcher.registerDevice(forToken: token, deadline: deadline)
        defer { dispatcher.unregisterToken(token) }

        // Get root frame for coordinate scaling before point lookup
        let rootFrame = getRootFrame(token: token)

        try checkDeadline(deadline, timeoutSeconds: timeoutSeconds)

        let point = CGPoint(x: x, y: y)

        guard let translation = performPointTranslation(point: point, token: token) else {
            throw AXPBridgeError.noElementAtPoint(x: x, y: y)
        }

        (translation as AnyObject).setValue(token, forKey: "bridgeDelegateToken")

        try checkDeadline(deadline, timeoutSeconds: timeoutSeconds)

        guard let element = macPlatformElement(from: translation) else {
            throw AXPBridgeError.noMacPlatformElement
        }

        (element as AnyObject).value(forKey: "translation").map {
            ($0 as AnyObject).setValue(token, forKey: "bridgeDelegateToken")
        }

        var elementCount = 0
        var result = try serializeElement(element, token: token, deadline: deadline, timeoutSeconds: timeoutSeconds, elementCount: &elementCount)
        let elapsed = ContinuousClock.now - start
        let elapsedMs = Int(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
        if verboseLogging {
            FileHandle.standardError.write(Data("[ios-simulator-mcp] accessibility point: \(elementCount) elements in \(elapsedMs)ms\n".utf8))
        }

        // Transform frames from macOS window coords to iOS points (uniform scale + centering)
        if let rf = rootFrame, rf.width > 0, rf.height > 0 {
            let uniformScale = Double(iosPointSize.width) / Double(rf.width)
            let yOffset = (Double(iosPointSize.height) - Double(rf.height) * uniformScale) / 2
            result = transformFrames(result, uniformScale: uniformScale, yOffset: yOffset, originX: Double(rf.origin.x), originY: Double(rf.origin.y))
        }
        return result
    }

    private func checkDeadline(_ deadline: ContinuousClock.Instant, timeoutSeconds: Double) throws {
        if ContinuousClock.now >= deadline {
            throw TimeoutError.accessibilityTimedOut(timeoutSeconds: timeoutSeconds)
        }
    }

    // MARK: - Frame coordinate transformation

    /// Fetches the root (frontmost app) element's frame in AX coordinates.
    /// Uses a cached value when available to avoid an extra XPC round-trip.
    private func getRootFrame(token: String) -> CGRect? {
        if let cached = cachedRootFrame {
            return cached
        }

        guard let translation = performTranslation(
            selector: "frontmostApplicationWithDisplayId:bridgeDelegateToken:",
            arg1: UInt32(0),
            arg2: token
        ) else { return nil }

        (translation as AnyObject).setValue(token, forKey: "bridgeDelegateToken")

        guard let element = macPlatformElement(from: translation) else { return nil }

        (element as AnyObject).value(forKey: "translation").map {
            ($0 as AnyObject).setValue(token, forKey: "bridgeDelegateToken")
        }

        let frameSel = NSSelectorFromString("accessibilityFrame")
        guard (element as AnyObject).responds(to: frameSel) else { return nil }
        let frame = callFrameMethod(element as AnyObject, selector: frameSel)
        cachedRootFrame = frame
        return frame
    }

    /// Clears the cached root frame, forcing the next point query to re-fetch it.
    public func invalidateRootFrameCache() {
        cachedRootFrame = nil
    }

    /// Recursively transforms all frames in a TreeNode from macOS window coords to iOS points.
    /// Uses uniform scaling (same factor for X and Y) plus a vertical centering offset,
    /// because the macOS window letterboxes the iOS content vertically.
    private func transformFrames(_ node: TreeNode, uniformScale: Double, yOffset: Double, originX: Double, originY: Double) -> TreeNode {
        let newFrame: TreeNode.FrameInfo?
        if let f = node.frame {
            newFrame = TreeNode.FrameInfo(
                x: ((f.x - originX) * uniformScale * 100).rounded() / 100,
                y: (((f.y - originY) * uniformScale + yOffset) * 100).rounded() / 100,
                width: (f.width * uniformScale * 100).rounded() / 100,
                height: (f.height * uniformScale * 100).rounded() / 100
            )
        } else {
            newFrame = nil
        }
        return TreeNode(
            role: node.role,
            label: node.label,
            title: node.title,
            value: node.value,
            identifier: node.identifier,
            hint: node.hint,
            traits: node.traits,
            frame: newFrame,
            children: node.children.map { transformFrames($0, uniformScale: uniformScale, yOffset: yOffset, originX: originX, originY: originY) }
        )
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
    /// Checks `deadline` before each child traversal to bound total operation time.
    private func serializeElement(_ element: AnyObject, token: String, deadline: ContinuousClock.Instant, timeoutSeconds: Double, elementCount: inout Int) throws -> TreeNode {
        elementCount += 1
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
                x: (Double(frame.origin.x) * 100).rounded() / 100,
                y: (Double(frame.origin.y) * 100).rounded() / 100,
                width: (Double(frame.size.width) * 100).rounded() / 100,
                height: (Double(frame.size.height) * 100).rounded() / 100
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

        // Ensure this element's translation has the token set before accessing children.
        // AXPMacPlatformElement lazily resolves children via XPC using the token.
        if let trans = (element as AnyObject).value(forKey: "translation") as AnyObject? {
            trans.setValue(token, forKey: "bridgeDelegateToken")
        }

        // Children
        var childNodes: [TreeNode] = []
        if let children = (element as AnyObject).value(forKey: "accessibilityChildren") as? [AnyObject], !children.isEmpty {
            for child in children {
                try checkDeadline(deadline, timeoutSeconds: timeoutSeconds)
                // Set bridgeDelegateToken on each child's translation
                if let translation = (child as AnyObject).value(forKey: "translation") as AnyObject? {
                    translation.setValue(token, forKey: "bridgeDelegateToken")
                }
                childNodes.append(try serializeElement(child, token: token, deadline: deadline, timeoutSeconds: timeoutSeconds, elementCount: &elementCount))
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

    /// Grid-scan fallback: when accessibilityChildren returns empty (watchOS),
    /// discover elements by hit-testing at regular intervals across the screen.
    /// Deduplicates by frame to avoid returning the same element multiple times.
    private func gridScanChildren(rootFrame: CGRect, token: String, deadline: ContinuousClock.Instant, timeoutSeconds: Double, elementCount: inout Int) -> [TreeNode] {
        let step: CGFloat = 10
        var seen = Set<String>() // "x,y,w,h" frame keys for dedup
        var elements: [TreeNode] = []

        var probeY = rootFrame.origin.y + step / 2
        while probeY < rootFrame.origin.y + rootFrame.height {
            var probeX = rootFrame.origin.x + step / 2
            while probeX < rootFrame.origin.x + rootFrame.width {
                if ContinuousClock.now >= deadline { return elements }

                // Skip points already covered by a discovered element's frame
                if elements.contains(where: { node in
                    guard let f = node.frame else { return false }
                    return Double(probeX) >= f.x && Double(probeX) <= f.x + f.width &&
                           Double(probeY) >= f.y && Double(probeY) <= f.y + f.height
                }) {
                    probeX += step
                    continue
                }

                guard let translation = performPointTranslation(
                    point: CGPoint(x: probeX, y: probeY), token: token
                ) else {
                    probeX += step
                    continue
                }

                (translation as AnyObject).setValue(token, forKey: "bridgeDelegateToken")

                guard let elem = macPlatformElement(from: translation) else {
                    probeX += step
                    continue
                }

                (elem as AnyObject).value(forKey: "translation").map {
                    ($0 as AnyObject).setValue(token, forKey: "bridgeDelegateToken")
                }

                // Serialize without recursing into children (they're likely empty too)
                guard let node = try? serializeElement(elem, token: token, deadline: deadline, timeoutSeconds: timeoutSeconds, elementCount: &elementCount) else {
                    probeX += step
                    continue
                }

                // Dedup by frame
                let frameKey: String
                if let f = node.frame {
                    frameKey = "\(f.x),\(f.y),\(f.width),\(f.height)"
                } else {
                    frameKey = "nil-\(node.identifier ?? node.label ?? UUID().uuidString)"
                }

                if !seen.contains(frameKey) {
                    seen.insert(frameKey)
                    // Skip the root element itself (same frame as rootFrame)
                    if node.role != "AXApplication" {
                        elements.append(node)
                    }
                }

                probeX += step
            }
            probeY += step
        }

        if verboseLogging {
            FileHandle.standardError.write(Data("[ios-simulator-mcp] grid scan: \(elements.count) elements discovered via hit-testing\n".utf8))
        }
        return elements
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
    private var tokenToDeadline: [String: ContinuousClock.Instant] = [:]  // token -> deadline
    private let defaultDevice: AnyObject  // SimDevice

    init(device: AnyObject, bridge: PrivateFrameworkBridge) {
        self.defaultDevice = device
        self.bridge = bridge
        super.init()
    }

    func registerDevice(forToken token: String, deadline: ContinuousClock.Instant? = nil) {
        lock.lock()
        defer { lock.unlock() }
        tokenToDevice[token] = defaultDevice
        if let deadline = deadline {
            tokenToDeadline[token] = deadline
        }
    }

    func unregisterToken(_ token: String) {
        lock.lock()
        defer { lock.unlock() }
        tokenToDevice.removeValue(forKey: token)
        tokenToDeadline.removeValue(forKey: token)
    }

    private func device(forToken token: String) -> AnyObject? {
        lock.lock()
        defer { lock.unlock() }
        return tokenToDevice[token]
    }

    private func deadline(forToken token: String) -> ContinuousClock.Instant? {
        lock.lock()
        defer { lock.unlock() }
        return tokenToDeadline[token]
    }

    // MARK: - AXPTranslationTokenDelegateHelper

    /// Returns a synchronous callback block that bridges to SimDevice.sendAccessibilityRequestAsync.
    @objc func accessibilityTranslationDelegateBridgeCallbackWithToken(_ token: NSString) -> Any {
        let tokenStr = token as String
        let device = self.device(forToken: tokenStr)
        let deadline = self.deadline(forToken: tokenStr)

        let callback: @convention(block) (AnyObject) -> AnyObject = { [weak self] (request: AnyObject) -> AnyObject in
            guard let self = self, let dev = device else {
                return Self.emptyAXPResponse()
            }

            // Compute per-call timeout from remaining deadline budget
            let xpcTimeout: Double
            if let deadline = deadline {
                let now = ContinuousClock.now
                let remaining = deadline - now
                let remainingSecs = Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18
                if remainingSecs <= 0 {
                    return Self.emptyAXPResponse()
                }
                xpcTimeout = min(remainingSecs, 10.0)
            } else {
                xpcTimeout = 10.0
            }

            do {
                return try self.bridge.sendAccessibilityRequest(request, toDevice: dev, timeoutSeconds: xpcTimeout)
            } catch {
                FileHandle.standardError.write(Data("[ios-simulator-mcp] XPC call failed: \(error.localizedDescription)\n".utf8))
                return Self.emptyAXPResponse()
            }
        }

        return callback
    }

    private static func emptyAXPResponse() -> AnyObject {
        if let cls: AnyClass = objc_lookUpClass("AXPTranslatorResponse") {
            let sel = NSSelectorFromString("emptyResponse")
            if let resp = (cls as AnyObject).perform(sel)?.takeUnretainedValue() {
                return resp
            }
        }
        return NSNull()
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
