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
    private let udid: String
    private let iosPointSize: CGSize    // iOS point dimensions (e.g. 402x874)
    private var cachedRootFrame: CGRect?
    /// Set on visionOS, whose elements are placed in 3D and projected onto the screen.
    private let gazeCamera: GazeCamera?

    private func setBridgeToken(_ token: String, on obj: AnyObject) {
        obj.setValue(token, forKey: "bridgeDelegateToken")
    }

    public init(udid: String) throws {
        self.bridge = PrivateFrameworkBridge.shared
        try bridge.ensureAXPLoaded()

        // iOS 27 runtimes no longer auto-enable accessibility for AXP clients;
        // without this, every attribute request returns empty (0x0 rootless tree).
        SimulatorAccessibilityEnabler.ensureEnabled(udid: udid)

        self.translator = try bridge.getAXPTranslatorSharedInstance()
        self.device = try bridge.lookUpDevice(udid: udid)
        self.udid = udid

        // Compute iOS point size = device pixels / screen scale
        let pixelSize = bridge.screenSize(forDevice: device)
        let scale = bridge.screenScale(forDevice: device)
        self.iosPointSize = CGSize(
            width: CGFloat(pixelSize.width) / CGFloat(scale),
            height: CGFloat(pixelSize.height) / CGFloat(scale)
        )
        self.gazeCamera = bridge.isVisionOS(device: device)
            ? GazeCamera.default(aspectRatio: Double(pixelSize.width) / max(Double(pixelSize.height), 1))
            : nil

        // Create our delegate that bridges AXPTranslator callbacks to SimDevice
        let del = AXPTranslationDispatcher(device: self.device, bridge: self.bridge)
        self.delegate = del

        super.init()

        // Set the translator's bridgeTokenDelegate to our dispatcher.
        // Note: idb does NOT set supportsDelegateTokens; the framework infers
        // token-based delegation from the presence of bridgeTokenDelegate.
        (translator as AnyObject).setValue(del, forKey: "bridgeTokenDelegate")
    }

    deinit {
        // Unset bridgeTokenDelegate so the AXPTranslator singleton doesn't
        // retain a stale reference to our dispatcher (and through it, the
        // SimDevice). Without this, each process-lifetime bridge leaks its
        // dispatcher + device XPC connection even after the bridge is released.
        (translator as AnyObject).setValue(nil, forKey: "bridgeTokenDelegate")
        logDiagnostic("deinit — unset bridgeTokenDelegate", prefix: "AXPAccessibilityBridge")
    }

    // MARK: - Public API

    /// Returns the full accessibility tree from the frontmost application as an array of TreeNodes.
    /// The entire operation (including recursive tree walk) is bounded by `timeout`.
    public func accessibilityElements(timeout: Duration = .seconds(10)) throws -> [TreeNode] {
        try LargeStackThread.run { try self.accessibilityElementsImpl(timeout: timeout) }
    }

    private func accessibilityElementsImpl(timeout: Duration) throws -> [TreeNode] {
        let start = ContinuousClock.now
        let deadline = start.advanced(by: timeout)
        let timeoutSeconds = timeout.totalSeconds
        let dispatcher = delegate as! AXPTranslationDispatcher

        let token = UUID().uuidString
        dispatcher.registerDevice(forToken: token, deadline: deadline)
        defer { dispatcher.unregisterToken(token) }

        try checkDeadline(deadline, timeoutSeconds: timeoutSeconds)

        if let gazeCamera {
            return try visionOSElements(camera: gazeCamera, token: token, deadline: deadline, timeoutSeconds: timeoutSeconds)
        }

        guard let translation = frontmostApplication(token: token) else {
            throw AXPBridgeError.noTranslationObject
        }

        // Set the token on the translation object
        setBridgeToken(token, on: translation as AnyObject)

        try checkDeadline(deadline, timeoutSeconds: timeoutSeconds)

        guard let element = macPlatformElement(from: translation) else {
            throw AXPBridgeError.noMacPlatformElement
        }

        (element as AnyObject).value(forKey: "translation").map {
            setBridgeToken(token, on: $0 as AnyObject)
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
        let elapsedMs = Int(elapsed.totalSeconds * 1000)
        logDiagnostic("accessibility: \(elementCount) elements in \(elapsedMs)ms")

        // Transform frames from macOS window coords to iOS points.
        // The AX root frame (e.g. 320x480) has a different aspect ratio than the iOS
        // screen (e.g. 402x874) because the macOS window letterboxes the content.
        // Use uniform scaling (based on width) + vertical centering offset.
        if let rootFrame = result.first?.frame,
           rootFrame.width > 0, rootFrame.height > 0 {
            let uniformScale = Double(iosPointSize.width) / rootFrame.width
            let yOffset = (Double(iosPointSize.height) - rootFrame.height * uniformScale) / 2
                logDiagnostic("frame transform: AX root \(rootFrame.width)x\(rootFrame.height) -> iOS \(iosPointSize.width)x\(iosPointSize.height) (uniformScale \(String(format: "%.3f", uniformScale)), yOffset \(String(format: "%.1f", yOffset)))")
            let transform = FrameTransform(uniformScale: uniformScale, yOffset: yOffset, originX: rootFrame.x, originY: rootFrame.y)
            let transformed = result.map { transformFrames($0, uniformScale: uniformScale, yOffset: yOffset, originX: rootFrame.x, originY: rootFrame.y) }
            return transformed.map {
                expandEmptyContainers($0, transform: transform, token: token,
                                      deadline: deadline, timeoutSeconds: timeoutSeconds,
                                      elementCount: &elementCount)
            }
        }
        return result
    }

    /// The uniform-scale + vertical-centering transform that maps raw AX frames to iOS
    /// point space. `objectAtPoint:` hit-testing also operates in this point space, so
    /// hit-test results must be transformed with the same parameters.
    private struct FrameTransform {
        let uniformScale: Double
        let yOffset: Double
        let originX: Double
        let originY: Double
    }

    /// Post-transform pass for issue #2: walks the (point-space) tree and, for every
    /// grouping container that reported no children but occupies non-trivial bounds
    /// (e.g. the SwiftUI NavigationStack nav-bar AXGroup), recovers its children by
    /// hit-testing across the container's point-space frame. Recovered nodes are not
    /// themselves re-expanded, bounding the work to one sweep layer.
    private func expandEmptyContainers(_ node: TreeNode, transform: FrameTransform, token: String, deadline: ContinuousClock.Instant, timeoutSeconds: Double, elementCount: inout Int) -> TreeNode {
        var children = node.children

        if HitTestChildDiscovery.shouldDiscoverChildren(
            role: node.role, frame: node.frame, reportedChildCount: children.count),
           let frame = node.frame, ContinuousClock.now < deadline {
            children = HitTestChildDiscovery.discoverChildren(
                in: frame,
                containerFrame: frame,
                isCancelled: { ContinuousClock.now >= deadline }
            ) { x, y in
                // Hit-test in point space, then map the hit's raw frame back to points.
                guard let raw = hitTestNode(at: CGPoint(x: x, y: y), token: token,
                                            deadline: deadline, timeoutSeconds: timeoutSeconds,
                                            elementCount: &elementCount) else { return nil }
                return transformFrames(raw, uniformScale: transform.uniformScale,
                                       yOffset: transform.yOffset,
                                       originX: transform.originX, originY: transform.originY)
            }
            if !children.isEmpty {
                logDiagnostic("hit-test fallback: recovered \(children.count) children for empty \(node.role ?? "?") at \(frame.x),\(frame.y)")
            }
        } else {
            // Only recurse into containers we did NOT expand — recovered children are terminal.
            children = children.map {
                expandEmptyContainers($0, transform: transform, token: token,
                                      deadline: deadline, timeoutSeconds: timeoutSeconds,
                                      elementCount: &elementCount)
            }
        }

        return TreeNode(
            role: node.role, label: node.label, title: node.title, value: node.value,
            identifier: node.identifier, hint: node.hint, traits: node.traits,
            frame: node.frame, children: children
        )
    }

    /// Returns the accessibility element at the given iOS point coordinates.
    /// The entire operation is bounded by `timeout`.
    public func accessibilityElementAtPoint(x: Double, y: Double, timeout: Duration = .seconds(10)) throws -> TreeNode {
        try LargeStackThread.run { try self.accessibilityElementAtPointImpl(x: x, y: y, timeout: timeout) }
    }

    private func accessibilityElementAtPointImpl(x: Double, y: Double, timeout: Duration) throws -> TreeNode {
        // visionOS hit-tests return nothing, so search the projected tree instead (below the
        // root, which spans the whole screen).
        if gazeCamera != nil {
            let tree = try accessibilityElementsImpl(timeout: timeout)
            guard let hit = Self.smallestNode(containing: (x, y), in: tree.flatMap(\.children)) else {
                throw AXPBridgeError.noElementAtPoint(x: x, y: y)
            }
            return hit
        }

        let start = ContinuousClock.now
        let deadline = start.advanced(by: timeout)
        let timeoutSeconds = timeout.totalSeconds
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

        setBridgeToken(token, on: translation as AnyObject)

        try checkDeadline(deadline, timeoutSeconds: timeoutSeconds)

        guard let element = macPlatformElement(from: translation) else {
            throw AXPBridgeError.noMacPlatformElement
        }

        (element as AnyObject).value(forKey: "translation").map {
            setBridgeToken(token, on: $0 as AnyObject)
        }

        var elementCount = 0
        var result = try serializeElement(element, token: token, deadline: deadline, timeoutSeconds: timeoutSeconds, elementCount: &elementCount)
        let elapsed = ContinuousClock.now - start
        let elapsedMs = Int(elapsed.totalSeconds * 1000)
        logDiagnostic("accessibility point: \(elementCount) elements in \(elapsedMs)ms")

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

        guard let translation = frontmostApplication(token: token) else { return nil }

        setBridgeToken(token, on: translation as AnyObject)

        guard let element = macPlatformElement(from: translation) else { return nil }

        (element as AnyObject).value(forKey: "translation").map {
            setBridgeToken(token, on: $0 as AnyObject)
        }

        let frameSel = NSSelectorFromString("accessibilityFrame")
        guard (element as AnyObject).responds(to: frameSel) else { return nil }
        let frame = callFrameMethod(element as AnyObject, selector: frameSel)
        cachedRootFrame = frame
        return frame
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

    /// Resolves the frontmost application's translation object.
    ///
    /// The simulator's CoreSimulatorBridge answers this request, and it starts at boot. If
    /// accessibility was only enabled afterwards (see `SimulatorAccessibilityEnabler`), the
    /// bridge keeps answering nil even though point queries against the app succeed, and
    /// relaunching the app doesn't help. Restarting the bridge does, so on a nil result we
    /// do that once and ask again, as idb does for a SpringBoard crash.
    private func frontmostApplication(token: String) -> AnyObject? {
        let selector = "frontmostApplicationWithDisplayId:bridgeDelegateToken:"
        if let translation = performTranslation(selector: selector, arg1: UInt32(0), arg2: token) {
            return translation
        }
        guard SimulatorAccessibilityEnabler.restartBridgeOnce(udid: udid) else { return nil }

        // launchd respawns the bridge on demand; give it a moment to come back up.
        for _ in 0..<15 {
            if let translation = performTranslation(selector: selector, arg1: UInt32(0), arg2: token) {
                return translation
            }
            usleep(200_000)
        }
        return nil
    }

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
    /// - Parameter ancestors: identities of the elements on the current root-to-parent
    ///   path, used to break reference cycles. SpringBoard's Dynamic Island element
    ///   lists **itself** in its own `accessibilityChildren` (pointer-identical every
    ///   level), which otherwise materializes as a ~4000-deep chain of repeated nodes
    ///   and overflows the stack of whichever thread walks, searches, encodes, or
    ///   even deallocates the tree.
    /// - Parameter spatial: on visionOS, collects each element's 3D placement in pre-order, for
    ///   `applySpatialFrames` to project once the world transforms are known.
    private func serializeElement(_ element: AnyObject, token: String, deadline: ContinuousClock.Instant, timeoutSeconds: Double, elementCount: inout Int, ancestors: Set<ObjectIdentifier> = [], spatial: SpatialCollector? = nil) throws -> TreeNode {
        elementCount += 1
        // Extract properties via KVC / selectors
        let role = stringProperty(element, "accessibilityRole")
        let label = stringProperty(element, "accessibilityLabel")
        let title = stringProperty(element, "accessibilityTitle")
        let value = valueProperty(element, "accessibilityValue")
        let identifier = stringProperty(element, "accessibilityIdentifier")
        let hint = stringProperty(element, "accessibilityHelp")

        // Frame (on visionOS a window-local rect, replaced by `applySpatialFrames`)
        let frameInfo: TreeNode.FrameInfo?
        let frameSel = NSSelectorFromString("accessibilityFrame")
        if spatial == nil, element.responds(to: frameSel) {
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
            setBridgeToken(token, on: trans)
            spatial?.translations.append(trans)
        } else {
            spatial?.translations.append(nil)
        }

        // Children
        var childNodes: [TreeNode] = []
        if let children = (element as AnyObject).value(forKey: "accessibilityChildren") as? [AnyObject], !children.isEmpty {
            var path = ancestors
            path.insert(ObjectIdentifier(element))
            for child in children {
                try checkDeadline(deadline, timeoutSeconds: timeoutSeconds)
                guard !path.contains(ObjectIdentifier(child)) else {
                    logDiagnostic("cycle: \(role ?? "?") \"\(label ?? "")\" lists an ancestor (or itself) as a child — skipping")
                    continue
                }
                let node: TreeNode = try autoreleasepool {
                    // Set bridgeDelegateToken on each child's translation
                    if let translation = (child as AnyObject).value(forKey: "translation") as AnyObject? {
                        setBridgeToken(token, on: translation)
                    }
                    return try serializeElement(child, token: token, deadline: deadline, timeoutSeconds: timeoutSeconds, elementCount: &elementCount, ancestors: path, spatial: spatial)
                }
                childNodes.append(node)
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

    /// Hit-tests at a single point and serializes the element found there, without
    /// recursing into a further hit-test sweep. Shared by the per-container fallback
    /// and the watchOS grid scan. Returns nil when no element is found at the point.
    private func hitTestNode(at point: CGPoint, token: String, deadline: ContinuousClock.Instant, timeoutSeconds: Double, elementCount: inout Int) -> TreeNode? {
        autoreleasepool {
            guard let translation = performPointTranslation(point: point, token: token) else {
                return nil
            }
            setBridgeToken(token, on: translation as AnyObject)
            guard let elem = macPlatformElement(from: translation) else { return nil }
            (elem as AnyObject).value(forKey: "translation").map {
                setBridgeToken(token, on: $0 as AnyObject)
            }
            return try? serializeElement(elem, token: token, deadline: deadline, timeoutSeconds: timeoutSeconds, elementCount: &elementCount)
        }
    }

    /// Grid-scan fallback: when accessibilityChildren returns empty for the whole tree
    /// (common on watchOS), discover elements by hit-testing across the entire screen.
    /// Delegates the sweep + dedup to the same logic the per-container fallback uses.
    private func gridScanChildren(rootFrame: CGRect, token: String, deadline: ContinuousClock.Instant, timeoutSeconds: Double, elementCount: inout Int) -> [TreeNode] {
        let region = TreeNode.FrameInfo(
            x: Double(rootFrame.origin.x), y: Double(rootFrame.origin.y),
            width: Double(rootFrame.size.width), height: Double(rootFrame.size.height)
        )
        let elements = HitTestChildDiscovery.discoverChildren(
            in: region,
            containerFrame: region,
            isCancelled: { ContinuousClock.now >= deadline }
        ) { x, y in
            hitTestNode(at: CGPoint(x: x, y: y), token: token,
                        deadline: deadline, timeoutSeconds: timeoutSeconds,
                        elementCount: &elementCount)
        }
        logDiagnostic("grid scan: \(elements.count) elements discovered via hit-testing")
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

    // MARK: - visionOS

    /// `AXPAttributeDebugiOSAttribute`: reads the raw iOS attribute named by the request's
    /// `parameter`, for attributes AXP has no mapping for.
    private static let debugiOSAttribute = 63
    private static let childrenAttribute = 8  // AXPAttributeChildren
    /// SurfBoard's answer for a scene container: every element in the scene, flattened, plus
    /// the window chrome (close button, placement and resize bars) from RealityChrome.
    private static let sceneElementsAttribute = 2095
    /// `AXAutomationSystemProperties`: the element's 3D placement (see `SpatialProperties`).
    /// Complete, but the app takes ~50ms to answer it.
    private static let automationSystemPropertiesAttribute = 5063
    // The automation properties one at a time. The window-space transform is cheap (~1ms);
    // the top-level-entity-space transform costs ~25ms.
    private static let backingObjectTypeAttribute = 20007     // "View" or "Entity"
    private static let topLevelEntityIDAttribute = 20008
    private static let topLevelEntitySpaceTransformAttribute = 20009
    private static let boundingBoxAttribute = 20012
    private static let windowSpaceTransformAttribute = 20013

    /// Each element's placement, in the order given. A window's (or ornament's) views differ
    /// only by their window-space transform, so the full automation properties are read for
    /// the first view per top-level entity, and the rest are derived from it (see
    /// `SpatialProperties.init(relativeTo:)`). RealityKit entities are read individually: their
    /// automation properties carry no bounding box, and in an immersive space an identity
    /// transform for every entity, so their own transform and bounds are read instead.
    private func spatialProperties(of translations: [AnyObject?]) -> [SpatialProperties?] {
        var anchors: [UInt64: SpatialProperties.Anchor?] = [:]
        return translations.map { translation in
            guard let translation else { return nil }
            func full() -> SpatialProperties? {
                (iosAttribute(Self.automationSystemPropertiesAttribute, of: translation) as? [String: Any])
                    .flatMap(SpatialProperties.init(automationProperties:))
            }
            let box = { self.iosAttribute(Self.boundingBoxAttribute, of: translation).flatMap(SpatialProperties.boundingBox) }

            if iosAttribute(Self.backingObjectTypeAttribute, of: translation) as? String == "Entity" {
                guard var spatial = full() else { return nil }
                if let transform = iosAttribute(Self.topLevelEntitySpaceTransformAttribute, of: translation)
                    .flatMap(SpatialProperties.matrix) {
                    spatial.transform = transform
                }
                if let box = box() { (spatial.boundingBoxMin, spatial.boundingBoxMax) = box }
                return spatial
            }

            guard let entity = (iosAttribute(Self.topLevelEntityIDAttribute, of: translation) as? NSNumber)?.uint64Value,
                  let window = iosAttribute(Self.windowSpaceTransformAttribute, of: translation).flatMap(SpatialProperties.matrix),
                  window.columns.3.w != 0  // all zeros for UIKit views hosted in SwiftUI
            else { return full() }
            if let anchor = anchors[entity] ?? nil, let box = box() {
                return SpatialProperties(relativeTo: anchor, windowSpaceTransform: window, boundingBox: box)
            }
            let spatial = full()
            if anchors[entity] == nil {
                anchors[entity] = spatial.map { SpatialProperties.Anchor(properties: $0, windowSpaceTransform: window) }
            }
            return spatial
        }
    }

    /// Collects elements in the order `serializeElement` visits them, to read their
    /// `SpatialProperties` afterwards.
    private final class SpatialCollector {
        var translations: [AnyObject?] = []
    }

    /// The platform element for `translation`, ready to read with `token`. Platform elements
    /// are cached per object ID and keep the translation they were first made from, whose
    /// token belongs to an earlier read, so that one needs the current token too.
    private func platformElement(from translation: AnyObject, token: String) -> AnyObject? {
        setBridgeToken(token, on: translation)
        guard let element = macPlatformElement(from: translation) else { return nil }
        (element as AnyObject).value(forKey: "translation").map { setBridgeToken(token, on: $0 as AnyObject) }
        return element
    }

    /// Reads a raw iOS accessibility attribute from the element behind `translation`.
    private func iosAttribute(_ attribute: Int, of translation: AnyObject) -> Any? {
        axpAttribute(Self.debugiOSAttribute, parameters: ["parameter": NSNumber(value: attribute)], of: translation)
    }

    /// Reads an AXP attribute straight from the simulator, without a platform element.
    private func axpAttribute(_ attribute: Int, parameters: [String: Any]? = nil, of translation: AnyObject) -> Any? {
        guard let requestClass = objc_lookUpClass("AXPTranslatorRequest") as AnyObject?,
              let request = requestClass.perform(NSSelectorFromString("requestWithTranslation:"), with: translation)?
                .takeUnretainedValue() else { return nil }
        request.setValue(NSNumber(value: 2), forKey: "requestType")  // attribute
        request.setValue(NSNumber(value: attribute), forKey: "attributeType")
        if let parameters { request.setValue(parameters, forKey: "parameters") }
        guard let response = try? bridge.sendAccessibilityRequest(request, toDevice: device, timeoutSeconds: 5) else {
            return nil
        }
        let value = response.value(forKey: "resultData")
        return value is NSNull ? nil : value
    }

    /// The visionOS tree. The frontmost "application" is SurfBoard, the system shell, whose
    /// children are one placeholder group per scene (window, volume, immersive space, or
    /// system UI such as Control Center) with no children of their own. Each scene's elements
    /// come from `sceneElementsAttribute` instead, and their frames are window-local points,
    /// so they're replaced with the element's 3D bounding box projected onto the screen.
    private func visionOSElements(camera: GazeCamera, token: String, deadline: ContinuousClock.Instant, timeoutSeconds: Double) throws -> [TreeNode] {
        let start = ContinuousClock.now
        // Spawning the world-transform helper takes most of a second, so start it now: it
        // reports every visible scene, which normally covers every scene the walk finds.
        let visibleWorld = VisionOSWorldHelper.Pending(device: device, scenes: [],
                                                       timeoutSeconds: max((deadline - start).totalSeconds, 0.5))
        var shell: AnyObject
        var containers: [AnyObject]  // translation objects
        // SurfBoard lists no scenes while one opens or closes, and for several seconds after
        // an app launches. Ride out the brief gaps; for longer ones, return the empty tree and
        // leave waiting to the caller (`wait` polls).
        let retryUntil = min(deadline, start + .seconds(2))

        repeat {
            guard let translation = frontmostApplication(token: token) else {
                throw AXPBridgeError.noTranslationObject
            }
            guard let element = platformElement(from: translation, token: token) else {
                throw AXPBridgeError.noMacPlatformElement
            }
            shell = element
            containers = axpAttribute(Self.childrenAttribute, of: translation) as? [AnyObject] ?? []
            if containers.isEmpty, ContinuousClock.now < retryUntil {
                logDiagnostic("visionOS: no scenes yet, retrying")
                usleep(250_000)
            } else {
                break
            }
        } while true

        var elementCount = 1
        let spatial = SpatialCollector()
        var scenes: [TreeNode] = []
        for containerTranslation in containers {
            try checkDeadline(deadline, timeoutSeconds: timeoutSeconds)
            guard let container = platformElement(from: containerTranslation, token: token) else { continue }
            elementCount += 1

            var members: [TreeNode] = []
            for member in iosAttribute(Self.sceneElementsAttribute, of: containerTranslation) as? [AnyObject] ?? [] {
                try checkDeadline(deadline, timeoutSeconds: timeoutSeconds)
                let node: TreeNode? = try autoreleasepool {
                    guard let element = platformElement(from: member, token: token) else { return nil }
                    return try serializeElement(element, token: token, deadline: deadline, timeoutSeconds: timeoutSeconds,
                                                elementCount: &elementCount, spatial: spatial)
                }
                if let node { members.append(node) }
            }
            scenes.append(TreeNode(
                role: stringProperty(container, "accessibilityRole"),
                label: stringProperty(container, "accessibilityLabel"),
                title: nil, value: nil, identifier: nil, hint: nil, traits: nil,
                frame: nil, children: members
            ))
        }

        let placements = spatialProperties(of: spatial.translations)
        let sceneIDs = Set(placements.compactMap { $0?.sceneID })
        var world: VisionOSWorld?
        do {
            world = try visibleWorld.wait()
            let missing = sceneIDs.subtracting(world!.scenes.keys)
            if !missing.isEmpty {
                logDiagnostic("visionOS: \(missing.count) scenes not visible, asking for them by ID")
                let remaining = (deadline - ContinuousClock.now).totalSeconds
                let more = try VisionOSWorldHelper.world(device: device, scenes: missing, timeoutSeconds: max(remaining, 0.5))
                world!.scenes.merge(more.scenes) { _, new in new }
            }
        } catch {
            // Without placement every frame is unknown, but the tree is still useful.
            FileHandle.standardError.write(Data("[iosef] visionOS element frames unavailable: \(error.localizedDescription)\n".utf8))
        }

        var entries = placements.makeIterator()
        let projected = scenes.map { scene in
            let children = scene.children.map {
                applySpatialFrames($0, entries: &entries, world: world, camera: camera)
            }
            return Self.withFrame(Self.union(children.compactMap(\.frame)), children: children, of: scene)
        }

        logDiagnostic("accessibility (visionOS): \(elementCount) elements, \(sceneIDs.count) scenes in \(Int((ContinuousClock.now - start).totalSeconds * 1000))ms")
        let screen = TreeNode.FrameInfo(x: 0, y: 0, width: Double(iosPointSize.width), height: Double(iosPointSize.height))
        return [TreeNode(
            role: stringProperty(shell, "accessibilityRole"), label: stringProperty(shell, "accessibilityLabel"),
            title: nil, value: nil, identifier: nil, hint: nil, traits: nil,
            frame: screen, children: projected
        )]
    }

    /// Replaces the frames of `node` and its descendants (in the pre-order `serializeElement`
    /// collected `entries`) with their projected screen frames. An element with no placement
    /// of its own takes the union of its children's frames, or none.
    private func applySpatialFrames(_ node: TreeNode, entries: inout IndexingIterator<[SpatialProperties?]>,
                                    world: VisionOSWorld?, camera: GazeCamera) -> TreeNode {
        let properties = entries.next() ?? nil
        let children = node.children.map { applySpatialFrames($0, entries: &entries, world: world, camera: camera) }
        let frame = properties.flatMap { world?.screenFrame(of: $0, camera: camera, screenSize: iosPointSize) }
            ?? Self.union(children.compactMap(\.frame))
        return Self.withFrame(frame, children: children, of: node)
    }

    private static func withFrame(_ frame: TreeNode.FrameInfo?, children: [TreeNode], of node: TreeNode) -> TreeNode {
        TreeNode(role: node.role, label: node.label, title: node.title, value: node.value,
                 identifier: node.identifier, hint: node.hint, traits: node.traits,
                 frame: frame, children: children)
    }

    private static func union(_ frames: [TreeNode.FrameInfo]) -> TreeNode.FrameInfo? {
        guard let minX = frames.map(\.x).min(), let minY = frames.map(\.y).min(),
              let maxX = frames.map({ $0.x + $0.width }).max(),
              let maxY = frames.map({ $0.y + $0.height }).max() else { return nil }
        return TreeNode.FrameInfo(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The node with the smallest frame containing `point`, searching the whole tree.
    static func smallestNode(containing point: (x: Double, y: Double), in nodes: [TreeNode]) -> TreeNode? {
        var best: (node: TreeNode, area: Double)?
        func visit(_ node: TreeNode) {
            if let f = node.frame, point.x >= f.x, point.x <= f.x + f.width, point.y >= f.y, point.y <= f.y + f.height {
                let area = f.width * f.height
                if best == nil || area < best!.area { best = (node, area) }
            }
            node.children.forEach(visit)
        }
        nodes.forEach(visit)
        return best?.node
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
                let remainingSecs = remaining.totalSeconds
                if remainingSecs <= 0 {
                    return Self.emptyAXPResponse()
                }
                xpcTimeout = min(remainingSecs, 10.0)
            } else {
                xpcTimeout = 10.0
            }

            do {
                if ProcessInfo.processInfo.environment["IOSEF_AXP_DUMP"] != nil {
                    logDiagnostic("request \(type(of: request)): \(request)", prefix: "AXPDump")
                }
                let response = try self.bridge.sendAccessibilityRequest(request, toDevice: dev, timeoutSeconds: xpcTimeout)
                if ProcessInfo.processInfo.environment["IOSEF_AXP_DUMP"] != nil {
                    logDiagnostic("response \(type(of: response)): \(response)", prefix: "AXPDump")
                }
                return response
            } catch {
                logDiagnostic("XPC call failed: \(error.localizedDescription)")
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
