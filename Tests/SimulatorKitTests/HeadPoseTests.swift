import Foundation
import simd
import Testing
@testable import SimulatorKit

@Suite("HeadPose Tests")
struct HeadPoseTests {
    private func isClose(_ a: SIMD3<Float>, _ b: SIMD3<Float>, tolerance: Float = 1e-5) -> Bool {
        abs(a.x - b.x) < tolerance && abs(a.y - b.y) < tolerance && abs(a.z - b.z) < tolerance
    }

    private let ahead = SIMD3<Float>(0, 0, -1)

    @Test("The default pose leaves rays alone")
    func defaultIsIdentity() {
        let ray = GazeRay(origin: .zero, direction: SIMD3(0.3, -0.2, -1))
        #expect(HeadPose.default.toWorld(ray) == ray)
    }

    @Test("Positive yaw turns right and positive pitch looks up",
          arguments: [(90.0, 0.0, SIMD3<Float>(1, 0, 0)),
                      (-90.0, 0.0, SIMD3<Float>(-1, 0, 0)),
                      (0.0, 90.0, SIMD3<Float>(0, 1, 0)),
                      (0.0, -90.0, SIMD3<Float>(0, -1, 0)),
                      (180.0, 0.0, SIMD3<Float>(0, 0, 1))])
    func orientation(yaw: Double, pitch: Double, expected: SIMD3<Float>) {
        let pose = HeadPose(yawDegrees: yaw, pitchDegrees: pitch)
        #expect(isClose(pose.toWorld(GazeRay(direction: ahead)).direction, expected))
    }

    @Test("Pitch is applied after yaw: turn, then look up")
    func pitchAfterYaw() {
        let pose = HeadPose(yawDegrees: 90, pitchDegrees: 45)
        let s = Float(0.5).squareRoot()
        #expect(isClose(pose.toWorld(GazeRay(direction: ahead)).direction, SIMD3(s, s, 0)))
    }

    @Test("Offsets move the ray's origin and points, in metres")
    func translation() {
        let pose = HeadPose(x: 0.5, y: -0.25, z: -1)
        let ray = pose.toWorld(GazeRay(direction: ahead))
        #expect(ray.origin == SIMD3(0.5, -0.25, -1))
        #expect(ray.direction == ahead)
        #expect(pose.toWorld(point: SIMD3(0.2, -0.3, -0.4)) == SIMD3(0.7, -0.55, -1.4))
    }

    /// The orb in VisionTestApp's immersive space is 1m left and 2m ahead: turning left by
    /// atan(1/2) puts it straight ahead, which the visionOS gauntlet relies on.
    @Test("Turning by atan(x/z) faces a point off to the side")
    func facesOffsetPoint() {
        let yaw = -atan(0.5) * 180 / .pi
        let direction = HeadPose(yawDegrees: yaw).toWorld(GazeRay(direction: ahead)).direction
        let toOrb = simd_normalize(SIMD3<Float>(-1, 0, -2))
        #expect(isClose(simd_normalize(direction), toOrb))
    }

    // MARK: - Message

    private func read<T>(_ type: T.Type, _ data: Data, at offset: Int) -> T {
        data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
    }

    @Test("The pose message targets the pose service with translation and quaternion")
    func message() {
        let pose = HeadPose(yawDegrees: 30, x: 0.1, y: 0.2, z: -0.3)
        let data = HeadPoseMessage(pose: pose).data
        let e = GazePinchMessage.payloadOffset
        #expect(data.count == 0xC0)
        #expect(read(UInt32.self, data, at: 0x18) == 0xA0)
        #expect(read(UInt32.self, data, at: e + 0x00) == 1)
        #expect(read(UInt32.self, data, at: e + 0x10) == 300)
        #expect(read(Float.self, data, at: e + 0x34) == 0.1)
        #expect(read(Float.self, data, at: e + 0x38) == 0.2)
        #expect(read(Float.self, data, at: e + 0x3C) == -0.3)
        // Turning right is a negative rotation about +Y: q = (0, -sin 15°, 0, cos 15°).
        let half = Float(15.0 * .pi / 180)
        #expect(abs(read(Float.self, data, at: e + 0x44)) < 1e-6)
        #expect(abs(read(Float.self, data, at: e + 0x48) + sin(half)) < 1e-6)
        #expect(abs(read(Float.self, data, at: e + 0x4C)) < 1e-6)
        #expect(abs(read(Float.self, data, at: e + 0x50) - cos(half)) < 1e-6)
    }

    // MARK: - Store

    @Test("A saved pose is only trusted for the boot it was set in")
    func storeIsPerBoot() {
        let udid = "TEST-\(UUID().uuidString)"
        let boot = Date(timeIntervalSince1970: 1_800_000_000)
        let pose = HeadPose(yawDegrees: 45, z: -0.5)
        defer { try? FileManager.default.removeItem(at: HeadPoseStore.directory.appendingPathComponent("\(udid.uppercased()).json")) }

        #expect(HeadPoseStore.load(udid: udid, bootedAt: boot) == .default)
        HeadPoseStore.save(pose, udid: udid, bootedAt: boot)
        #expect(HeadPoseStore.load(udid: udid, bootedAt: boot) == pose)
        #expect(HeadPoseStore.load(udid: udid.lowercased(), bootedAt: boot) == pose)
        #expect(HeadPoseStore.load(udid: udid, bootedAt: boot.addingTimeInterval(60)) == .default)
    }
}
