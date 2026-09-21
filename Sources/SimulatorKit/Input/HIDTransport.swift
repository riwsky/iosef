import Foundation

/// The phase of a single digitizer contact.
enum HIDTouchPhase {
    /// Finger lands.
    case start
    /// Finger moves while down.
    case position
    /// Finger lifts.
    case end
}

/// A way of getting touch, keyboard and button events into a simulator's guest. `SimulatorHIDClient`
/// composes gestures out of these primitives, so a transport only has to know how to put
/// one event on the wire.
protocol HIDTransport: AnyObject, Sendable {
    /// Short name for diagnostics.
    var name: String { get }

    /// False once the transport can no longer deliver and should be replaced, e.g. because
    /// the simulator rebooted under it. A transport that recovers on its own stays true.
    var isValid: Bool { get }

    /// Sends one digitizer contact. `xRatio`/`yRatio` are 0...1 from the top-left.
    func sendTouch(xRatio: Double, yRatio: Double, phase: HIDTouchPhase)

    /// Sends two simultaneous digitizer contacts, sharing one phase. Ratios as in `sendTouch`.
    func sendTouches(
        _ first: (xRatio: Double, yRatio: Double),
        _ second: (xRatio: Double, yRatio: Double),
        phase: HIDTouchPhase)

    /// Sends one keyboard event. `usage` is a USB HID keyboard usage code.
    func sendKey(usage: UInt8, down: Bool)

    /// Sends one hardware button event (home, lock, side, etc.). `source` and `direction`
    /// are Indigo's button source and direction codes.
    func sendButton(source: UInt32, direction: Int32)

    /// Blocks until everything sent so far has been handed to the guest. Called at the end
    /// of each gesture, so a process exiting straight afterwards doesn't take events with it.
    func flush()
}
