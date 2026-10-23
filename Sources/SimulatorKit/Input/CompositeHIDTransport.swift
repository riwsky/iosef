import Foundation

/// The transport `SimulatorHIDClient` actually talks to: a `HIDTransport` that dispatches
/// each event to whichever underlying transport should carry it.
///
/// - Touch and keyboard go to `DTUHIDTransport` when the device has `dtuhidd` and it
///   answers, because there the guest suppresses the legacy services. The connection is
///   made on first use and rebuilt if a simulator reboot invalidates it.
/// - Everything falls back to `IndigoHIDTransport` when dtuhidd is absent or unreachable.
/// - Hardware buttons always go to Indigo, where they stay functional; dtuhidd identifies
///   buttons by HID usage rather than by Indigo source.
/// - On visionOS, touches become gaze + pinch (`GazePinchTransport`): the guest ignores
///   digitizer contacts.
///
/// Selection happens per event, so a gesture already in flight when dtuhidd dies finishes
/// on Indigo rather than being dropped.
final class CompositeHIDTransport: HIDTransport, @unchecked Sendable {
    let name = "composite"

    /// Always true: it replaces its own parts.
    var isValid: Bool { true }

    private let device: AnyObject      // SimDevice
    private let indigo: IndigoHIDTransport

    private let lock = NSLock()
    private var dtuhid: DTUHIDTransport?
    /// Set when dtuhidd couldn't be reached, so a stream of events doesn't each pay for a
    /// doomed connection attempt before falling back to Indigo.
    private var dtuhidRetryAfter: ContinuousClock.Instant?
    private static let dtuhidRetryInterval: Duration = .seconds(30)

    /// Decided once per device: whether to try dtuhidd before Indigo.
    private let dtuhidSupported: Bool
    /// Set on visionOS devices, where it carries all touches.
    private let gazePinch: GazePinchTransport?

    init(bridge: PrivateFrameworkBridge, device: AnyObject) throws {
        self.device = device
        self.indigo = try IndigoHIDTransport(bridge: bridge, device: device)
        self.dtuhidSupported = DTUHIDTransport.isSupported(device: device, bridge: bridge)
        if bridge.isVisionOS(device: device) {
            let size = bridge.screenSize(forDevice: device)
            let camera = GazeCamera.default(aspectRatio: size.width / max(size.height, 1))
            self.gazePinch = GazePinchTransport(indigo: indigo, camera: camera)
        } else {
            self.gazePinch = nil
        }
    }

    // MARK: - HIDTransport

    func sendTouch(xRatio: Double, yRatio: Double, phase: HIDTouchPhase) {
        if let gazePinch {
            gazePinch.sendTouch(xRatio: xRatio, yRatio: yRatio, phase: phase)
        } else {
            touchAndKeyboard().sendTouch(xRatio: xRatio, yRatio: yRatio, phase: phase)
        }
    }

    func sendTouches(
        _ first: (xRatio: Double, yRatio: Double),
        _ second: (xRatio: Double, yRatio: Double),
        phase: HIDTouchPhase
    ) {
        if let gazePinch {
            gazePinch.sendTouches(first, second, phase: phase)
        } else {
            touchAndKeyboard().sendTouches(first, second, phase: phase)
        }
    }

    func sendKey(usage: UInt8, down: Bool) {
        touchAndKeyboard().sendKey(usage: usage, down: down)
    }

    func sendButton(source: UInt32, direction: Int32) {
        indigo.sendButton(source: source, direction: direction)
    }

    func flush() {
        lock.withLock { dtuhid }?.flush()
        indigo.flush()
    }

    // MARK: - visionOS

    /// The visionOS input path, or nil on other platforms.
    var visionOS: GazePinchTransport? { gazePinch }

    // MARK: - Dispatch

    /// `IOSEF_HID_TRANSPORT=indigo` forces the legacy path, for debugging.
    private func touchAndKeyboard() -> any HIDTransport {
        if ProcessInfo.processInfo.environment["IOSEF_HID_TRANSPORT"] == indigo.name { return indigo }
        guard dtuhidSupported else { return indigo }

        lock.lock()
        defer { lock.unlock() }

        if let dtuhid, dtuhid.isValid { return dtuhid }
        dtuhid = nil

        let now = ContinuousClock.now
        if let retryAfter = dtuhidRetryAfter, now < retryAfter { return indigo }

        do {
            let connected = try DTUHIDTransport(device: device)
            dtuhid = connected
            dtuhidRetryAfter = nil
            logDiagnostic("using \(connected.name) transport", prefix: "CompositeHIDTransport")
            return connected
        } catch {
            dtuhidRetryAfter = now.advanced(by: Self.dtuhidRetryInterval)
            logDiagnostic("dtuhidd unavailable, falling back to \(indigo.name): \(error.localizedDescription)", prefix: "CompositeHIDTransport")
            return indigo
        }
    }
}
