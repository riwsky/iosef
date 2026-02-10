import Foundation

/// Async wrapper for running shell commands (primarily xcrun simctl).
public enum SimCtlClient {

    public struct CommandResult: Sendable {
        public let stdout: String
        public let stderr: String
    }

    /// Runs a command with arguments and returns stdout/stderr.
    public static func run(_ command: String, arguments: [String]) async throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Read output asynchronously
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        process.waitUntilExit()

        let stdout = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if process.terminationStatus != 0 {
            throw SimCtlError.commandFailed(
                command: command,
                args: arguments,
                exitCode: process.terminationStatus,
                stderr: stderr
            )
        }

        return CommandResult(stdout: stdout, stderr: stderr)
    }

    /// Runs xcrun simctl with the given arguments.
    public static func simctl(_ arguments: String...) async throws -> CommandResult {
        try await run("/usr/bin/xcrun", arguments: ["simctl"] + arguments)
    }

    /// Runs xcrun simctl with an array of arguments.
    public static func simctl(_ arguments: [String]) async throws -> CommandResult {
        try await run("/usr/bin/xcrun", arguments: ["simctl"] + arguments)
    }

    /// Gets the booted device info.
    public static func getBootedDevice() async throws -> DeviceInfo {
        let result = try await simctl("list", "devices", "-j")
        guard let data = result.stdout.data(using: .utf8) else {
            throw SimCtlError.parseError("Failed to parse simctl output as UTF-8")
        }

        let deviceList = try JSONDecoder().decode(DeviceListResponse.self, from: data)

        for (_, devices) in deviceList.devices {
            for device in devices where device.state == "Booted" {
                return device
            }
        }

        throw SimCtlError.noBootedSimulator
    }

    /// Gets the UDID of the booted device, or uses the provided one.
    public static func resolveDeviceID(_ udid: String?) async throws -> String {
        if let udid = udid {
            return udid
        }
        let device = try await getBootedDevice()
        return device.udid
    }

    /// Gets the device name for a given UDID.
    public static func getDeviceName(udid: String) async throws -> String? {
        let result = try await simctl("list", "devices", "-j")
        guard let data = result.stdout.data(using: .utf8) else { return nil }
        let deviceList = try JSONDecoder().decode(DeviceListResponse.self, from: data)

        for (_, devices) in deviceList.devices {
            for device in devices where device.udid == udid {
                return device.name
            }
        }
        return nil
    }

    public enum SimCtlError: Error, LocalizedError {
        case commandFailed(command: String, args: [String], exitCode: Int32, stderr: String)
        case noBootedSimulator
        case parseError(String)

        public var errorDescription: String? {
            switch self {
            case .commandFailed(_, _, _, let stderr):
                return stderr.isEmpty ? "Command failed" : stderr
            case .noBootedSimulator:
                return "No booted simulator found"
            case .parseError(let message):
                return message
            }
        }
    }
}
