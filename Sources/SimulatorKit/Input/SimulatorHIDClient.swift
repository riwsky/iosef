import Foundation
import CoreGraphics

/// Sends touch, swipe, keyboard, and button events to a specific iOS Simulator device.
/// Does not move the macOS mouse cursor.
///
/// Gestures are composed here out of `HIDTransport` primitives; which transport carries
/// each event is `CompositeHIDTransport`'s business.
public final class SimulatorHIDClient: @unchecked Sendable {
    public let screenSize: CGSize      // pixel dimensions (e.g., 1179x2556)
    public let screenScale: Float      // e.g., 3.0

    private let transport: any HIDTransport

    public init(udid: String) throws {
        let bridge = PrivateFrameworkBridge.shared
        try bridge.ensureLoaded()

        let device = try bridge.lookUpDevice(udid: udid)
        self.transport = try CompositeHIDTransport(bridge: bridge, device: device)
        self.screenSize = bridge.screenSize(forDevice: device)
        self.screenScale = bridge.screenScale(forDevice: device)
    }

    // MARK: - Public API

    /// Sends a tap at the given iOS point coordinates.
    public func tap(x: Double, y: Double) {
        press(x: x, y: y, holdMicros: 30_000)  // 30ms hold
    }

    /// Sends a long press at the given iOS point coordinates.
    public func longPress(x: Double, y: Double, duration: Double) {
        press(x: x, y: y, holdMicros: UInt32(duration * 1_000_000))
    }

    private func press(x: Double, y: Double, holdMicros: UInt32) {
        let ratio = indigoScreenRatio(x: x, y: y, screenSize: screenSize, screenScale: screenScale)

        transport.sendTouch(xRatio: ratio.xRatio, yRatio: ratio.yRatio, phase: .start)
        usleep(holdMicros)
        transport.sendTouch(xRatio: ratio.xRatio, yRatio: ratio.yRatio, phase: .end)
        transport.flush()
    }

    /// Sends a swipe gesture from start to end iOS point coordinates.
    public func swipe(
        startX: Double, startY: Double,
        endX: Double, endY: Double,
        steps: Int = 20,
        durationSeconds: Double? = nil
    ) {
        let startRatio = indigoScreenRatio(x: startX, y: startY, screenSize: screenSize, screenScale: screenScale)
        let endRatio = indigoScreenRatio(x: endX, y: endY, screenSize: screenSize, screenScale: screenScale)

        let stepCount = max(1, steps)
        let stepDelay = durationSeconds.map { $0 / Double(stepCount) } ?? 0.01
        let stepDelayMicros = UInt32(stepDelay * 1_000_000)
        let dxRatio = (endRatio.xRatio - startRatio.xRatio) / Double(stepCount)
        let dyRatio = (endRatio.yRatio - startRatio.yRatio) / Double(stepCount)

        transport.sendTouch(xRatio: startRatio.xRatio, yRatio: startRatio.yRatio, phase: .start)
        for i in 1...stepCount {
            autoreleasepool {
                transport.sendTouch(
                    xRatio: startRatio.xRatio + dxRatio * Double(i),
                    yRatio: startRatio.yRatio + dyRatio * Double(i),
                    phase: .position)
                usleep(stepDelayMicros)
            }
        }
        transport.sendTouch(xRatio: endRatio.xRatio, yRatio: endRatio.yRatio, phase: .end)
        transport.flush()
    }

    /// Sends a hardware button press (home, lock, side, etc.).
    public func pressButton(source: UInt32, direction: Int32) {
        transport.sendButton(source: source, direction: direction)
    }

    // MARK: - Keyboard Input

    /// Types a string by sending per-character HID keyboard events.
    public func typeText(_ text: String) {
        let leftShift: UInt8 = 0xE1

        for char in text {
            autoreleasepool {
                guard let (keyCode, needsShift) = Self.hidKeyCode(for: char) else { return }

                if needsShift { transport.sendKey(usage: leftShift, down: true) }
                transport.sendKey(usage: keyCode, down: true)
                transport.sendKey(usage: keyCode, down: false)
                if needsShift { transport.sendKey(usage: leftShift, down: false) }

                usleep(10_000)  // 10ms between characters
            }
        }
        transport.flush()
    }

    /// Maps an ASCII character to its USB HID keycode and whether Shift is needed.
    private static func hidKeyCode(for char: Character) -> (keyCode: UInt8, needsShift: Bool)? {
        switch char {
        // Letters
        case "a"..."z":
            return (UInt8(char.asciiValue! - Character("a").asciiValue! + 0x04), false)
        case "A"..."Z":
            return (UInt8(char.asciiValue! - Character("A").asciiValue! + 0x04), true)
        // Numbers
        case "1"..."9":
            return (UInt8(char.asciiValue! - Character("1").asciiValue! + 0x1E), false)
        case "0":
            return (0x27, false)
        // Shifted number row symbols
        case "!": return (0x1E, true)
        case "@": return (0x1F, true)
        case "#": return (0x20, true)
        case "$": return (0x21, true)
        case "%": return (0x22, true)
        case "^": return (0x23, true)
        case "&": return (0x24, true)
        case "*": return (0x25, true)
        case "(": return (0x26, true)
        case ")": return (0x27, true)
        // Special keys
        case "\n": return (0x28, false)  // Enter/Return
        case "\t": return (0x2B, false)  // Tab
        case " ":  return (0x2C, false)  // Space
        // Punctuation (unshifted / shifted pairs)
        case "-": return (0x2D, false)
        case "_": return (0x2D, true)
        case "=": return (0x2E, false)
        case "+": return (0x2E, true)
        case "[": return (0x2F, false)
        case "{": return (0x2F, true)
        case "]": return (0x30, false)
        case "}": return (0x30, true)
        case "\\": return (0x31, false)
        case "|":  return (0x31, true)
        case ";": return (0x33, false)
        case ":": return (0x33, true)
        case "'": return (0x34, false)
        case "\"": return (0x34, true)
        case "`": return (0x35, false)
        case "~": return (0x35, true)
        case ",": return (0x36, false)
        case "<": return (0x36, true)
        case ".": return (0x37, false)
        case ">": return (0x37, true)
        case "/": return (0x38, false)
        case "?": return (0x38, true)
        default:
            return nil
        }
    }
}
