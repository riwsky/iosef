import Foundation

/// Carries touches on visionOS simulators as gaze + pinch.
///
/// visionOS ignores direct digitizer contacts (they're accepted and dropped), and the guest
/// doesn't vend a dtuhidd digitizer either; UI only responds to *indirect* input: a
/// selection ray from the eyes plus a hand pinch. The simulator's SimulatorHID turns an
/// Indigo "Paloma collection" message into exactly that, so a touch becomes a stream of
/// collection frames: the ray through the touched screen point, with the right hand
/// pinching while the finger is down.
///
/// Wire format reverse-engineered from `_IOHIDEventFromIndigoHIDData` in the xros
/// SimulatorHID.framework and its consumer, `rcp::SyntheticNaturalInputEventProvider` in
/// RealitySystemSupport.framework. See `GazePinchMessage` for the layout.
///
/// To see what the guest makes of the frames, turn on its debug logging and stream
/// backboardd for `Selection ray`, `Manipulator: Active` and `Contact updated`:
///
///     xcrun simctl spawn <udid> log config --subsystem com.apple.RealitySystemSupport --mode level:debug
///
/// It only carries touches; `CompositeHIDTransport` sends keys and buttons over Indigo itself.
final class GazePinchTransport: @unchecked Sendable {
    private let indigo: IndigoHIDTransport
    private let camera: GazeCamera
    private let lock = NSLock()
    /// The frame being repeated while a pinch is held, in head space. Its ray stays where the
    /// pinch started.
    private var held: GazePinchMessage?
    /// Where the viewer's head is; frames are composed relative to it and sent in world space.
    private var headPose = HeadPose.default
    private var holdTimer: DispatchSourceTimer?

    /// Real hardware reports hands at display rate; a pinch is held by repeating the frame.
    private static let frameMicros: useconds_t = 16_000
    /// Frames of plain gaze before a pinch starts, so the system has hit-tested the target
    /// (hover) before the contact begins.
    private static let hoverFrames = 6
    /// Frames of released gaze after a pinch ends, so the release isn't the last word.
    private static let releaseFrames = 3

    init(indigo: IndigoHIDTransport, camera: GazeCamera) {
        self.indigo = indigo
        self.camera = camera
    }

    deinit {
        holdTimer?.cancel()
    }

    // MARK: - Touches

    func sendTouch(xRatio: Double, yRatio: Double, phase: HIDTouchPhase) {
        let ray = camera.ray(xRatio: xRatio, yRatio: yRatio)
        switch phase {
        case .start:
            let hover = GazePinchMessage(ray: ray)
            for _ in 0..<Self.hoverFrames { send(hover); usleep(Self.frameMicros) }
            var pinch = hover
            pinch.rightHandPinching = true
            send(pinch)
            startHolding(pinch)
        case .position:
            // visionOS picks the target with the gaze when the pinch starts and then follows
            // the hand, so a drag keeps the starting ray and moves the hand instead. The hold
            // timer delivers the updated frame.
            lock.withLock {
                guard var frame = held else { return }
                frame.rightHandTranslation = GazePinchMessage.restingRightHand
                    + camera.handOffset(dragging: frame.ray, to: ray)
                held = frame
            }
        case .end:
            var release = stopHolding() ?? GazePinchMessage(ray: ray)
            release.rightHandPinching = false
            send(release)
            for _ in 1..<Self.releaseFrames { usleep(Self.frameMicros); send(release) }
        }
    }

    /// visionOS has one selection ray, so a second finger has nowhere to go. Two-handed
    /// manipulation (zoom/rotate) needs hand poses rather than rays and isn't supported yet;
    /// the first finger alone is delivered so the gesture at least selects.
    func sendTouches(
        _ first: (xRatio: Double, yRatio: Double),
        _ second: (xRatio: Double, yRatio: Double),
        phase: HIDTouchPhase
    ) {
        if phase == .start {
            logDiagnostic("two-finger gestures aren't supported on visionOS; sending the first finger only", prefix: "GazePinchTransport")
        }
        sendTouch(xRatio: first.xRatio, yRatio: first.yRatio, phase: phase)
    }

    // MARK: - Head pose

    /// Adopts a pose the guest already has (set by an earlier process), without sending it.
    func assumeHeadPose(_ pose: HeadPose) {
        lock.withLock { headPose = pose }
    }

    /// Moves the viewer's head. The guest keeps the pose until it's changed or the simulator
    /// reboots; a few frames make sure it lands.
    func setHeadPose(_ pose: HeadPose) {
        lock.withLock { headPose = pose }
        for _ in 0..<5 {
            indigo.sendRaw(HeadPoseMessage(pose: pose).data)
            usleep(Self.frameMicros)
        }
    }

    // MARK: - Holding a pinch

    private func startHolding(_ frame: GazePinchMessage) {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        let interval = DispatchTimeInterval.microseconds(Int(Self.frameMicros))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self, let frame = self.lock.withLock({ self.held }) else { return }
            self.send(frame)
        }
        lock.withLock {
            holdTimer?.cancel()
            held = frame
            holdTimer = timer
        }
        timer.resume()
    }

    /// Stops repeating the held frame and returns it.
    private func stopHolding() -> GazePinchMessage? {
        let (timer, frame) = lock.withLock { () -> (DispatchSourceTimer?, GazePinchMessage?) in
            defer { holdTimer = nil; held = nil }
            return (holdTimer, held)
        }
        timer?.cancel()
        return frame
    }

    /// Sends a head-space frame, placed in the world where the head now is.
    private func send(_ frame: GazePinchMessage) {
        let pose = lock.withLock { headPose }
        var frame = frame
        frame.ray = pose.toWorld(frame.ray)
        frame.leftHandTranslation = pose.toWorld(point: frame.leftHandTranslation)
        frame.rightHandTranslation = pose.toWorld(point: frame.rightHandTranslation)
        frame.timestamp = mach_absolute_time()
        indigo.sendRaw(frame.data)
    }
}

/// A selection ray from the viewer's eyes, in the simulator's head space: meters, -Z ahead,
/// +Y up.
struct GazeRay: Equatable {
    var origin: SIMD3<Float> = .zero
    var direction: SIMD3<Float>
}

/// The visionOS simulator's default viewpoint, for turning a point on its screen into the
/// gaze ray that passes through it.
///
/// The simulator renders a pinhole view from the head with a 90° horizontal field of view,
/// so the focal length is half the screen width. Measured by tapping a grid of buttons
/// spanning a window (VisionTestApp) on the visionOS 26.4 and 27.0 runtimes: hits held for
/// focal lengths of roughly 895–1040 points on a 1920-point-wide screen, centred on 960.
struct GazeCamera: Equatable {
    /// Screen width over height, e.g. 16/9 for the Apple Vision Pro (4K) simulator.
    var aspectRatio: Double
    var horizontalFieldOfViewDegrees: Double = 90

    /// `IOSEF_GAZE_HFOV_DEGREES` and `IOSEF_GAZE_DRAG_GAIN` override the field of view and
    /// drag gain, for re-calibrating against a simulator whose camera differs.
    static func `default`(aspectRatio: Double) -> GazeCamera {
        var camera = GazeCamera(aspectRatio: aspectRatio)
        let env = ProcessInfo.processInfo.environment
        if let fov = env["IOSEF_GAZE_HFOV_DEGREES"].flatMap(Double.init) {
            camera.horizontalFieldOfViewDegrees = fov
        }
        if let gain = env["IOSEF_GAZE_DRAG_GAIN"].flatMap(Double.init) {
            camera.dragGain = gain
        }
        return camera
    }

    /// The ray through a point on the screen, given as 0...1 ratios from the top-left (the
    /// same ratios digitizer touches use).
    func ray(xRatio: Double, yRatio: Double) -> GazeRay {
        let halfWidth = tan(horizontalFieldOfViewDegrees * .pi / 360)
        let halfHeight = halfWidth / aspectRatio
        let dx = (xRatio - 0.5) * 2 * halfWidth
        let dy = -(yRatio - 0.5) * 2 * halfHeight
        return GazeRay(direction: SIMD3(Float(dx), Float(dy), -1))
    }

    /// How far (meters, head space) to move the pinching hand so that content grabbed along
    /// `start` follows the gaze to `end`: the change in ray direction scaled by `dragGain`.
    func handOffset(dragging start: GazeRay, to end: GazeRay) -> SIMD3<Float> {
        let delta = end.direction - start.direction
        return SIMD3(delta.x, delta.y, 0) * Float(dragGain)
    }

    /// Meters of hand movement per unit change of ray direction. Measured by dragging a
    /// token in a window (VisionTestApp): at 1.4 a 120-point drag moves it 122 points, and
    /// vertical and diagonal drags land within 3 points.
    var dragGain: Double = 1.4
}

/// An Indigo "Paloma collection" message: a selection ray plus both hands, addressed to the
/// guest's manipulator service.
///
/// Layout of the payload (`e`, at 0x20 in the message; packed, so many fields are unaligned):
///
/// | offset | type        | field                                                   |
/// |--------|-------------|---------------------------------------------------------|
/// | 0x00   | u32         | Indigo event type: 1 (collection)                       |
/// | 0x04   | u64         | mach_absolute_time                                      |
/// | 0x0C   | u32         | options for the right hand's events                     |
/// | 0x10   | u32         | target service: 300 pose, 301 selection, 302 manipulator |
/// | 0x14   | u32         | left hand data length (3)                               |
/// | 0x18   | u8[3]       | left hand: flags (bit 0 = pinch), chirality (2), 0      |
/// | 0x1B   | u32         | right hand data length (3)                              |
/// | 0x1F   | u8[3]       | right hand: flags (bit 0 = pinch), chirality (1), 0     |
/// | 0x22   | u8          | nonzero to omit the hands                               |
/// | 0x23   | u16         | left hand IOHIDEvent phase                              |
/// | 0x25   | u16         | right hand IOHIDEvent phase                             |
/// | 0x27   | f32×3 (+4)  | selection ray origin                                    |
/// | 0x37   | f32×3 (+4)  | selection ray direction                                 |
/// | 0x47   | f32×3 (+4)  | left hand translation                                   |
/// | 0x57   | f32×4       | left hand orientation quaternion (x, y, z, w)           |
/// | 0x67   | f32×3 (+4)  | right hand translation                                  |
/// | 0x77   | f32×4       | right hand orientation quaternion (x, y, z, w)          |
///
/// The consumer matches each hand by its chirality byte, so both must be set even when only
/// one pinches; with only one hand pinching the guest sees a single contact, which SwiftUI
/// recognizes as a tap.
struct GazePinchMessage {
    static let messageSize = 0xC0
    static let payloadOffset = 0x20

    /// The guest's manipulator service. (300 is head pose and 301 the selection stream; a
    /// pinch sent to the selection stream registers as two contacts.)
    static let manipulatorService: UInt32 = 302

    enum Chirality: UInt8 {
        case right = 1
        case left = 2
    }

    var ray: GazeRay
    /// Only the right hand pinches: with both, the guest sees two contacts and SwiftUI
    /// doesn't take it as a tap.
    var rightHandPinching = false
    var timestamp: UInt64 = mach_absolute_time()

    /// Resting hand poses, roughly where relaxed hands sit, relative to the head.
    static let restingLeftHand = SIMD3<Float>(-0.2, -0.3, -0.4)
    static let restingRightHand = SIMD3<Float>(0.2, -0.3, -0.4)

    var leftHandTranslation = restingLeftHand
    var rightHandTranslation = restingRightHand

    var data: Data {
        var bytes = [UInt8](repeating: 0, count: Self.messageSize)
        func put<T>(_ value: T, at offset: Int) {
            withUnsafeBytes(of: value) { raw in
                for (i, byte) in raw.enumerated() { bytes[offset + i] = byte }
            }
        }
        func putVector(_ v: SIMD3<Float>, at offset: Int) {
            put(v.x, at: offset); put(v.y, at: offset + 4); put(v.z, at: offset + 8)
        }

        // Message header: one 0xA0-byte payload.
        put(UInt32(0xA0), at: 0x18)
        bytes[0x1C] = 1

        let e = Self.payloadOffset
        put(UInt32(1), at: e + 0x00)
        put(timestamp, at: e + 0x04)
        put(Self.manipulatorService, at: e + 0x10)

        put(UInt32(3), at: e + 0x14)
        bytes[e + 0x19] = Chirality.left.rawValue
        put(UInt32(3), at: e + 0x1B)
        bytes[e + 0x1F] = rightHandPinching ? 1 : 0
        bytes[e + 0x20] = Chirality.right.rawValue

        // kIOHIDEventPhaseChanged: the hands are continuously tracked.
        put(UInt16(2), at: e + 0x23)
        put(UInt16(2), at: e + 0x25)

        putVector(ray.origin, at: e + 0x27)
        putVector(ray.direction, at: e + 0x37)

        putVector(leftHandTranslation, at: e + 0x47)
        put(Float(1), at: e + 0x63)   // identity orientation (w)
        putVector(rightHandTranslation, at: e + 0x67)
        put(Float(1), at: e + 0x83)

        return Data(bytes)
    }
}
