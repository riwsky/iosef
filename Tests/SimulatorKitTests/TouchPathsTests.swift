import CoreGraphics
import Foundation
import Testing
@testable import SimulatorKit

@Suite("TouchPaths Tests")
struct TouchPathsTests {
    let center = CGPoint(x: 200, y: 400)

    private func span(_ fingers: [[CGPoint]], at index: Int) -> Double {
        hypot(fingers[1][index].x - fingers[0][index].x, fingers[1][index].y - fingers[0][index].y)
    }

    @Test("Pinch changes the finger span by the scale", arguments: [2.0, 4.0, 0.5, 0.25])
    func pinchScalesSpan(scale: Double) throws {
        let fingers = try TouchPaths.pinch(center: center, scale: scale, radius: 100)
        #expect(fingers.count == 2)
        let start = span(fingers, at: 0), end = span(fingers, at: 1)
        #expect(abs(end / start - scale) < 1e-9)
        // The widest the fingers get is the requested radius, whichever direction we go.
        #expect(abs(max(start, end) - 200) < 1e-9)
    }

    @Test("Pinch keeps the fingers symmetric about the center")
    func pinchIsSymmetric() throws {
        let fingers = try TouchPaths.pinch(center: center, scale: 2, radius: 80)
        for i in 0..<2 {
            #expect(abs((fingers[0][i].x + fingers[1][i].x) / 2 - center.x) < 1e-9)
            #expect(fingers[0][i].y == center.y && fingers[1][i].y == center.y)
        }
    }

    @Test("Pinch rejects scales that aren't a gesture", arguments: [1.0, 0.0, -2.0, Double.infinity, Double.nan])
    func pinchRejectsBadScale(scale: Double) {
        #expect(throws: TouchPathError.self) { try TouchPaths.pinch(center: center, scale: scale, radius: 100) }
    }

    @Test("Pinch refuses to bring the fingers close enough to merge")
    func pinchRejectsTinySpan() {
        #expect(throws: TouchPathError.fingersTooClose(span: 10)) {
            try TouchPaths.pinch(center: center, scale: 20, radius: 100)
        }
    }

    @Test("Rotate sweeps both fingers by the angle at a constant radius", arguments: [90.0, -45.0, 10.0, 270.0])
    func rotateSweepsAngle(degrees: Double) throws {
        let fingers = try TouchPaths.rotate(center: center, degrees: degrees, radius: 80)
        for finger in fingers {
            for point in finger {
                #expect(abs(hypot(point.x - center.x, point.y - center.y) - 80) < 1e-9)
            }
            let start = atan2(finger.first!.y - center.y, finger.first!.x - center.x)
            let end = atan2(finger.last!.y - center.y, finger.last!.x - center.x)
            var swept = (end - start) * 180 / .pi
            // atan2 wraps; compare modulo a full turn.
            swept = (swept - degrees).truncatingRemainder(dividingBy: 360)
            #expect(abs(swept) < 1e-6 || abs(abs(swept) - 360) < 1e-6)
        }
        // Opposite sides of the center throughout.
        for i in fingers[0].indices {
            #expect(abs((fingers[0][i].x + fingers[1][i].x) / 2 - center.x) < 1e-9)
            #expect(abs((fingers[0][i].y + fingers[1][i].y) / 2 - center.y) < 1e-9)
        }
    }

    @Test("Positive rotation is clockwise on screen (y grows downward)")
    func rotateDirection() throws {
        let fingers = try TouchPaths.rotate(center: center, degrees: 90, radius: 80)
        // The finger starting to the right of center should end up below it.
        #expect(abs(fingers[0].last!.x - center.x) < 1e-9)
        #expect(fingers[0].last!.y > center.y)
    }

    @Test("Resample returns steps + 1 points, pinned to the path's ends")
    func resampleEndpoints() {
        let path = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 30)]
        let sampled = TouchPaths.resample(path, steps: 8)
        #expect(sampled.count == 9)
        #expect(sampled.first == path.first && sampled.last == path.last)
    }

    @Test("Resample spaces points evenly along the length, not per segment")
    func resampleIsByArcLength() {
        // Segments of length 10 and 30: the halfway point lies 10 into the second segment.
        let path = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 30)]
        let sampled = TouchPaths.resample(path, steps: 4)
        #expect(abs(sampled[2].x - 10) < 1e-9 && abs(sampled[2].y - 10) < 1e-9)
        for (a, b) in zip(sampled, sampled.dropFirst()) {
            #expect(abs(hypot(b.x - a.x, b.y - a.y) - 10) < 1e-9)
        }
    }

    @Test("Resample holds still for a single point or a zero-length path")
    func resampleDegenerate() {
        let point = CGPoint(x: 5, y: 5)
        #expect(TouchPaths.resample([point], steps: 3) == Array(repeating: point, count: 4))
        #expect(TouchPaths.resample([point, point], steps: 3) == Array(repeating: point, count: 4))
        #expect(TouchPaths.resample([], steps: 3).isEmpty)
    }
}
