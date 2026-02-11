import Testing
@testable import SimulatorKit

@Suite("IndigoHIDClient Tests", .tags(.requiresSimulator))
struct IndigoHIDClientTests {

    /// Helper: gets a booted simulator UDID via simctl, or skips.
    static func bootedUDID() async throws -> String {
        let device = try await SimCtlClient.getBootedDevice()
        return device.udid
    }

    @Test("Client creation with booted simulator")
    func createClient() async throws {
        let udid = try await Self.bootedUDID()
        let client = try IndigoHIDClient(udid: udid)
        #expect(client.screenSize.width > 0)
        #expect(client.screenSize.height > 0)
        #expect(client.screenScale >= 1.0)
    }

    @Test("Screen size is reasonable for an iOS device")
    func screenSizeReasonable() async throws {
        let udid = try await Self.bootedUDID()
        let client = try IndigoHIDClient(udid: udid)
        // Smallest iOS device screen is wider than 640px
        #expect(client.screenSize.width >= 640)
        #expect(client.screenSize.height >= 1000)
    }

    @Test("Tap sends without error")
    func tapSendsWithoutError() async throws {
        let udid = try await Self.bootedUDID()
        let client = try IndigoHIDClient(udid: udid)
        // Tap center of screen — should not crash or throw
        client.tap(x: 196, y: 426)
    }

    @Test("Swipe sends without error")
    func swipeSendsWithoutError() async throws {
        let udid = try await Self.bootedUDID()
        let client = try IndigoHIDClient(udid: udid)
        // Short swipe — should not crash or throw
        client.swipe(startX: 196, startY: 500, endX: 196, endY: 300, steps: 10)
    }
}

extension Tag {
    @Tag static var requiresSimulator: Self
}
