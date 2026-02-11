import Foundation

/// Async wrapper for running shell commands (primarily xcrun simctl).
public enum SimCtlClient {

    /// Default timeout for process execution. Can be overridden via `IOS_SIMULATOR_MCP_TIMEOUT` env var.
    nonisolated(unsafe) public static var defaultTimeout: Duration = .seconds(30)

    public struct CommandResult: Sendable {
        public let stdout: String
        public let stderr: String
    }

    /// Runs a command with arguments and returns stdout/stderr.
    /// Times out after `timeout` (defaults to `defaultTimeout`), killing the process if exceeded.
    public static func run(_ command: String, arguments: [String], timeout: Duration? = nil) async throws -> CommandResult {
        let timeout = timeout ?? defaultTimeout
        let shortArgs = arguments.prefix(4).joined(separator: " ")
        fputs("[SimCtl] run: \(command) \(shortArgs)...\n", stderr)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let timeoutSeconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18

        try process.run()
        fputs("[SimCtl] process launched (pid \(process.processIdentifier)), reading output...\n", stderr)

        // Schedule timeout: capture only PID (Int32, Sendable) and a thread-safe flag
        let pid = process.processIdentifier
        let timedOut = TimeoutFlag()
        let timeoutItem = DispatchWorkItem {
            timedOut.set()
            kill(pid, SIGTERM)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: timeoutItem)

        // Read output (blocks until write end closes when process exits)
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        process.waitUntilExit()
        timeoutItem.cancel()
        fputs("[SimCtl] exited with status \(process.terminationStatus), stdout=\(stdoutData.count)B stderr=\(stderrData.count)B\n", stderr)

        if timedOut.value {
            let desc = ([command] + arguments).joined(separator: " ")
            throw TimeoutError.processTimedOut(command: desc, timeoutSeconds: timeoutSeconds)
        }

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

    /// Thread-safe boolean flag for timeout detection.
    private final class TimeoutFlag: @unchecked Sendable {
        private var _value = false
        private let lock = NSLock()

        var value: Bool {
            lock.lock()
            defer { lock.unlock() }
            return _value
        }

        func set() {
            lock.lock()
            defer { lock.unlock() }
            _value = true
        }
    }

    /// Runs xcrun simctl with the given arguments.
    public static func simctl(_ arguments: String...) async throws -> CommandResult {
        try await run("/usr/bin/xcrun", arguments: ["simctl"] + arguments)
    }

    /// Runs xcrun simctl with an array of arguments.
    public static func simctl(_ arguments: [String], timeout: Duration? = nil) async throws -> CommandResult {
        try await run("/usr/bin/xcrun", arguments: ["simctl"] + arguments, timeout: timeout)
    }

    /// Default device name derived from VCS root at startup.
    /// Set once before the server starts handling requests.
    nonisolated(unsafe) public static var defaultDeviceName: String?

    /// Finds an available simulator matching the given name, checking `name` then `name-main`.
    public static func findDeviceByName(_ name: String) async throws -> DeviceInfo? {
        let result = try await simctl("list", "devices", "-j")
        guard let data = result.stdout.data(using: .utf8) else { return nil }
        let deviceList = try JSONDecoder().decode(DeviceListResponse.self, from: data)

        let candidates = [name, "\(name)-main"]
        for candidate in candidates {
            for (_, devices) in deviceList.devices {
                for device in devices where device.name == candidate && (device.isAvailable ?? false) {
                    return device
                }
            }
        }
        return nil
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

        // Try default device by name (set from VCS root at startup)
        if let name = defaultDeviceName,
           let device = try await findDeviceByName(name) {
            return device.udid
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
