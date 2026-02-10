import Foundation
import CoreGraphics
import ImageIO

/// Captures screenshots of the iOS Simulator window natively.
public enum ScreenCapture {

    /// Captures the simulator window as a JPEG and returns base64-encoded data.
    public static func captureSimulatorWindow(windowID: CGWindowID) throws -> (base64: String, width: Int, height: Int) {
        guard let image = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .nominalResolution]
        ) else {
            throw CaptureError.windowCaptureFailed
        }

        let jpegData = try encodeJPEG(image: image, quality: 0.8)
        let base64 = jpegData.base64EncodedString()

        return (base64: base64, width: image.width, height: image.height)
    }

    /// Finds the simulator window ID by searching CGWindowList.
    public static func findSimulatorWindowID() -> CGWindowID? {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        for window in windowList {
            guard let ownerName = window[kCGWindowOwnerName as String] as? String,
                  ownerName == "Simulator",
                  let layer = window[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let windowID = window[kCGWindowNumber as String] as? CGWindowID
            else { continue }
            return windowID
        }

        return nil
    }

    /// Encodes a CGImage as JPEG data.
    private static func encodeJPEG(image: CGImage, quality: Double) throws -> Data {
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData as CFMutableData,
            "public.jpeg" as CFString,
            1,
            nil
        ) else {
            throw CaptureError.jpegEncodingFailed
        }

        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw CaptureError.jpegEncodingFailed
        }

        return mutableData as Data
    }

    public enum CaptureError: Error, LocalizedError {
        case windowCaptureFailed
        case jpegEncodingFailed
        case simulatorWindowNotFound

        public var errorDescription: String? {
            switch self {
            case .windowCaptureFailed:
                return "Failed to capture simulator window"
            case .jpegEncodingFailed:
                return "Failed to encode image as JPEG"
            case .simulatorWindowNotFound:
                return "Simulator window not found on screen"
            }
        }
    }
}
