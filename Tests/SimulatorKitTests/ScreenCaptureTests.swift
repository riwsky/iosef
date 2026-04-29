import Testing
import Foundation
import ImageIO
@testable import SimulatorKit

@Suite("ScreenCapture Tests", .tags(.requiresSimulator))
struct ScreenCaptureTests {

    static func bootedUDID() throws -> String {
        try SimCtlClient.getBootedDevice().udid
    }

    @Test("captureToFile output dimensions match captureSimulator point dimensions")
    func captureToFileMatchesPointSpace() throws {
        let udid = try Self.bootedUDID()

        let bridge = PrivateFrameworkBridge.shared
        try bridge.ensureLoaded()
        let device = try bridge.lookUpDevice(udid: udid)
        let screenScale = bridge.screenScale(forDevice: device)

        let pointSpace = try ScreenCapture.captureSimulator(udid: udid, screenScale: screenScale)

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("iosef-capturetofile-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmp) }

        try ScreenCapture.captureToFile(udid: udid, outputPath: tmp.path, format: "png")

        guard let source = CGImageSourceCreateWithURL(tmp as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            Issue.record("Failed to decode captureToFile output at \(tmp.path)")
            return
        }

        #expect(image.width == pointSpace.width,
                "captureToFile width \(image.width) != captureSimulator point width \(pointSpace.width)")
        #expect(image.height == pointSpace.height,
                "captureToFile height \(image.height) != captureSimulator point height \(pointSpace.height)")
    }
}
