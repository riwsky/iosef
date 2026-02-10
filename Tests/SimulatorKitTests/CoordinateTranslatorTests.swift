import Testing
@testable import SimulatorKit
import CoreGraphics

@Suite("CoordinateTranslator Tests")
struct CoordinateTranslatorTests {

    @Test("Identity mapping when content frame equals device size")
    func identityMapping() {
        let translator = CoordinateTranslator(
            contentFrame: CGRect(x: 100, y: 200, width: 393, height: 852),
            deviceSize: CGSize(width: 393, height: 852)
        )
        let point = translator.toScreenCoordinate(iosX: 0, iosY: 0)
        #expect(point.x == 100)
        #expect(point.y == 200)
    }

    @Test("Offset applied correctly")
    func offsetApplied() {
        let translator = CoordinateTranslator(
            contentFrame: CGRect(x: 50, y: 100, width: 393, height: 852),
            deviceSize: CGSize(width: 393, height: 852)
        )
        let point = translator.toScreenCoordinate(iosX: 100, iosY: 200)
        #expect(point.x == 150)
        #expect(point.y == 300)
    }

    @Test("Scale applied when zoomed")
    func scaleApplied() {
        // Content frame is half the device size (50% zoom)
        let translator = CoordinateTranslator(
            contentFrame: CGRect(x: 0, y: 0, width: 196.5, height: 426),
            deviceSize: CGSize(width: 393, height: 852)
        )
        let point = translator.toScreenCoordinate(iosX: 393, iosY: 852)
        #expect(abs(point.x - 196.5) < 0.01)
        #expect(abs(point.y - 426.0) < 0.01)
    }

    @Test("Center point with offset and scale")
    func centerPointWithOffsetAndScale() {
        let translator = CoordinateTranslator(
            contentFrame: CGRect(x: 100, y: 50, width: 200, height: 400),
            deviceSize: CGSize(width: 400, height: 800)
        )
        // scale = 0.5, so iOS point (200, 400) → screen (100 + 200*0.5, 50 + 400*0.5) = (200, 250)
        let point = translator.toScreenCoordinate(iosX: 200, iosY: 400)
        #expect(abs(point.x - 200.0) < 0.01)
        #expect(abs(point.y - 250.0) < 0.01)
    }
}
