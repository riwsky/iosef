import Foundation
import simd

/// Where the visionOS simulator's viewer is, relative to the default seated pose: how far the
/// head is turned and tilted, and how far it has moved.
///
/// Rotation is applied as yaw then pitch, like turning your head and then looking up or down.
public struct HeadPose: Codable, Equatable, Sendable {
    /// Degrees to the right (negative turns left).
    public var yawDegrees: Double
    /// Degrees up (negative looks down).
    public var pitchDegrees: Double
    /// Metres to the right of the default seat.
    public var x: Double
    /// Metres above the default eye height.
    public var y: Double
    /// Metres behind the default seat: negative steps forward.
    public var z: Double

    public init(yawDegrees: Double = 0, pitchDegrees: Double = 0, x: Double = 0, y: Double = 0, z: Double = 0) {
        self.yawDegrees = yawDegrees
        self.pitchDegrees = pitchDegrees
        self.x = x
        self.y = y
        self.z = z
    }

    /// Looking straight ahead from the default seat.
    public static let `default` = HeadPose()

    var translation: SIMD3<Float> { SIMD3(Float(x), Float(y), Float(z)) }

    /// Head-to-world rotation. The simulator's world has +Y up and -Z ahead, so turning right
    /// is a negative rotation about +Y.
    var rotation: simd_quatf {
        let yaw = simd_quatf(angle: Float(-yawDegrees * .pi / 180), axis: SIMD3(0, 1, 0))
        let pitch = simd_quatf(angle: Float(pitchDegrees * .pi / 180), axis: SIMD3(1, 0, 0))
        return yaw * pitch
    }

    /// A point given relative to the head, in the world.
    func toWorld(point: SIMD3<Float>) -> SIMD3<Float> {
        translation + rotation.act(point)
    }

    /// A ray given relative to the head (as `GazeCamera` produces them), in the world, which is
    /// where the guest hit-tests selection rays.
    func toWorld(_ ray: GazeRay) -> GazeRay {
        GazeRay(origin: toWorld(point: ray.origin), direction: rotation.act(ray.direction))
    }
}

/// An Indigo "Paloma pose" message: the head's pose, addressed to the guest's pose service.
///
/// Payload layout (`e`, at 0x20 in the message), decoded by `_IOHIDEventFromIndigoPalomaPose`
/// in the xros SimulatorHID.framework into a vendor-defined event (usage 0x72) carrying a
/// translation and a quaternion:
///
/// | offset | type  | field                                   |
/// |--------|-------|-----------------------------------------|
/// | 0x00   | u32   | Indigo event type: 1                    |
/// | 0x04   | u64   | mach_absolute_time                      |
/// | 0x10   | u32   | target service: 300 (pose)              |
/// | 0x34   | f32×3 | translation from the default seat       |
/// | 0x44   | f32×4 | orientation quaternion (x, y, z, w)     |
///
/// The pose is absolute: sending `HeadPose.default` puts the viewer back in the default seat.
struct HeadPoseMessage {
    static let poseService: UInt32 = 300

    var pose: HeadPose
    var timestamp: UInt64 = mach_absolute_time()

    var data: Data {
        var bytes = [UInt8](repeating: 0, count: GazePinchMessage.messageSize)
        func put<T>(_ value: T, at offset: Int) {
            withUnsafeBytes(of: value) { raw in
                for (i, byte) in raw.enumerated() { bytes[offset + i] = byte }
            }
        }

        put(UInt32(0xA0), at: 0x18)
        bytes[0x1C] = 1

        let e = GazePinchMessage.payloadOffset
        put(UInt32(1), at: e + 0x00)
        put(timestamp, at: e + 0x04)
        put(Self.poseService, at: e + 0x10)

        let t = pose.translation
        put(t.x, at: e + 0x34); put(t.y, at: e + 0x38); put(t.z, at: e + 0x3C)
        let q = pose.rotation.vector
        put(q.x, at: e + 0x44); put(q.y, at: e + 0x48); put(q.z, at: e + 0x4C); put(q.w, at: e + 0x50)

        return Data(bytes)
    }
}

/// Remembers the head pose iosef last set on each device, since every CLI invocation is a new
/// process and the guest's selection rays are in world space: taps after `look` have to be
/// aimed from where the head now is.
///
/// A pose is tagged with the device's last boot time and ignored after a reboot, which puts the
/// viewer back in the default seat. Moving the camera by other means (e.g. Device Hub's camera
/// tools) isn't seen here.
enum HeadPoseStore {
    private struct Entry: Codable {
        var pose: HeadPose
        var bootedAt: Date?
    }

    static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iosef/head-pose", isDirectory: true)
    }

    private static func file(udid: String) -> URL {
        directory.appendingPathComponent("\(udid.uppercased()).json")
    }

    static func load(udid: String, bootedAt: Date?) -> HeadPose {
        guard let data = try? Data(contentsOf: file(udid: udid)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.bootedAt == bootedAt else { return .default }
        return entry.pose
    }

    static func save(_ pose: HeadPose, udid: String, bootedAt: Date?) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(Entry(pose: pose, bootedAt: bootedAt)).write(to: file(udid: udid), options: .atomic)
        } catch {
            logDiagnostic("couldn't save head pose: \(error.localizedDescription)", prefix: "HeadPoseStore")
        }
    }
}
