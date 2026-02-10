import Foundation

/// Represents a simulated device from simctl list output.
public struct DeviceInfo: Codable, Sendable {
    public let name: String
    public let udid: String
    public let state: String
    public let isAvailable: Bool?

    enum CodingKeys: String, CodingKey {
        case name, udid, state, isAvailable
    }
}

/// Top-level response from `simctl list devices -j`.
public struct DeviceListResponse: Codable, Sendable {
    public let devices: [String: [DeviceInfo]]
}
