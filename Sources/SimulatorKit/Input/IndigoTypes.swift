import Foundation
import IndigoCTypes

// Swift-friendly constants wrapping the C defines from IndigoCTypes.h.
// The actual packed struct types (IndigoMessage, IndigoPayload, IndigoTouch, etc.)
// are imported directly from the IndigoCTypes C module.

enum IndigoEventTypeConst {
    static let button: UInt8 = UInt8(kIndigoEventTypeButton)
    static let touch: UInt8 = UInt8(kIndigoEventTypeTouch)
}

enum IndigoDirection {
    static let down: Int32 = Int32(kIndigoDirectionDown)
    static let up: Int32 = Int32(kIndigoDirectionUp)
}

enum IndigoButtonSourceConst {
    static let applePay: UInt32 = UInt32(kButtonSourceApplePay)
    static let homeButton: UInt32 = UInt32(kButtonSourceHomeButton)
    static let lock: UInt32 = UInt32(kButtonSourceLock)
    static let keyboard: UInt32 = UInt32(kButtonSourceKeyboard)
    static let sideButton: UInt32 = UInt32(kButtonSourceSideButton)
    static let siri: UInt32 = UInt32(kButtonSourceSiri)
}

enum IndigoButtonTargetConst {
    static let hardware: UInt32 = UInt32(kButtonTargetHardware)
    static let keyboard: UInt32 = UInt32(kButtonTargetKeyboard)
}

/// Calculates screen ratio from iOS point coordinates.
/// This matches idb's `screenRatioFromPoint:screenSize:screenScale:`.
func indigoScreenRatio(x: Double, y: Double, screenSize: CGSize, screenScale: Float) -> (xRatio: Double, yRatio: Double) {
    let xRatio = (x * Double(screenScale)) / Double(screenSize.width)
    let yRatio = (y * Double(screenScale)) / Double(screenSize.height)
    return (xRatio, yRatio)
}
