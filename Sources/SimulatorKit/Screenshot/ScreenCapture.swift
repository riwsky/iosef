import Foundation
import CoreGraphics
import ImageIO

/// Captures screenshots of the iOS Simulator via `xcrun simctl io`.
public enum ScreenCapture {

    private static func log(_ message: String) {
        fputs("[ScreenCapture] \(message)\n", stderr)
    }

    /// Captures the simulator screen as a JPEG via simctl and returns base64-encoded data.
    /// The image is downscaled from device pixels to iOS points using `screenScale`
    /// so that screenshot coordinates align with `ui_tap` and `ui_describe_all`.
    public static func captureSimulator(udid: String, screenScale: Float, timeout: Duration = .seconds(5)) throws -> (base64: String, width: Int, height: Int) {
        let tempPath = "/tmp/ios-sim-mcp-\(UUID().uuidString).png"
        defer { try? FileManager.default.removeItem(atPath: tempPath) }

        log("Starting simctl screenshot for \(udid) -> \(tempPath)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "io", udid, "screenshot", "--type=png", "--", tempPath]
        process.standardOutput = FileHandle.nullDevice
        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            semaphore.signal()
        }

        try process.run()
        log("simctl process launched (pid \(process.processIdentifier)), waiting...")

        let timeoutSeconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        let waitResult = semaphore.wait(timeout: .now() + timeoutSeconds)

        if waitResult == .timedOut {
            process.terminate()
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
            }
            throw TimeoutError.processTimedOut(command: "xcrun simctl io screenshot", timeoutSeconds: timeoutSeconds)
        }

        let simctlStderr = String(data: stderrPipe.fileHandleForReading.availableData, encoding: .utf8) ?? ""
        log("simctl exited with status \(process.terminationStatus)" +
            (simctlStderr.isEmpty ? "" : ", stderr: \(simctlStderr)"))

        guard process.terminationStatus == 0 else {
            throw CaptureError.simctlFailed(exitCode: process.terminationStatus)
        }

        let pngData = try Data(contentsOf: URL(fileURLWithPath: tempPath))
        log("PNG loaded: \(pngData.count) bytes")

        // Load PNG as CGImage for dimensions + JPEG re-encoding
        guard let imageSource = CGImageSourceCreateWithData(pngData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw CaptureError.jpegEncodingFailed
        }

        // Downscale from device pixels to iOS points
        let targetWidth = Int(round(Double(cgImage.width) / Double(screenScale)))
        let targetHeight = Int(round(Double(cgImage.height) / Double(screenScale)))
        log("CGImage: \(cgImage.width)x\(cgImage.height), resizing to \(targetWidth)x\(targetHeight) (scale \(screenScale))...")
        guard let resized = resizeImage(cgImage, width: targetWidth, height: targetHeight) else {
            throw CaptureError.jpegEncodingFailed
        }

        let jpegData = try encodeJPEG(image: resized, quality: 0.8)
        log("JPEG encoded: \(jpegData.count) bytes, encoding base64...")
        let base64 = jpegData.base64EncodedString()
        log("Base64 encoded: \(base64.count) chars, done")

        return (base64: base64, width: targetWidth, height: targetHeight)
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
        case simctlFailed(exitCode: Int32)
        case jpegEncodingFailed

        public var errorDescription: String? {
            switch self {
            case .simctlFailed(let code):
                return "simctl screenshot failed with exit code \(code)"
            case .jpegEncodingFailed:
                return "Failed to encode image as JPEG"
            }
        }
    }
}
