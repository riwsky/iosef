import Foundation
import CoreGraphics

/// Injects swipe/drag gestures into the iOS Simulator using CGEvents.
public enum SwipeInjector {

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

    /// Sends a swipe gesture from start to end coordinates.
    ///
    /// - Parameters:
    ///   - startX/startY: Starting macOS screen coordinates
    ///   - endX/endY: Ending macOS screen coordinates
    ///   - steps: Number of intermediate drag points (default 20)
    ///   - durationSeconds: Optional total swipe duration
    public static func swipe(
        startX: CGFloat, startY: CGFloat,
        endX: CGFloat, endY: CGFloat,
        steps: Int = 20,
        durationSeconds: Double? = nil
    ) {
        let dx = (endX - startX) / CGFloat(steps)
        let dy = (endY - startY) / CGFloat(steps)
        let stepDelay = durationSeconds.map { $0 / Double(steps) } ?? 0.01

        // Move to start position
        sendMouseEvent(x: startX, y: startY, eventType: .mouseMoved)
        Thread.sleep(forTimeInterval: 0.02)

        // Mouse down at start
        sendMouseEvent(x: startX, y: startY, eventType: .leftMouseDown)
        Thread.sleep(forTimeInterval: 0.02)

        // Drag through intermediate points
        for i in 1...steps {
            let x = startX + dx * CGFloat(i)
            let y = startY + dy * CGFloat(i)
            sendMouseEvent(x: x, y: y, eventType: .leftMouseDragged)
            Thread.sleep(forTimeInterval: stepDelay)
        }

        // Mouse up at end
        sendMouseEvent(x: endX, y: endY, eventType: .leftMouseUp)
    }
}
