import Foundation
import Testing
@testable import SimulatorKit

@Suite("GazePinch Tests")
struct GazePinchTests {
    let camera = GazeCamera(aspectRatio: 16.0 / 9.0)

    private func isClose(_ a: SIMD3<Float>, _ b: SIMD3<Float>, tolerance: Float = 1e-5) -> Bool {
        abs(a.x - b.x) < tolerance && abs(a.y - b.y) < tolerance && abs(a.z - b.z) < tolerance
    }

    // MARK: - GazeCamera

    @Test("The screen centre looks straight ahead")
    func centreLooksAhead() {
        #expect(camera.ray(xRatio: 0.5, yRatio: 0.5).direction == SIMD3(0, 0, -1))
    }

    @Test("Screen edges sit at ±45° horizontally and the aspect-scaled extent vertically",
          arguments: [(0.0, 0.5, SIMD3<Float>(-1, 0, -1)),
                      (1.0, 0.5, SIMD3<Float>(1, 0, -1)),
                      (0.5, 0.0, SIMD3<Float>(0, 9.0 / 16.0, -1)),
                      (0.5, 1.0, SIMD3<Float>(0, -9.0 / 16.0, -1))])
    func edges(xRatio: Double, yRatio: Double, expected: SIMD3<Float>) {
        #expect(isClose(camera.ray(xRatio: xRatio, yRatio: yRatio).direction, expected))
    }

    /// The point the calibration was measured at: VisionTestApp's top-right grid button on
    /// the 1920×1080-point Apple Vision Pro (4K) simulator. A 90° field of view puts its
    /// focal length at 960 points.
    @Test("A screen point maps to its offset over a 960-point focal length")
    func calibratedPoint() {
        let ray = camera.ray(xRatio: 1293.0 / 1920, yRatio: 485.0 / 1080)
        #expect(isClose(ray.direction, SIMD3(333.0 / 960, 55.0 / 960, -1)))
    }

    @Test("Up on screen is +Y and right is +X")
    func orientation() {
        let ray = camera.ray(xRatio: 0.75, yRatio: 0.25)
        #expect(ray.direction.x > 0 && ray.direction.y > 0)
    }

    @Test("Dragging moves the hand in proportion to the change of gaze, in the view plane",
          arguments: [(0.6, 0.5), (0.4, 0.3), (0.5, 0.9)])
    func handOffsetIsProportional(xRatio: Double, yRatio: Double) {
        let start = camera.ray(xRatio: 0.5, yRatio: 0.5)
        let end = camera.ray(xRatio: xRatio, yRatio: yRatio)
        let offset = camera.handOffset(dragging: start, to: end)
        let expected = (end.direction - start.direction) * Float(camera.dragGain)
        #expect(isClose(offset, SIMD3(expected.x, expected.y, 0)))
        #expect(camera.handOffset(dragging: start, to: start) == .zero)
    }

    // MARK: - GazePinchMessage

    private func read<T>(_ type: T.Type, _ data: Data, at offset: Int) -> T {
        data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
    }

    private let e = GazePinchMessage.payloadOffset

    @Test("The message is one 0xA0-byte Indigo collection payload for the manipulator service")
    func header() {
        let data = GazePinchMessage(ray: camera.ray(xRatio: 0.5, yRatio: 0.5)).data
        #expect(data.count == 0xC0)
        #expect(read(UInt32.self, data, at: 0x18) == 0xA0)
        #expect(data[0x1C] == 1)
        #expect(read(UInt32.self, data, at: e + 0x00) == 1)
        #expect(read(UInt32.self, data, at: e + 0x10) == 302)
    }

    @Test("Each hand carries 3 bytes of data: pinch flag, then chirality; only the right pinches",
          arguments: [false, true])
    func hands(pinching: Bool) {
        var message = GazePinchMessage(ray: camera.ray(xRatio: 0.5, yRatio: 0.5))
        message.rightHandPinching = pinching
        let data = message.data
        #expect(read(UInt32.self, data, at: e + 0x14) == 3)
        #expect(data[e + 0x18] == 0)
        #expect(data[e + 0x19] == 2)
        #expect(read(UInt32.self, data, at: e + 0x1B) == 3)
        #expect(data[e + 0x1F] == (pinching ? 1 : 0))
        #expect(data[e + 0x20] == 1)
        #expect(data[e + 0x22] == 0)
    }

    @Test("The ray and hand poses land at their (unaligned) offsets")
    func geometry() {
        var message = GazePinchMessage(ray: GazeRay(origin: SIMD3(0.1, 0.2, 0.3), direction: SIMD3(0.4, -0.5, -1)))
        message.rightHandTranslation = SIMD3(0.25, -0.35, -0.45)
        let data = message.data
        func vector(at offset: Int) -> SIMD3<Float> {
            SIMD3(read(Float.self, data, at: e + offset),
                  read(Float.self, data, at: e + offset + 4),
                  read(Float.self, data, at: e + offset + 8))
        }
        #expect(vector(at: 0x27) == SIMD3(0.1, 0.2, 0.3))
        #expect(vector(at: 0x37) == SIMD3(0.4, -0.5, -1))
        #expect(vector(at: 0x47) == GazePinchMessage.restingLeftHand)
        #expect(vector(at: 0x67) == SIMD3(0.25, -0.35, -0.45))
        // Identity orientations: w is the fourth component of each quaternion.
        #expect(read(Float.self, data, at: e + 0x63) == 1)
        #expect(read(Float.self, data, at: e + 0x83) == 1)
    }

    @Test("The timestamp is carried through")
    func timestamp() {
        var message = GazePinchMessage(ray: camera.ray(xRatio: 0.5, yRatio: 0.5))
        message.timestamp = 0x0123_4567_89AB_CDEF
        #expect(read(UInt64.self, message.data, at: e + 0x04) == 0x0123_4567_89AB_CDEF)
    }
}
