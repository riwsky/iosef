import Foundation
import CoreGraphics
import ImageIO
import CoreImage
import IOSurface

/// Captures screenshots of the iOS Simulator.
/// - `captureSimulator`: IOSurface framebuffer → downscale to iOS points (coordinate-aligned)
/// - `captureToFile`: fast window capture via CGWindowListCreateImage (no coordinate alignment needed)
public enum ScreenCapture {

    private static func log(_ message: String) {
        guard verboseLogging else { return }
        fputs("[ScreenCapture] \(message)\n", stderr)
    }

    // MARK: - Cached simctl path

    /// Resolved path to `simctl` binary, cached after first lookup.
    /// Avoids ~5-10ms `xcrun` overhead on every call.
    private static let resolvedSimctlPath: String = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["-f", "simctl"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus == 0,
           let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            return path
        }
        // Fallback: use xcrun at call time
        return ""
    }()

    // MARK: - Shared CIContext

    /// Reusable CIContext for GPU-accelerated image processing.
    private static let ciContext: CIContext = {
        // Use default (GPU) context for best performance
        CIContext(options: [.useSoftwareRenderer: false])
    }()

    /// Captures the simulator screen as a JPEG and returns base64-encoded data.
    /// Uses direct IOSurface access for speed (~3ms vs ~200ms simctl), falling back
    /// to simctl pipe if IOSurface is unavailable. Downscales to iOS point dimensions
    /// so coordinates align with `ui_tap` and `ui_describe_all`.
    public static func captureSimulator(udid: String, screenScale: Float, timeout: Duration = .seconds(5)) throws -> (base64: String, width: Int, height: Int) {
        let t0 = CFAbsoluteTimeGetCurrent()

        let bridge = PrivateFrameworkBridge.shared
        let device = try bridge.lookUpDevice(udid: udid)

        // Compute target dimensions
        let scale = Double(screenScale)

        // Try IOSurface fast path first
        var cgImage: CGImage?
        do {
            let result = try bridge.captureFramebufferIOSurface(device: device)
            let t1 = CFAbsoluteTimeGetCurrent()
            log("IOSurface capture: \(Int((t1 - t0) * 1000))ms (\(result.width)x\(result.height))")

            // If we got back an IOSurface-backed CGImage, use CIImage(ioSurface:) for zero-copy
            // Otherwise fall through to CGImage path
            cgImage = result
        } catch {
            let t1 = CFAbsoluteTimeGetCurrent()
            log("IOSurface failed (\(Int((t1 - t0) * 1000))ms): \(error.localizedDescription)")
        }

        // Simctl fallback
        if cgImage == nil {
            let tSimctl0 = CFAbsoluteTimeGetCurrent()
            let imageData = try captureFramebufferSimctl(udid: udid)
            let tSimctl1 = CFAbsoluteTimeGetCurrent()
            log("simctl capture: \(Int((tSimctl1 - tSimctl0) * 1000))ms (\(imageData.count) bytes)")

            // Decode with CGImageSource (format-agnostic: handles PNG, TIFF, etc.)
            guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
                  let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw CaptureError.framebufferCaptureFailed("Failed to decode simctl image data")
            }
            let tDecode = CFAbsoluteTimeGetCurrent()
            log("decode: \(Int((tDecode - tSimctl1) * 1000))ms (\(decoded.width)x\(decoded.height))")
            cgImage = decoded
        }

        guard let sourceImage = cgImage else {
            throw CaptureError.framebufferCaptureFailed("No image captured")
        }

        // Downscale from device pixels to iOS points + encode JPEG using CIContext
        let targetWidth = Int(round(Double(sourceImage.width) / scale))
        let targetHeight = Int(round(Double(sourceImage.height) / scale))

        let tResize0 = CFAbsoluteTimeGetCurrent()

        let ciImage = CIImage(cgImage: sourceImage)
        let scaleX = CGFloat(targetWidth) / CGFloat(sourceImage.width)
        let scaleY = CGFloat(targetHeight) / CGFloat(sourceImage.height)
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        let tResize1 = CFAbsoluteTimeGetCurrent()

        // Encode directly to JPEG from CIImage (skip intermediate CGImage)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let jpegData = ciContext.jpegRepresentation(
            of: scaled,
            colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.8]
        ) else {
            throw CaptureError.jpegEncodingFailed
        }

        let tEncode = CFAbsoluteTimeGetCurrent()
        log("resize: \(Int((tResize1 - tResize0) * 1000))ms, jpeg: \(Int((tEncode - tResize1) * 1000))ms (\(jpegData.count) bytes)")

        let base64 = jpegData.base64EncodedString()
        let tTotal = CFAbsoluteTimeGetCurrent()
        log("total: \(Int((tTotal - t0) * 1000))ms (base64 \(base64.count) chars)")

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

    // MARK: - Framebuffer Capture (simctl pipe fallback)

    /// Captures the device framebuffer via `simctl io screenshot` piped to stdout.
    /// Uses TIFF format for faster encode (no deflate compression) and direct simctl path to skip xcrun.
    private static func captureFramebufferSimctl(udid: String) throws -> Data {
        let process = Process()

        // Use cached direct simctl path to avoid xcrun overhead (~5-10ms)
        if !resolvedSimctlPath.isEmpty {
            process.executableURL = URL(fileURLWithPath: resolvedSimctlPath)
            process.arguments = ["io", udid, "screenshot", "--type=tiff", "-"]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["simctl", "io", udid, "screenshot", "--type=tiff", "-"]
        }

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
