import Foundation
import simd
import Testing
@testable import SimulatorKit

/// Values captured from VisionTestApp on the Apple Vision Pro (4K) simulator (1920×1080
/// points), with its window in its default placement.
@Suite("visionOS spatial accessibility")
struct VisionOSSpatialTests {
    let camera = GazeCamera(aspectRatio: 16.0 / 9.0)
    let screen = CGSize(width: 1920, height: 1080)
    let windowScene = "com.mcp-test.playground.visionapp:SFBSystemService-B2927814"

    /// Grid button R0C0's automation properties, as the app reports them (some numbers come
    /// back as strings).
    var buttonProperties: [String: Any] {
        [
            "AXBackingObjectType": "View",
            "AXBoundingBox": [["-0.028125", "-0.01617647", "-0"], ["0.028125", "0.01617647", 0]],
            "AXPointsPerMeter": 1360,
            "AXSceneID": windowScene,
            "AXTopLevelEntityID": 5765687435340451464 as UInt64,
            "AXTopLevelEntitySpaceTransform": [[1, 0, 0, 0], [0, 1, "2.504705e-22", 0],
                                               [0, "-2.968977e-22", 1, 0], ["-0.3575368", "0.1356618", "3.397928e-23", 1]],
        ]
    }

    /// The window's world transform from RealitySystemSupport: 2m ahead, slightly below eye
    /// level, scaled up with distance.
    var world: VisionOSWorld {
        VisionOSWorld(head: matrix_identity_double4x4, scenes: [
            windowScene: simd_double4x4(columns: (SIMD4(1.937456, 0, 0, 0), SIMD4(0, 1.937456, 0, 0),
                                                  SIMD4(0, 0, 1.937456, 0), SIMD4(0, -0.104672, -1.997259, 1))),
        ])
    }

    private func translation(_ m: simd_double4x4) -> SIMD3<Double> {
        SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
    }

    private func isClose(_ a: SIMD3<Double>, _ b: SIMD3<Double>, tolerance: Double = 1e-5) -> Bool {
        simd_length(a - b) < tolerance
    }

    // MARK: - Parsing

    @Test("Automation properties parse, with numbers given as strings")
    func parsesAutomationProperties() throws {
        let p = try #require(SpatialProperties(automationProperties: buttonProperties))
        #expect(p.sceneID == windowScene)
        #expect(p.pointsPerMeter == 1360)
        #expect(isClose(translation(p.transform), SIMD3(-0.3575368, 0.1356618, 0)))
        #expect(isClose(p.boundingBoxMin, SIMD3(-0.028125, -0.01617647, 0)))
        #expect(isClose(p.boundingBoxMax, SIMD3(0.028125, 0.01617647, 0)))
    }

    @Test("An entity's properties parse without a bounding box")
    func parsesEntityWithoutBox() throws {
        var properties = buttonProperties
        properties["AXBoundingBox"] = nil
        properties["AXBackingObjectType"] = "Entity"
        let p = try #require(SpatialProperties(automationProperties: properties))
        #expect(p.boundingBoxMin == .zero && p.boundingBoxMax == .zero)
    }

    @Test("Properties without a scene or transform don't place the element",
          arguments: ["AXSceneID", "AXTopLevelEntitySpaceTransform"])
    func requiresSceneAndTransform(missing key: String) {
        var properties = buttonProperties
        properties[key] = nil
        #expect(SpatialProperties(automationProperties: properties) == nil)
    }

    @Test("A malformed matrix is rejected")
    func rejectsMalformedMatrix() {
        #expect(SpatialProperties.matrix([[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0]]) == nil)
        #expect(SpatialProperties.matrix([[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, "x", 1]]) == nil)
    }

    // MARK: - Projection

    @Test("GazeCamera.screenRatios inverts ray(xRatio:yRatio:)",
          arguments: [(0.5, 0.5), (0.1, 0.9), (0.8, 0.2), (0.0, 1.0), (0.33, 0.47)],
          [0.5, 2.0, 7.0])
    func screenRatiosInvertsRay(ratios: (Double, Double), depth: Double) throws {
        let direction = camera.ray(xRatio: ratios.0, yRatio: ratios.1).direction
        let point = SIMD3<Double>(Double(direction.x), Double(direction.y), Double(direction.z)) * depth
        let back = try #require(camera.screenRatios(ofHeadSpacePoint: point))
        #expect(abs(back.x - ratios.0) < 1e-6 && abs(back.y - ratios.1) < 1e-6)
    }

    @Test("Points behind the viewer have no screen position")
    func behindViewer() {
        #expect(camera.screenRatios(ofHeadSpacePoint: SIMD3(0, 0, 1)) == nil)
        #expect(camera.screenRatios(ofHeadSpacePoint: SIMD3(0.2, 0, 0)) == nil)
    }

    /// iosef's reading on the simulator, where the button's screenshot centre is (627, 463).
    @Test("A window button projects where the screenshot shows it")
    func projectsButton() throws {
        let p = try #require(SpatialProperties(automationProperties: buttonProperties))
        let frame = try #require(world.screenFrame(of: p, camera: camera, screenSize: screen))
        #expect(abs(frame.center.x - 627) < 1 && abs(frame.center.y - 464) < 1)
        #expect(abs(frame.width - 52.4) < 1 && abs(frame.height - 30.1) < 1)
    }

    @Test("Head movement moves the projection the other way")
    func followsHead() throws {
        let p = try #require(SpatialProperties(automationProperties: buttonProperties))
        var turned = world
        turned.head = simd_double4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(-0.1, 0, 0, 1)))
        let before = try #require(world.screenFrame(of: p, camera: camera, screenSize: screen))
        let after = try #require(turned.screenFrame(of: p, camera: camera, screenSize: screen))
        #expect(after.center.x > before.center.x + 40)
    }

    @Test("Elements in an unknown scene, behind the viewer, or off screen have no frame")
    func unplaceable() throws {
        var p = try #require(SpatialProperties(automationProperties: buttonProperties))
        p.sceneID = "elsewhere"
        #expect(world.screenFrame(of: p, camera: camera, screenSize: screen) == nil)

        p.sceneID = windowScene
        p.transform.columns.3 = SIMD4(0, 0, 2, 1)  // pulled back past the head
        #expect(world.screenFrame(of: p, camera: camera, screenSize: screen) == nil)

        p.transform.columns.3 = SIMD4(5, 0, 0, 1)  // far off to the right
        #expect(world.screenFrame(of: p, camera: camera, screenSize: screen) == nil)
    }

    // MARK: - Placement relative to an anchor

    @Test("Views are placed from their window-space transform relative to an anchor view",
          arguments: [
              // Grid buttons R0C2 (anchor) and R0C0: X offset only.
              (SIMD3(640.0, 175.5, 0), SIMD3(0.0, 0.1356618, 0), SIMD3(153.75, 175.5, 0), SIMD3(-0.3575368, 0.1356618, 0)),
              // Window chrome: the Close button (anchor) and the placement bar, which sit
              // slightly in front of the window.
              (SIMD3(238.0, 369, -1), SIMD3(-0.07500001, -0.2860295, -0.0007352942),
               SIMD3(342.5, 369, -2), SIMD3(0.001838237, -0.2860295, -0.001470588)),
          ])
    func derivesFromAnchor(anchorWindow: SIMD3<Double>, anchorScene: SIMD3<Double>,
                           window: SIMD3<Double>, expected: SIMD3<Double>) {
        func translated(_ t: SIMD3<Double>) -> simd_double4x4 {
            var m = matrix_identity_double4x4
            m.columns.3 = SIMD4(t, 1)
            return m
        }
        let anchor = SpatialProperties.Anchor(
            properties: SpatialProperties(sceneID: windowScene, transform: translated(anchorScene),
                                          boundingBoxMin: .zero, boundingBoxMax: .zero),
            windowSpaceTransform: translated(anchorWindow))
        let box = (min: SIMD3(-0.01, -0.01, 0.0), max: SIMD3(0.01, 0.01, 0.0))
        let p = SpatialProperties(relativeTo: anchor, windowSpaceTransform: translated(window), boundingBox: box)
        #expect(p.sceneID == windowScene)
        #expect(isClose(translation(p.transform), expected, tolerance: 1e-6))
        // The rotation/scale part stays the anchor's: element space is meters either way.
        #expect(isClose(SIMD3(p.transform.columns.0.x, p.transform.columns.1.y, p.transform.columns.2.z), SIMD3(1, 1, 1)))
        #expect(p.boundingBoxMax == box.max)
    }

    // MARK: - Point lookup

    @Test("A point resolves to the smallest element containing it")
    func smallestNode() {
        func node(_ label: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double, _ children: [TreeNode] = []) -> TreeNode {
            TreeNode(role: "AXButton", label: label, title: nil, value: nil, identifier: nil, hint: nil, traits: nil,
                     frame: .init(x: x, y: y, width: w, height: h), children: children)
        }
        let scene = node("scene", 0, 0, 500, 500, [node("big", 0, 0, 200, 200), node("small", 50, 50, 20, 20)])
        #expect(AXPAccessibilityBridge.smallestNode(containing: (60, 60), in: [scene])?.label == "small")
        #expect(AXPAccessibilityBridge.smallestNode(containing: (150, 150), in: [scene])?.label == "big")
        #expect(AXPAccessibilityBridge.smallestNode(containing: (400, 400), in: [scene])?.label == "scene")
        #expect(AXPAccessibilityBridge.smallestNode(containing: (600, 600), in: [scene]) == nil)
    }
}
