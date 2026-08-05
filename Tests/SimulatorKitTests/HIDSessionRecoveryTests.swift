import Testing
import Foundation
@testable import SimulatorKit

/// Regression coverage for issue #8: a long-lived `IndigoHIDClient` used to post into a
/// dead Mach port after the simulator rebooted, so every later tap/swipe silently did
/// nothing while still reporting success.
///
/// Opt-in, because it reboots a simulator (~40s) — too disruptive for a plain
/// `swift test`. Run with:
///
///     IOSEF_REBOOT_TESTS=1 swift test --filter HIDSessionRecoveryTests
///
/// It reboots the first booted device; set `IOSEF_REBOOT_TEST_UDID` to pick a specific
/// one when several simulators are running.
@Suite("HID session recovery", .tags(.requiresSimulator), .serialized)
struct HIDSessionRecoveryTests {

    static let isEnabled = ProcessInfo.processInfo.environment["IOSEF_REBOOT_TESTS"] == "1"

    @Test("Cached client still drives the simulator after a reboot", .enabled(if: isEnabled))
    func clientRecoversAfterReboot() async throws {
        let udid = try ProcessInfo.processInfo.environment["IOSEF_REBOOT_TEST_UDID"]
            ?? SimCtlClient.getBootedDevice().udid
        let client = try IndigoHIDClient(udid: udid)

        try await launchSettings(udid: udid)
        #expect(try await swipeChangesScreen(client, udid: udid),
                "baseline: swiping should scroll Settings before the reboot")

        try await reboot(udid: udid)
        try await launchSettings(udid: udid)

        // The same client instance, across a boot that tore down the HID endpoint.
        #expect(try await swipeChangesScreen(client, udid: udid),
                "the cached client should reconnect and keep delivering after a reboot")
    }

    // MARK: - Helpers

    /// Settings is a long scrollable list on every device, which makes a swipe a
    /// content-agnostic oracle: if HID events land, the framebuffer changes.
    private func launchSettings(udid: String) async throws {
        let bridge = PrivateFrameworkBridge.shared
        try bridge.ensureLoaded()
        let device = try bridge.lookUpDevice(udid: udid)
        _ = try bridge.launchApp(device: device, bundleID: "com.apple.Preferences", terminateExisting: true)
        try await Task.sleep(for: .seconds(3))
    }

    private func swipeChangesScreen(_ client: IndigoHIDClient, udid: String) async throws -> Bool {
        let before = try screen(udid: udid, scale: client.screenScale)
        client.swipe(startX: 200, startY: 600, endX: 200, endY: 250, steps: 12)
        try await Task.sleep(for: .seconds(2))
        let after = try screen(udid: udid, scale: client.screenScale)
        return before != after
    }

    private func screen(udid: String, scale: Float) throws -> String {
        try ScreenCapture.captureSimulator(udid: udid, screenScale: scale).base64
    }

    private func reboot(udid: String) async throws {
        try await SimCtlClient.shutdownSimulator(udid: udid)
        try await Task.sleep(for: .seconds(3))
        try PrivateFrameworkBridge.shared.bootDevice(udid: udid)
        _ = try? await SimCtlClient.run("/usr/bin/xcrun", arguments: ["simctl", "bootstatus", udid, "-b"],
                                        timeout: .seconds(120))
        try await Task.sleep(for: .seconds(3))
    }
}
