import Foundation
import CoreGraphics

public enum TouchPathError: Error, LocalizedError, Equatable {
    case unsupportedFingerCount(Int)
    case emptyPath(finger: Int)
    case invalidScale(Double)
    case fingersTooClose(span: Double)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFingerCount(let count):
            return "Expected 1 or 2 finger paths, got \(count)"
        case .emptyPath(let finger):
            return "Finger \(finger) has an empty path; each finger needs at least one point"
        case .invalidScale(let scale):
            return "Scale must be a positive number other than 1 (got \(scale))"
        case .fingersTooClose(let span):
            return "Fingers would be only \(Int(span))pt apart, too close to register as two contacts. "
                + "Use a larger radius or a scale closer to 1."
        }
    }
}

/// Finger paths for multi-touch gestures, in iOS points. Pure geometry: nothing here talks
/// to a simulator.
public enum TouchPaths {

    /// Below this the two contacts are liable to be merged into one.
    static let minimumFingerSpan = 20.0

    /// Two fingers on a horizontal line through `center`, moving symmetrically so the
    /// distance between them changes by `scale` (>1 spreads apart, <1 pinches together).
    /// `radius` is how far each finger gets from the center at the gesture's widest.
    public static func pinch(center: CGPoint, scale: Double, radius: Double) throws -> [[CGPoint]] {
        guard scale > 0, scale != 1, scale.isFinite else { throw TouchPathError.invalidScale(scale) }

        let startRadius = scale > 1 ? radius / scale : radius
        let endRadius = startRadius * scale
        let narrowest = 2 * min(startRadius, endRadius)
        guard narrowest >= minimumFingerSpan else { throw TouchPathError.fingersTooClose(span: narrowest) }

        return [-1.0, 1.0].map { side in
            [startRadius, endRadius].map { CGPoint(x: center.x + side * $0, y: center.y) }
        }
    }

    /// Two fingers on opposite sides of `center`, `radius` away, sweeping `degrees` around
    /// it. Positive is clockwise on screen, matching `RotateGesture`.
    public static func rotate(center: CGPoint, degrees: Double, radius: Double) throws -> [[CGPoint]] {
        guard 2 * radius >= minimumFingerSpan else { throw TouchPathError.fingersTooClose(span: 2 * radius) }

        // An arc as a polyline: a waypoint at least every 5 degrees.
        let segments = max(1, Int((abs(degrees) / 5).rounded(.up)))
        return [0.0, Double.pi].map { offset in
            (0...segments).map { i in
                // y grows downward on screen, so increasing the angle sweeps clockwise.
                let angle = offset + (degrees * .pi / 180) * Double(i) / Double(segments)
                return CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            }
        }
    }

    /// Resamples `path` into `steps + 1` points evenly spaced along its length, so fingers
    /// with different numbers of waypoints can still advance in lockstep.
    public static func resample(_ path: [CGPoint], steps: Int) -> [CGPoint] {
        guard let first = path.first else { return [] }
        let steps = max(1, steps)

        var cumulative = [0.0]
        for (a, b) in zip(path, path.dropFirst()) {
            cumulative.append(cumulative.last! + hypot(b.x - a.x, b.y - a.y))
        }
        let total = cumulative.last!
        guard total > 0 else { return Array(repeating: first, count: steps + 1) }

        var segment = 0
        return (0...steps).map { i in
            let target = total * Double(i) / Double(steps)
            while segment < path.count - 2, cumulative[segment + 1] < target { segment += 1 }
            let length = cumulative[segment + 1] - cumulative[segment]
            let t = length > 0 ? (target - cumulative[segment]) / length : 0
            let a = path[segment], b = path[segment + 1]
            return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
    }
}
