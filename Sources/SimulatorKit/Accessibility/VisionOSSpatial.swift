import CryptoKit
import Foundation
import ObjectiveC
import simd

/// Where a visionOS accessibility element sits in 3D, from its XCTest automation
/// properties (iOS attribute 5063, `AXAutomationSystemProperties`).
///
/// visionOS reports `accessibilityFrame` in window-local points, which says nothing about
/// where the window is. The automation properties place the element in its scene instead,
/// in meters:
///
///     AXSceneID                      = "com.example.app:SFBSystemService-…"
///     AXTopLevelEntitySpaceTransform = 4x4, column-major (element -> the scene's top-level entity)
///     AXBoundingBox                  = ((minX, minY, minZ), (maxX, maxY, maxZ)), element space
///
/// Combined with the scene's world transform and the head pose (see `VisionOSWorld`), that
/// projects onto the screen through the same camera that gaze input uses. (Window chrome
/// reports its own `AXTopLevelEntityID` but a transform relative to the window's scene, so
/// the scene is the reliable anchor; MuseAccessibility composes them the same way.)
struct SpatialProperties: Equatable {
    var sceneID: String
    var transform: simd_double4x4
    var boundingBoxMin: SIMD3<Double>
    var boundingBoxMax: SIMD3<Double>
    var pointsPerMeter: Double = 1360

    /// Parses the automation properties dictionary; nil when it doesn't place the element
    /// (system containers, or an older runtime).
    init?(automationProperties dict: [String: Any]) {
        guard let sceneID = dict["AXSceneID"] as? String, !sceneID.isEmpty,
              let transform = dict["AXTopLevelEntitySpaceTransform"].flatMap(Self.matrix) else {
            return nil
        }
        // RealityKit entities report no bounding box here; the caller fills it in.
        let box = dict["AXBoundingBox"].flatMap(Self.boundingBox) ?? (.zero, .zero)
        self.init(sceneID: sceneID, transform: transform, boundingBoxMin: box.min, boundingBoxMax: box.max,
                  pointsPerMeter: dict["AXPointsPerMeter"].flatMap(Self.double) ?? 1360)
    }

    init(sceneID: String, transform: simd_double4x4,
         boundingBoxMin: SIMD3<Double>, boundingBoxMax: SIMD3<Double>, pointsPerMeter: Double = 1360) {
        self.sceneID = sceneID
        self.transform = transform
        self.boundingBoxMin = boundingBoxMin
        self.boundingBoxMax = boundingBoxMax
        self.pointsPerMeter = pointsPerMeter
    }

    /// A view whose full properties are known, and its `AXWindowSpaceTransform` (element
    /// points -> window points, Y down).
    struct Anchor {
        var properties: SpatialProperties
        var windowSpaceTransform: simd_double4x4
    }

    /// A view in the same window as `anchor`, placed from its own window-space transform:
    /// both share the map from window points to top-level-entity meters, so
    ///
    ///     transform = anchor.transform * B^-1 * anchorWindow^-1 * window * B
    ///
    /// where B = diag(ppm, -ppm, ppm) takes element meters (Y up) to element points (Y down).
    init(relativeTo anchor: Anchor, windowSpaceTransform window: simd_double4x4,
         boundingBox: (min: SIMD3<Double>, max: SIMD3<Double>)) {
        let ppm = anchor.properties.pointsPerMeter
        let b = simd_double4x4(diagonal: SIMD4(ppm, -ppm, ppm, 1))
        self.init(
            sceneID: anchor.properties.sceneID,
            transform: anchor.properties.transform * b.inverse * anchor.windowSpaceTransform.inverse * window * b,
            boundingBoxMin: boundingBox.min, boundingBoxMax: boundingBox.max, pointsPerMeter: ppm
        )
    }

    /// The eight corners of the bounding box, in element space.
    var corners: [SIMD3<Double>] {
        let (lo, hi) = (boundingBoxMin, boundingBoxMax)
        return [lo.x, hi.x].flatMap { x in [lo.y, hi.y].flatMap { y in [lo.z, hi.z].map { SIMD3(x, y, $0) } } }
    }

    // Values arrive as NSNumber, or as NSString after secure-coding post-processing.
    private static func double(_ value: Any) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private static func vector(_ value: Any) -> SIMD3<Double>? {
        guard let a = value as? [Any], a.count == 3 else { return nil }
        let v = a.compactMap(double)
        return v.count == 3 ? SIMD3(v[0], v[1], v[2]) : nil
    }

    /// ((minX, minY, minZ), (maxX, maxY, maxZ)).
    static func boundingBox(_ value: Any) -> (min: SIMD3<Double>, max: SIMD3<Double>)? {
        guard let box = value as? [Any], box.count == 2,
              let min = vector(box[0]), let max = vector(box[1]) else { return nil }
        return (min, max)
    }

    /// A 4x4 given as four columns of four.
    static func matrix(_ value: Any) -> simd_double4x4? {
        guard let cols = value as? [Any], cols.count == 4 else { return nil }
        var columns: [SIMD4<Double>] = []
        for col in cols {
            guard let a = col as? [Any], a.count == 4 else { return nil }
            let v = a.compactMap(double)
            guard v.count == 4 else { return nil }
            columns.append(SIMD4(v[0], v[1], v[2], v[3]))
        }
        return simd_double4x4(columns)
    }
}

/// World transforms the AX tree can't supply: the head pose and each scene's placement in
/// the world. Both come from RealitySystemSupport, which is only reachable from
/// inside the simulator, so `VisionOSWorldHelper` asks for them from a process it spawns there.
struct VisionOSWorld {
    var head: simd_double4x4
    var scenes: [String: simd_double4x4]

    /// The element's on-screen frame in screen points: its bounding box carried into head
    /// space and projected through `camera`. Nil when the scene is unknown or the element
    /// isn't in view: partly behind the viewer (like the HUD scenes parked at the wrists), or
    /// entirely off screen.
    func screenFrame(of element: SpatialProperties, camera: GazeCamera, screenSize: CGSize) -> TreeNode.FrameInfo? {
        guard let scene = scenes[element.sceneID] else { return nil }
        let toHead = head.inverse * scene * element.transform
        var ratios: [(x: Double, y: Double)] = []
        for corner in element.corners {
            let p = toHead * SIMD4(corner, 1)
            guard let r = camera.screenRatios(ofHeadSpacePoint: SIMD3(p.x, p.y, p.z)) else { return nil }
            ratios.append(r)
        }
        let xs = ratios.map { $0.x * Double(screenSize.width) }
        let ys = ratios.map { $0.y * Double(screenSize.height) }
        guard xs.max()! > 0, xs.min()! < Double(screenSize.width),
              ys.max()! > 0, ys.min()! < Double(screenSize.height) else { return nil }
        let round = { (v: Double) in (v * 100).rounded() / 100 }
        return TreeNode.FrameInfo(
            x: round(xs.min()!), y: round(ys.min()!),
            width: round(xs.max()! - xs.min()!), height: round(ys.max()! - ys.min()!)
        )
    }
}

extension GazeCamera {
    /// Where a head-space point (meters; -Z ahead, +Y up) appears on screen, as 0...1 ratios
    /// from the top-left: the inverse of `ray(xRatio:yRatio:)`. Nil for points behind the
    /// viewer (or within a centimeter of the eye).
    func screenRatios(ofHeadSpacePoint p: SIMD3<Double>) -> (x: Double, y: Double)? {
        guard p.z < -0.01 else { return nil }
        let halfWidth = tan(horizontalFieldOfViewDegrees * .pi / 360)
        let halfHeight = halfWidth / aspectRatio
        return (0.5 + (p.x / -p.z) / (2 * halfWidth), 0.5 - (p.y / -p.z) / (2 * halfHeight))
    }
}

/// Runs a small Objective-C program inside the visionOS simulator that reads the head pose
/// and scene world transforms from RealitySystemSupport (`RSSApplicationService`, via
/// MuseAccessibility's `+[AXUIElement _rssApplicationService]`, the same service XCTest uses
/// to place elements).
///
/// The program is compiled on first use with the Xcode's xrsimulator SDK and cached under
/// `~/Library/Caches/iosef`, keyed by a hash of its source. It is launched with
/// `-[SimDevice spawnWithPath:…]` rather than `simctl spawn`, which costs about a second.
enum VisionOSWorldHelper {
    static let source = #"""
    #import <Foundation/Foundation.h>
    #include <dlfcn.h>
    #include <objc/message.h>
    #include <simd/simd.h>

    static NSArray *columns(simd_float4x4 m) {
        NSMutableArray *a = [NSMutableArray array];
        for (int c = 0; c < 4; c++) {
            NSMutableArray *col = [NSMutableArray array];
            for (int r = 0; r < 4; r++) [col addObject:@(m.columns[c][r])];
            [a addObject:col];
        }
        return a;
    }

    // Usage: helper [scene id...]; prints {"head": 4x4, "scenes": {id: 4x4}} (column-major)
    // for every visible scene, and for each scene named.
    int main(int argc, char **argv) {
        @autoreleasepool {
            if (!dlopen("/System/Library/PrivateFrameworks/MuseAccessibility.framework/MuseAccessibility", RTLD_NOW)) {
                fprintf(stderr, "dlopen MuseAccessibility: %s\n", dlerror());
                return 2;
            }
            id service = ((id (*)(id, SEL))objc_msgSend)(NSClassFromString(@"AXUIElement"), sel_registerName("_rssApplicationService"));
            if (!service) {
                fprintf(stderr, "no RealitySystemSupport application service\n");
                return 3;
            }
            simd_float4x4 (*get)(id, SEL) = (void *)objc_msgSend;
            simd_float4x4 (*getScene)(id, SEL, NSString *) = (void *)objc_msgSend;
            NSMutableDictionary *scenes = [NSMutableDictionary dictionary];
            NSArray *visible = ((id (*)(id, SEL))objc_msgSend)(service, sel_registerName("visibleSceneAccessibilityProperties"));
            for (NSDictionary *scene in visible) {
                NSString *sceneID = scene[@"sceneID"];
                NSData *transform = scene[@"worldTransform"];
                if (![sceneID isKindOfClass:NSString.class] || ![transform isKindOfClass:NSData.class]
                    || transform.length != sizeof(simd_float4x4)) continue;
                simd_float4x4 m;
                memcpy(&m, transform.bytes, sizeof m);
                scenes[sceneID] = columns(m);
            }
            for (int i = 1; i < argc; i++) {
                NSString *scene = @(argv[i]);
                scenes[scene] = columns(getScene(service, sel_registerName("worldTransformOfTopLevelEntityForSceneID:"), scene));
            }
            NSDictionary *out = @{
                @"head": columns(get(service, sel_registerName("headWorldTransform"))),
                @"scenes": scenes,
            };
            NSData *json = [NSJSONSerialization dataWithJSONObject:out options:0 error:nil];
            fwrite(json.bytes, 1, json.length, stdout);
        }
        return 0;
    }
    """#

    enum HelperError: Error, LocalizedError {
        case compileFailed(String)
        case spawnFailed(String)
        case badOutput(String)

        var errorDescription: String? {
            switch self {
            case .compileFailed(let detail):
                return "Couldn't build the visionOS world-transform helper (needs Xcode's visionOS simulator SDK): \(detail)"
            case .spawnFailed(let detail):
                return "Couldn't run the visionOS world-transform helper in the simulator: \(detail)"
            case .badOutput(let detail):
                return "Unexpected output from the visionOS world-transform helper: \(detail)"
            }
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var builtPath: String?

    /// The helper's path, compiling it if this source hasn't been built yet.
    static func executablePath() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        if let builtPath { return builtPath }

        let digest = SHA256.hash(data: Data(source.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iosef", isDirectory: true)
        let path = cache.appendingPathComponent("visionos-world-helper-\(digest)").path
        if FileManager.default.isExecutableFile(atPath: path) {
            builtPath = path
            return path
        }

        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let temp = path + ".\(ProcessInfo.processInfo.processIdentifier).tmp"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--sdk", "xrsimulator", "clang", "-fobjc-arc",
                             "-target", "arm64-apple-xros1.0-simulator",
                             "-framework", "Foundation", "-x", "objective-c", "-", "-o", temp]
        process.environment = DeveloperDir.childEnvironment
        let input = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        let start = ContinuousClock.now
        do { try process.run() } catch { throw HelperError.compileFailed(error.localizedDescription) }
        input.fileHandleForWriting.write(Data(source.utf8))
        try? input.fileHandleForWriting.close()
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(atPath: temp)
            throw HelperError.compileFailed(String(decoding: stderr, as: UTF8.self))
        }
        // Rename into place so a concurrent iosef never runs a half-written binary.
        _ = rename(temp, path)
        logDiagnostic("built \(path) in \(Int((ContinuousClock.now - start).totalSeconds * 1000))ms", prefix: "VisionOSWorld")
        builtPath = path
        return path
    }

    /// Reads the head pose and the world transforms of `scenes` from the simulator.
    static func world(device: AnyObject, scenes: Set<String>, timeoutSeconds: Double) throws -> VisionOSWorld {
        let path = try executablePath()
        let output = try spawn(device: device, path: path, arguments: scenes.sorted(), timeoutSeconds: timeoutSeconds)

        guard let json = try? JSONSerialization.jsonObject(with: output) as? [String: Any],
              let head = json["head"].flatMap(SpatialProperties.matrix),
              let raw = json["scenes"] as? [String: Any] else {
            throw HelperError.badOutput(String(decoding: output.prefix(200), as: UTF8.self))
        }
        var transforms: [String: simd_double4x4] = [:]
        for (scene, value) in raw {
            // A scene RealitySystemSupport doesn't know comes back as a zero matrix.
            guard let m = SpatialProperties.matrix(value), m.columns.3.w != 0 else { continue }
            transforms[scene] = m
        }
        return VisionOSWorld(head: head, scenes: transforms)
    }

    /// A `world(device:scenes:timeoutSeconds:)` call running in the background.
    final class Pending: @unchecked Sendable {
        private var result: Result<VisionOSWorld, Error>?
        private let done = DispatchSemaphore(value: 0)

        init(device: AnyObject, scenes: Set<String>, timeoutSeconds: Double) {
            nonisolated(unsafe) let device = device
            DispatchQueue.global().async { [self] in
                result = Result { try VisionOSWorldHelper.world(device: device, scenes: scenes, timeoutSeconds: timeoutSeconds) }
                done.signal()
            }
        }

        func wait() throws -> VisionOSWorld {
            done.wait()
            return try result!.get()
        }
    }

    /// Runs `path` inside the simulator and returns its stdout.
    private static func spawn(device: AnyObject, path: String, arguments: [String], timeoutSeconds: Double) throws -> Data {
        let sel = NSSelectorFromString("spawnWithPath:options:terminationHandler:error:")
        guard let method = class_getInstanceMethod(type(of: device), sel) else {
            throw HelperError.spawnFailed("SimDevice has no spawnWithPath:options:terminationHandler:error:")
        }
        typealias SpawnFn = @convention(c) (AnyObject, Selector, NSString, NSDictionary, Any?, UnsafeMutablePointer<NSError?>?) -> Int32
        let spawnFn = unsafeBitCast(method_getImplementation(method), to: SpawnFn.self)

        let out = Pipe()
        let options: NSDictionary = [
            "arguments": [path] + arguments,
            "stdout": NSNumber(value: out.fileHandleForWriting.fileDescriptor),
        ]
        let exited = DispatchSemaphore(value: 0)
        let termination: @convention(block) (Int32) -> Void = { _ in exited.signal() }

        // Drain the pipe as it fills so a large reply can't block the helper.
        final class Output: @unchecked Sendable { var data = Data() }
        let output = Output()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            output.data = out.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }

        var error: NSError?
        let pid = spawnFn(device, sel, path as NSString, options, termination, &error)
        // Our copy of the write end must close for the reader to see EOF.
        try? out.fileHandleForWriting.close()
        guard pid > 0 else {
            throw HelperError.spawnFailed(error?.localizedDescription ?? "pid \(pid)")
        }
        guard exited.wait(timeout: .now() + timeoutSeconds) == .success,
              drained.wait(timeout: .now() + 1) == .success else {
            kill(pid, SIGKILL)
            throw HelperError.spawnFailed("timed out after \(timeoutSeconds)s")
        }
        return output.data
    }
}
