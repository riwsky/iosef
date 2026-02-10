import Foundation
import CoreGraphics

/// Injects tap and long-press events into the iOS Simulator using CGEvents.
public enum TouchInjector {

    /// Sends a mouse event at the given absolute screen coordinates.
    private static func sendMouseEvent(
        x: CGFloat, y: CGFloat,
        eventType: CGEventType,
        button: CGMouseButton = .left
    ) {
        let point = CGPoint(x: x, y: y)
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: eventType,
            mouseCursorPosition: point,
            mouseButton: button
        ) else { return }
        event.post(tap: .cghidEventTap)
    }

    /// Sends a tap at the given macOS screen coordinates.
    ///
    /// Sequence: MouseMoved → MouseDown (50ms hold) → MouseUp
    public static func tap(screenX: CGFloat, screenY: CGFloat) {
        sendMouseEvent(x: screenX, y: screenY, eventType: .mouseMoved)
        Thread.sleep(forTimeInterval: 0.01)

        sendMouseEvent(x: screenX, y: screenY, eventType: .leftMouseDown)
        Thread.sleep(forTimeInterval: 0.05)

        sendMouseEvent(x: screenX, y: screenY, eventType: .leftMouseUp)
    }

    /// Sends a long press at the given macOS screen coordinates.
    ///
    /// Sequence: MouseMoved → MouseDown → wait(duration) → MouseUp
    public static func longPress(screenX: CGFloat, screenY: CGFloat, durationSeconds: Double) {
        sendMouseEvent(x: screenX, y: screenY, eventType: .mouseMoved)
        Thread.sleep(forTimeInterval: 0.01)

        sendMouseEvent(x: screenX, y: screenY, eventType: .leftMouseDown)
        Thread.sleep(forTimeInterval: durationSeconds)

        sendMouseEvent(x: screenX, y: screenY, eventType: .leftMouseUp)
    }
}
