import Foundation
import CoreGraphics
import IndigoCTypes

/// Sends touch, swipe, and button events to a specific iOS Simulator device
/// via Apple's private IndigoHID mechanism. Does not move the macOS mouse cursor.
public final class IndigoHIDClient: @unchecked Sendable {
    private let device: AnyObject      // SimDevice
    private let client: AnyObject      // SimDeviceLegacyHIDClient
    public let screenSize: CGSize      // pixel dimensions (e.g., 1179x2556)
    public let screenScale: Float      // e.g., 3.0
    private let bridge: PrivateFrameworkBridge

    public init(udid: String) throws {
        self.bridge = PrivateFrameworkBridge.shared
        try bridge.ensureLoaded()

        self.device = try bridge.lookUpDevice(udid: udid)
        self.client = try bridge.createHIDClient(device: device)
        self.screenSize = bridge.screenSize(forDevice: device)
        self.screenScale = bridge.screenScale(forDevice: device)
    }

    // MARK: - Public API

    /// Sends a tap at the given iOS point coordinates.
    public func tap(x: Double, y: Double) {
        let ratio = indigoScreenRatio(x: x, y: y, screenSize: screenSize, screenScale: screenScale)
        let downData = buildTouchMessage(xRatio: ratio.xRatio, yRatio: ratio.yRatio, direction: IndigoDirection.down)
        let upData = buildTouchMessage(xRatio: ratio.xRatio, yRatio: ratio.yRatio, direction: IndigoDirection.up)

        bridge.sendMessage(downData, to: client)
        usleep(30_000)  // 30ms hold
        bridge.sendMessage(upData, to: client)
    }

    /// Sends a long press at the given iOS point coordinates.
    public func longPress(x: Double, y: Double, duration: Double) {
        let ratio = indigoScreenRatio(x: x, y: y, screenSize: screenSize, screenScale: screenScale)
        let downData = buildTouchMessage(xRatio: ratio.xRatio, yRatio: ratio.yRatio, direction: IndigoDirection.down)
        let upData = buildTouchMessage(xRatio: ratio.xRatio, yRatio: ratio.yRatio, direction: IndigoDirection.up)

        bridge.sendMessage(downData, to: client)
        usleep(UInt32(duration * 1_000_000))
        bridge.sendMessage(upData, to: client)
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

        // Touch down at start
        let downData = buildTouchMessage(xRatio: startRatio.xRatio, yRatio: startRatio.yRatio, direction: IndigoDirection.down)
        bridge.sendMessage(downData, to: client)

        // Drag through intermediate points
        let dxRatio = (endRatio.xRatio - startRatio.xRatio) / Double(stepCount)
        let dyRatio = (endRatio.yRatio - startRatio.yRatio) / Double(stepCount)

        for i in 1...stepCount {
            let xr = startRatio.xRatio + dxRatio * Double(i)
            let yr = startRatio.yRatio + dyRatio * Double(i)
            // Drag events use "down" direction (finger still touching)
            let dragData = buildTouchMessage(xRatio: xr, yRatio: yr, direction: IndigoDirection.down)
            bridge.sendMessage(dragData, to: client)
            usleep(stepDelayMicros)
        }

        // Touch up at end
        let upData = buildTouchMessage(xRatio: endRatio.xRatio, yRatio: endRatio.yRatio, direction: IndigoDirection.up)
        bridge.sendMessage(upData, to: client)
    }

    /// Sends a hardware button press (home, lock, side, etc.).
    public func pressButton(source: UInt32, direction: Int32) {
        guard let fn = bridge.messageForButton else { return }
        let msg = fn(Int32(source), direction, Int32(IndigoButtonTargetConst.hardware))
        let size = malloc_size(msg)
        let data = Data(bytes: msg, count: size)
        free(msg)
        bridge.sendMessage(data, to: client)
    }

    // MARK: - Keyboard Input

    /// Types a string by sending per-character HID keyboard events.
    public func typeText(_ text: String) {
        for char in text {
            guard let (keyCode, needsShift) = Self.hidKeyCode(for: char) else { continue }

            if needsShift {
                sendKeyEvent(keyCode: 0xE1, direction: IndigoDirection.down)  // Left Shift down
            }
            sendKeyEvent(keyCode: keyCode, direction: IndigoDirection.down)
            sendKeyEvent(keyCode: keyCode, direction: IndigoDirection.up)
            if needsShift {
                sendKeyEvent(keyCode: 0xE1, direction: IndigoDirection.up)    // Left Shift up
            }

            usleep(10_000)  // 10ms between characters
        }
    }

    /// Sends a single HID keyboard event via IndigoHIDMessageForKeyboardArbitrary.
    private func sendKeyEvent(keyCode: UInt8, direction: Int32) {
        guard let fn = bridge.messageForKeyboardArbitrary else { return }
        let msg = fn(Int32(keyCode), direction)
        let size = malloc_size(msg)
        let data = Data(bytes: msg, count: size)
        free(msg)
        bridge.sendMessage(data, to: client)
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

    // MARK: - Touch Message Construction

    /// Builds a 320-byte touch message with duplicated payload, matching idb's touchMessageWithPayload.
    private func buildTouchMessage(xRatio: Double, yRatio: Double, direction: Int32) -> Data {
        guard let fn = bridge.messageForMouseNSEvent else {
            // Fallback: build manually if function pointer not available
            return buildTouchMessageManual(xRatio: xRatio, yRatio: yRatio, direction: direction)
        }

        // Call IndigoHIDMessageForMouseNSEvent to get a message with direction fields populated
        var point = CGPoint(x: xRatio, y: yRatio)
        let initialMsg = fn(&point, nil, 0x32, direction, false)

        // Override xRatio/yRatio with our calculated values
        initialMsg.pointee.payload.event.touch.xRatio = xRatio
        initialMsg.pointee.payload.event.touch.yRatio = yRatio

        // Build the final 320-byte message with duplicated payload
        let touchPayload = initialMsg.pointee.payload.event.touch
        let result = buildFinalTouchMessage(from: touchPayload)

        free(initialMsg)
        return result
    }

    /// Constructs the final 320-byte touch message with duplicated payload.
    /// Mirrors idb's `+[FBSimulatorIndigoHID touchMessageWithPayload:messageSizeOut:]`.
    private func buildFinalTouchMessage(from touch: IndigoTouch) -> Data {
        let messageSize = MemoryLayout<IndigoMessage>.size + MemoryLayout<IndigoPayload>.size
        let payloadStride = MemoryLayout<IndigoPayload>.size

        // Compute the byte offset of `payload.event` within IndigoMessage
        let payloadOffset = MemoryLayout<IndigoMessage>.offset(of: \IndigoMessage.payload)!
        let eventOffset = payloadOffset + MemoryLayout<IndigoPayload>.offset(of: \IndigoPayload.event)!

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: messageSize, alignment: 4)
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: messageSize)

        let msg = buffer.assumingMemoryBound(to: IndigoMessage.self)

        // Set message header fields
        msg.pointee.innerSize = UInt32(payloadStride)
        msg.pointee.eventType = IndigoEventTypeConst.touch
        msg.pointee.payload.field1 = 0x0000000b
        msg.pointee.payload.timestamp = mach_absolute_time()

        // Copy touch data into the event union via buffer offset
        withUnsafePointer(to: touch) { src in
            buffer.advanced(by: eventOffset)
                .copyMemory(from: src, byteCount: MemoryLayout<IndigoTouch>.size)
        }

        // Duplicate the first payload into the second slot
        let firstPayloadPtr = buffer.advanced(by: payloadOffset)
        let secondPayloadPtr = firstPayloadPtr.advanced(by: payloadStride)
        secondPayloadPtr.copyMemory(from: firstPayloadPtr, byteCount: payloadStride)

        // Adjust the second payload: touch.field1 = 1, touch.field2 = 2
        let secondPayload = secondPayloadPtr.assumingMemoryBound(to: IndigoPayload.self)
        secondPayload.pointee.event.touch.field1 = 0x00000001
        secondPayload.pointee.event.touch.field2 = 0x00000002

        let data = Data(bytes: buffer, count: messageSize)
        buffer.deallocate()
        return data
    }

    /// Manual fallback if IndigoHIDMessageForMouseNSEvent is not available.
    private func buildTouchMessageManual(xRatio: Double, yRatio: Double, direction: Int32) -> Data {
        var touch = IndigoTouch()
        touch.xRatio = xRatio
        touch.yRatio = yRatio
        // Set direction indicators in the fields that MessageForMouseNSEvent would set
        touch.field9 = UInt32(direction)
        touch.field10 = (direction == IndigoDirection.down) ? 1 : 0
        return buildFinalTouchMessage(from: touch)
    }
}
