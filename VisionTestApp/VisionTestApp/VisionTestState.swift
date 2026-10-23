import SwiftUI
import Observation
import os

/// `print` doesn't reach the unified log on visionOS, so events go through Logger to be
/// visible to `iosef log_show` / `log_stream`.
let log = Logger(subsystem: "com.mcp-test.playground.visionapp", category: "VisionTest")

/// Everything the gauntlet records, surfaced as accessible labels so agents can assert on
/// it with `iosef text` / `iosef exists` as well as by screenshot.
@Observable
final class VisionTestState {
    var tapCount = 0
    var lastTap: String? = nil
    var textFieldValue = ""
    var dragOffset: CGSize = .zero
    var dragCount = 0
    var isImmersed = false
    var orbTapCount = 0
    var volumeCubeTapCount = 0
    var volumeCubePosition: SIMD3<Float> = .zero
    var immersiveCubePosition = ImmersiveView.cubeStart

    func tap(_ name: String) {
        tapCount += 1
        lastTap = name
        log.notice("[VisionTest] Button tapped: \(name, privacy: .public) (tap #\(self.tapCount))")
    }

    func tapVolumeCube() {
        volumeCubeTapCount += 1
        log.notice("[VisionTest] Volume cube tapped (tap #\(self.volumeCubeTapCount))")
    }

    func movedVolumeCube(to position: SIMD3<Float>) {
        volumeCubePosition = position
        log.notice("[VisionTest] Volume cube moved to \(position.centimetres, privacy: .public) cm")
    }

    func movedImmersiveCube(to position: SIMD3<Float>) {
        immersiveCubePosition = position
        log.notice("[VisionTest] Immersive cube moved to \(position.centimetres, privacy: .public) cm")
    }

    func tapOrb() {
        orbTapCount += 1
        log.notice("[VisionTest] Orb tapped (tap #\(self.orbTapCount))")
    }
}
