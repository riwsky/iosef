import Foundation
import CoreGraphics
import ImageIO

/// Captures screenshots of the iOS Simulator.
/// - `captureSimulator`: device framebuffer via simctl pipe → downscale to iOS points (coordinate-aligned)
/// - `captureToFile`: fast window capture via CGWindowListCreateImage (no coordinate alignment needed)
public enum ScreenCapture {

    private static func log(_ message: String) {
        fputs("[ScreenCapture] \(message)\n", stderr)
    }

    /// Captures the simulator screen as a JPEG and returns base64-encoded data.
    /// Uses simctl to get exact device framebuffer pixels, then downscales to iOS point
    /// dimensions so coordinates align with `ui_tap` and `ui_describe_all`.
    public static func captureSimulator(udid: String, screenScale: Float, timeout: Duration = .seconds(5)) throws -> (base64: String, width: Int, height: Int) {
        log("Starting framebuffer capture for \(udid)")

        let pngData = try captureFramebuffer(udid: udid)
        guard let provider = CGDataProvider(data: pngData as CFData),
              let cgImage = CGImage(pngDataProviderSource: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw CaptureError.jpegEncodingFailed
        }
        log("Framebuffer: \(cgImage.width)x\(cgImage.height)")

        // Downscale from device pixels to iOS points
        let targetWidth = Int(round(Double(cgImage.width) / Double(screenScale)))
        let targetHeight = Int(round(Double(cgImage.height) / Double(screenScale)))
        log("Resizing to \(targetWidth)x\(targetHeight) (scale \(screenScale))")

        guard let resized = resizeImage(cgImage, width: targetWidth, height: targetHeight) else {
            throw CaptureError.jpegEncodingFailed
        }

        let jpegData = try encodeJPEG(image: resized, quality: 0.8)
        log("JPEG encoded: \(jpegData.count) bytes")
        let base64 = jpegData.base64EncodedString()

        return (base64: base64, width: targetWidth, height: targetHeight)
    }

    /// Captures a screenshot and saves it to a file.
    /// Uses CGWindowListCreateImage for fast capture (no coordinate alignment needed).
    public static func captureToFile(udid: String, outputPath: String, format: String = "png") throws {
        log("Starting screenshot to file for \(udid)")

        let bridge = PrivateFrameworkBridge.shared
        let device = try bridge.lookUpDevice(udid: udid)
        let deviceName = (device as AnyObject).value(forKey: "name") as? String ?? ""

        let cgImage = try captureSimulatorWindow(deviceName: deviceName)
        log("Window captured: \(cgImage.width)x\(cgImage.height)")

        let url = URL(fileURLWithPath: outputPath)
        let uti = utiForFormat(format)

        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData as CFMutableData,
            uti as CFString,
            1,
            nil
        ) else {
            throw CaptureError.jpegEncodingFailed
        }

        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CaptureError.jpegEncodingFailed
        }

        try (mutableData as Data).write(to: url)
        log("Screenshot saved to \(outputPath) (\(mutableData.length) bytes)")
    }

    // MARK: - Framebuffer Capture (simctl pipe)

    /// Captures the device framebuffer via `simctl io screenshot` piped to stdout.
    /// Returns raw PNG data at device pixel resolution.
    private static func captureFramebuffer(udid: String) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "io", udid, "screenshot", "--type=png", "-"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0, !data.isEmpty else {
            throw CaptureError.framebufferCaptureFailed(
                "simctl screenshot exited with status \(process.terminationStatus)")
        }

        return data
    }

    // MARK: - Window Capture (CGWindowListCreateImage)

    /// Captures the Simulator window for the given device via CGWindowListCreateImage.
    private static func captureSimulatorWindow(deviceName: String) throws -> CGImage {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            throw CaptureError.noSimulatorWindow(deviceName)
        }

        for window in windowList {
            guard let ownerName = window[kCGWindowOwnerName as String] as? String,
                  ownerName == "Simulator",
                  let windowName = window[kCGWindowName as String] as? String,
                  windowName.contains(deviceName),
                  let windowID = window[kCGWindowNumber as String] as? CGWindowID,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  layer == 0 else {
                continue
            }

            log("Found window: '\(windowName)' (ID: \(windowID))")

            guard let image = CGWindowListCreateImage(
                .null,
                .optionIncludingWindow,
                windowID,
                [.boundsIgnoreFraming, .bestResolution]
            ) else {
                throw CaptureError.windowCaptureFailed(
                    "CGWindowListCreateImage returned nil. Grant Screen Recording permission in System Settings > Privacy & Security.")
            }

            return image
        }

        throw CaptureError.noSimulatorWindow(deviceName)
    }

    // MARK: - Helpers

    private static func utiForFormat(_ format: String) -> String {
        switch format.lowercased() {
        case "jpeg", "jpg": return "public.jpeg"
        case "tiff", "tif": return "public.tiff"
        case "bmp": return "com.microsoft.bmp"
        case "gif": return "com.compuserve.gif"
        default: return "public.png"
        }
    }

    /// Resizes a CGImage to the given dimensions using high-quality interpolation.
    private static func resizeImage(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
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
        case jpegEncodingFailed
        case noSimulatorWindow(String)
        case windowCaptureFailed(String)
        case framebufferCaptureFailed(String)

        public var errorDescription: String? {
            switch self {
            case .jpegEncodingFailed:
                return "Failed to encode image"
            case .noSimulatorWindow(let name):
                return "No Simulator window found for device '\(name)'. Is the Simulator running and visible?"
            case .windowCaptureFailed(let reason):
                return "Window capture failed: \(reason)"
            case .framebufferCaptureFailed(let reason):
                return "Framebuffer capture failed: \(reason)"
            }
        }
    }
}
