import Foundation
import CoreGraphics
import IndigoCTypes

/// Delivers HID events via Apple's private IndigoHID mechanism: packed Indigo messages
/// handed to a `SimDeviceLegacyHIDClient`.
///
/// This is the only transport on toolchains before CoreSimulator 1155.4. From there on the
/// guest suppresses the legacy touch and keyboard services in favour of `dtuhidd` (see
/// `DTUHIDTransport`), so it serves as the fallback, and as the path for hardware buttons,
/// which stay functional over Indigo.
final class IndigoHIDTransport: HIDTransport, @unchecked Sendable {
    let name = "indigo"

    /// Always true: a dead HID session is replaced from inside `send(_:)`.
    var isValid: Bool { true }

    private let bridge: PrivateFrameworkBridge
    private let device: AnyObject      // SimDevice

    /// SimDeviceLegacyHIDClient. Mutable because a simulator reboot tears down the
    /// sim-side HID endpoint, leaving this object permanently unable to deliver;
    /// `send(_:)` swaps in a fresh one when that happens.
    private var client: AnyObject
    private let lock = NSLock()
    private var lastReconnectAttempt: ContinuousClock.Instant?

    /// Minimum spacing between reconnect attempts. A device that is shut down (rather
    /// than rebooted) fails every send, and recreating the client costs ~100ms, so a
    /// 20-step swipe would otherwise pay for 20 doomed reconnects.
    private static let reconnectCooldown: Duration = .seconds(1)

    init(bridge: PrivateFrameworkBridge, device: AnyObject) throws {
        self.bridge = bridge
        self.device = device
        self.client = try bridge.createHIDClient(device: device)
    }

    deinit {
        // ARC drops the strong ref to `client` (SimDeviceLegacyHIDClient) here, triggering
        // its ObjC dealloc which closes Mach ports and XPC connections.
        logDiagnostic("deinit — releasing HID client", prefix: "IndigoHIDTransport")
    }

    // MARK: - HIDTransport

    func sendTouch(xRatio: Double, yRatio: Double, phase: HIDTouchPhase) {
        // Indigo has no "moved" state: a drag is a stream of downs at new positions.
        let direction = phase == .end ? IndigoDirection.up : IndigoDirection.down
        send(buildTouchMessage(xRatio: xRatio, yRatio: yRatio, direction: direction))
    }

    func sendKey(usage: UInt8, down: Bool) {
        guard let fn = bridge.messageForKeyboardArbitrary else { return }
        sendIndigoMessage(fn(Int32(usage), down ? IndigoDirection.down : IndigoDirection.up))
    }

    /// Nothing to wait for: `send(_:)` already blocks on the delivery callback.
    func flush() {}

    func sendButton(source: UInt32, direction: Int32) {
        guard let fn = bridge.messageForButton else { return }
        sendIndigoMessage(fn(Int32(source), direction, Int32(IndigoButtonTargetConst.hardware)))
    }

    // MARK: - Message delivery

    /// Delivers one Indigo message, reconnecting once if the simulator tore down the
    /// HID endpoint underneath us (e.g. `simctl shutdown` + `boot` during a long-lived
    /// MCP session). Without this, every later event posts into a dead Mach port and
    /// silently does nothing, forever.
    ///
    /// The completion handler is the only usable staleness signal. It reports
    /// "Mach port invalid, device disconnected" as soon as the sim-side endpoint is
    /// gone, whereas `SimDevice.bootGeneration` keeps reading the pre-reboot value
    /// in this process and `-[SimDeviceLegacyHIDClient resetHIDSession]` does not
    /// revive the dead client. Building a new client against the same SimDevice does.
    private func send(_ data: Data) {
        let current = lock.withLock { client }
        if bridge.sendMessage(data, to: current) == .delivered { return }

        guard let reconnected = reconnect(replacing: current) else { return }

        let result = bridge.sendMessage(data, to: reconnected)
        if result != .delivered {
            logDiagnostic("send failed after reconnect: \(result)", prefix: "IndigoHIDTransport")
        }
    }

    /// Replaces the underlying HID client. Returns the client to retry with, or nil if
    /// the retry should be skipped (reconnect failed, or one was attempted too recently).
    private func reconnect(replacing stale: AnyObject) -> AnyObject? {
        lock.lock()
        defer { lock.unlock() }

        // Another thread already reconnected — retry on theirs rather than churning.
        if client !== stale { return client }

        let now = ContinuousClock.now
        if let last = lastReconnectAttempt, now - last < Self.reconnectCooldown { return nil }
        lastReconnectAttempt = now

        do {
            client = try bridge.createHIDClient(device: device)
            logDiagnostic("HID session was stale — reconnected", prefix: "IndigoHIDTransport")
            return client
        } catch {
            logDiagnostic("HID session was stale — reconnect failed: \(error)", prefix: "IndigoHIDTransport")
            return nil
        }
    }

    /// Converts a malloc'd IndigoMessage pointer to Data, frees the pointer, and sends it.
    private func sendIndigoMessage(_ msg: UnsafeMutablePointer<IndigoMessage>) {
        let data = Data(bytes: msg, count: malloc_size(msg))
        free(msg)
        send(data)
    }

    // MARK: - Touch Message Construction

    /// Builds a 320-byte touch message with duplicated payload, matching idb's touchMessageWithPayload.
    private func buildTouchMessage(xRatio: Double, yRatio: Double, direction: Int32) -> Data {
        guard let fn = bridge.messageForMouseNSEvent else {
            // Fallback: build manually if function pointer not available
            return buildTouchMessageManual(xRatio: xRatio, yRatio: yRatio, direction: direction)
        }

        // Call IndigoHIDMessageForMouseNSEvent to get a message with direction fields populated
        // The point is already a ratio, so a unit size makes the builder's own
        // point / size normalization the identity. Edge 0 = contact not from a screen edge.
        var point = CGPoint(x: xRatio, y: yRatio)
        let initialMsg = fn(&point, nil, 0x32, UInt(direction), CGSize(width: 1, height: 1), 0)

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
