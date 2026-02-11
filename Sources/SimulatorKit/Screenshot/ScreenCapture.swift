import Foundation
import CoreGraphics
import ImageIO

/// Captures screenshots of the iOS Simulator via simctl.
public enum ScreenCapture {

    /// Captures the simulator screen as a JPEG and returns base64-encoded data.
    /// Uses `xcrun simctl io <udid> screenshot` which captures the simulator framebuffer
    /// directly — works even when the Simulator window is hidden or minimized.
    public static func captureSimulator(udid: String) throws -> (base64: String, width: Int, height: Int) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sim_screenshot_\(ProcessInfo.processInfo.processIdentifier).jpg")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "io", udid, "screenshot", "--type=jpeg", "--", tempURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw CaptureError.windowCaptureFailed
        }

        let jpegData = try Data(contentsOf: tempURL)
        let base64 = jpegData.base64EncodedString()

        // Read dimensions from the JPEG data
        var width = 0
        var height = 0
        if let source = CGImageSourceCreateWithData(jpegData as CFData, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
            width = properties[kCGImagePropertyPixelWidth as String] as? Int ?? 0
            height = properties[kCGImagePropertyPixelHeight as String] as? Int ?? 0
        }

        return (base64: base64, width: width, height: height)
    }

    public enum CaptureError: Error, LocalizedError {
        case windowCaptureFailed
        case jpegEncodingFailed

        public var errorDescription: String? {
            switch self {
            case .windowCaptureFailed:
                return "Failed to capture simulator screenshot"
            case .jpegEncodingFailed:
                return "Failed to encode image as JPEG"
            }
        }
    }
}
