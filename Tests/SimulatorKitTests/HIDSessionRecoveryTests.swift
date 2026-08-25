#if RebootTests
import Testing
import Foundation
@testable import SimulatorKit

/// Regression coverage for issue #8: a long-lived `IndigoHIDClient` used to post into a
/// dead Mach port after the simulator rebooted, so every later tap/swipe silently did
/// nothing while still reporting success.
///
/// Compiled in only with the `RebootTests` package trait (see Package.swift): the test
/// creates, boots, reboots, and deletes its own throwaway simulator (~2 min), which is
/// too slow for a plain `swift test`. Run it with:
///
///     scripts/test-reboot-recovery.sh
@Suite("HID session recovery", .tags(.requiresSimulator), .serialized)
struct HIDSessionRecoveryTests {

    @Test("Cached client still drives the simulator after a reboot")
    func clientRecoversAfterReboot() async throws {
        try await withThrowawaySimulator { udid in
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
    }

    // MARK: - Simulator lifecycle

    /// Creates and boots a dedicated simulator (latest iPhone device type on the latest
    /// iOS runtime) and deletes it afterwards, pass or fail — the test never touches a
    /// simulator someone is actually using.
    private func withThrowawaySimulator(_ body: (String) async throws -> Void) async throws {
        let runtime = try await SimCtlClient.getLatestRuntime()
        let deviceType = try await SimCtlClient.getLatestDeviceType(forRuntime: runtime)
        let udid = try await SimCtlClient.createSimulator(
            name: "iosef-reboot-test", deviceType: deviceType, runtime: runtime)
        do {
            try await boot(udid: udid)
            try await body(udid)
        } catch {
            try? await SimCtlClient.shutdownSimulator(udid: udid)
            try? await SimCtlClient.deleteSimulator(udid: udid)
            throw error
        }
        try await SimCtlClient.shutdownSimulator(udid: udid)
        try await SimCtlClient.deleteSimulator(udid: udid)
    }

    private func boot(udid: String) async throws {
        try PrivateFrameworkBridge.shared.ensureLoaded()
        try PrivateFrameworkBridge.shared.bootDevice(udid: udid)
        _ = try? await SimCtlClient.run("/usr/bin/xcrun", arguments: ["simctl", "bootstatus", udid, "-b"],
                                        timeout: .seconds(120))
        try await Task.sleep(for: .seconds(3))
    }

    private func reboot(udid: String) async throws {
        try await SimCtlClient.shutdownSimulator(udid: udid)
        try await Task.sleep(for: .seconds(3))
        try await boot(udid: udid)
    }

    // MARK: - Oracle helpers

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
}
#endif
