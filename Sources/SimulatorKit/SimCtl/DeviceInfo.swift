import Foundation

/// Represents a simulated device.
public struct DeviceInfo: Sendable {
    public let name: String
    public let udid: String
    public let state: String
    public let isAvailable: Bool?

    public init(name: String, udid: String, state: String, isAvailable: Bool?) {
        self.name = name
        self.udid = udid
        self.state = state
        self.isAvailable = isAvailable
    }
}
