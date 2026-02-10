import Foundation
import CoreGraphics

/// Translates iOS point coordinates to macOS screen coordinates.
///
/// Uses the AXGroup frame (the iOS content area within the Simulator window)
/// and the device logical size to compute a scale factor.
public struct CoordinateTranslator: Sendable {
    /// The macOS screen rect of the iOS content area (from AXGroup frame).
    public let contentFrame: CGRect

    /// The iOS device logical size in points.
    public let deviceSize: CGSize

    public init(contentFrame: CGRect, deviceSize: CGSize) {
        self.contentFrame = contentFrame
        self.deviceSize = deviceSize
    }

    /// Scale factor: how many macOS points per iOS point.
    public var scaleX: CGFloat {
        guard deviceSize.width > 0 else { return 1 }
        return contentFrame.width / deviceSize.width
    }

    public var scaleY: CGFloat {
        guard deviceSize.height > 0 else { return 1 }
        return contentFrame.height / deviceSize.height
    }

    /// Translates an iOS point coordinate to a macOS screen coordinate.
    public func toScreenCoordinate(iosX: CGFloat, iosY: CGFloat) -> CGPoint {
        let screenX = contentFrame.origin.x + iosX * scaleX
        let screenY = contentFrame.origin.y + iosY * scaleY
        return CGPoint(x: screenX, y: screenY)
    }
}
