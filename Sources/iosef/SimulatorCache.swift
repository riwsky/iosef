import Foundation
import SimulatorKit

// MARK: - Simulator cache

/// Caches device info, AXP accessibility bridge, and HID clients.
/// Device info (UDID + name) is cached in-memory (for MCP server mode).
actor SimulatorCache {
    static let shared = SimulatorCache()

    private struct DeviceCache {
        let udid: String
        let name: String?
        let timestamp: ContinuousClock.Instant
    }

    private var deviceCache: DeviceCache?
    private var axpBridges: [String: AXPAccessibilityBridge] = [:]
    private var hidClients: [String: IndigoHIDClient] = [:]

    private let deviceTTL: Duration = .seconds(30)

    /// Resolves device UDID, checking (in order):
    /// 1. Explicit identifier (UUID or simulator name)
    /// 2. In-memory cache (for MCP server mode)
    /// 3. Direct CoreSimulator API call
    ///
    /// After resolution, verifies the device is booted and throws a descriptive
    /// error with boot commands if it's shutdown.
    func resolveDeviceID(_ udid: String?) throws -> String {
        if let identifier = udid {
            let device: DeviceInfo
            if Self.isUUID(identifier) {
                device = try SimCtlClient.resolveDevice(identifier)
            } else {
                // Treat as simulator name
                guard let found = try SimCtlClient.findDeviceByName(identifier) else {
                    throw DeviceNotBootedError(
                        message: "No simulator found with name \"\(identifier)\". "
                            + "Create one with: xcrun simctl create \"\(identifier)\" \"iPhone 16\""
                    )
                }
                device = found
            }
            try Self.validateBooted(device)
            fputs("[iosef] Using device \"\(device.name)\" (\(device.udid)) — explicit --device flag\n", stderr)
            return device.udid
        }

        let now = ContinuousClock.now
        if let cached = deviceCache,
           now - cached.timestamp < deviceTTL {
            fputs("[iosef] Using device \"\(cached.name ?? cached.udid)\" (\(cached.udid)) — cached from earlier this session\n", stderr)
            return cached.udid
        }

        let device = try SimCtlClient.resolveDevice(nil)
        try Self.validateBooted(device)
        deviceCache = DeviceCache(udid: device.udid, name: device.name, timestamp: now)
        let reason: String
        if SimCtlClient.defaultDeviceName != nil {
            reason = "resolved via CoreSimulator (matched project/VCS name)"
        } else {
            reason = "first booted simulator"
        }
        fputs("[iosef] Using device \"\(device.name)\" (\(device.udid)) — \(reason)\n", stderr)
        return device.udid
    }

    /// Checks whether a string is a valid UUID (8-4-4-4-12 hex format).
    private static func isUUID(_ string: String) -> Bool {
        UUID(uuidString: string) != nil
    }

    /// Throws a descriptive error if the device is not booted, suggesting boot commands.
    private static func validateBooted(_ device: DeviceInfo) throws {
        guard device.state == "Booted" else {
            throw DeviceNotBootedError(
                message: "Simulator \"\(device.name)\" (\(device.udid)) is \(device.state.lowercased()). Boot it with:\n"
                    + "  xcrun simctl boot \"\(device.name)\" && open -a Simulator"
            )
        }
    }

    /// Gets or creates an AXPAccessibilityBridge for the given UDID.
    func getAXPBridge(udid: String) throws -> AXPAccessibilityBridge {
        if let cached = axpBridges[udid] {
            return cached
        }
        let bridge = try AXPAccessibilityBridge(udid: udid)
        axpBridges[udid] = bridge
        return bridge
    }

    /// Gets the screen scale for a device without creating a full HID client.
    /// Uses the cached device from PrivateFrameworkBridge.lookUpDevice.
    func getScreenScale(udid: String) throws -> Float {
        let bridge = PrivateFrameworkBridge.shared
        try bridge.ensureLoaded()
        let device = try bridge.lookUpDevice(udid: udid)
        return bridge.screenScale(forDevice: device)
    }

    /// Gets or creates an IndigoHIDClient for the given UDID.
    /// Clients are cached indefinitely (they hold a SimDevice reference).
    func getHIDClient(udid: String) throws -> IndigoHIDClient {
        if let cached = hidClients[udid] {
            return cached
        }
        let client = try IndigoHIDClient(udid: udid)
        hidClients[udid] = client
        return client
    }

    /// Deterministic cleanup: release HID clients and AXP bridges in reverse
    /// order of creation so that Mach ports and XPC connections are closed
    /// before the process exits, rather than relying on OS reaping.
    func shutdown() {
        axpBridges.removeAll()
        hidClients.removeAll()
        deviceCache = nil
    }
}
