import Foundation

/// Shell command runner (for `open -a Simulator.app` only) and device resolution
/// via direct CoreSimulator API calls through PrivateFrameworkBridge.
public enum SimCtlClient {

    /// Default timeout for process execution. Can be overridden via `IOSEF_TIMEOUT` env var.
    nonisolated(unsafe) public static var defaultTimeout: Duration = .seconds(30)

    public struct CommandResult: Sendable {
        public let stdout: String
        public let stderr: String
    }

    /// Runs a command with arguments and returns stdout/stderr.
    /// Used only for `open -a Simulator.app`.
    public static func run(_ command: String, arguments: [String], timeout: Duration? = nil) async throws -> CommandResult {
        let timeout = timeout ?? defaultTimeout
        logDiagnostic("run: \(command) \(arguments.prefix(4).joined(separator: " "))...", prefix: "SimCtl")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let timeoutSeconds = timeout.totalSeconds

        try process.run()

        let pid = process.processIdentifier
        let timedOut = TimeoutFlag()
        let timeoutItem = DispatchWorkItem {
            timedOut.set()
            kill(pid, SIGTERM)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: timeoutItem)

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        process.waitUntilExit()
        timeoutItem.cancel()

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

    /// Default device name derived from VCS root at startup.
    /// Set once before the server starts handling requests.
    nonisolated(unsafe) public static var defaultDeviceName: String?

    // MARK: - Device listing via direct CoreSimulator API

    /// Gets all devices from CoreSimulator as DeviceInfo structs.
    private static func getAllDevices() throws -> [DeviceInfo] {
        try PrivateFrameworkBridge.shared.allDevices().map {
            DeviceInfo(name: $0.name, udid: $0.udid, state: $0.state, isAvailable: $0.isAvailable)
        }
    }

    /// Finds an available simulator matching the given name, checking `name` then `name-main`.
    public static func findDeviceByName(_ name: String) throws -> DeviceInfo? {
        let devices = try getAllDevices()
        let candidates = [name, "\(name)-main"]
        for candidate in candidates {
            if let device = devices.first(where: { $0.name == candidate && ($0.isAvailable ?? false) }) {
                return device
            }
        }
        return nil
    }

    /// Gets the booted device info.
    public static func getBootedDevice() throws -> DeviceInfo {
        let devices = try getAllDevices()
        if let booted = devices.first(where: { $0.state == "Booted" }) {
            return booted
        }
        throw SimCtlError.noBootedSimulator
    }

    /// Resolves a device with full info (UDID + name).
    /// Checks: explicit UDID → default device by name → first booted simulator.
    public static func resolveDevice(_ udid: String?) throws -> DeviceInfo {
        let devices = try getAllDevices()

        if let udid = udid {
            if let device = devices.first(where: { $0.udid.caseInsensitiveCompare(udid) == .orderedSame }) {
                return device
            }
            return DeviceInfo(name: udid, udid: udid, state: "Unknown", isAvailable: nil)
        }

        // Try default device by name (set from VCS root at startup)
        if let name = defaultDeviceName {
            let candidates = [name, "\(name)-main"]
            for candidate in candidates {
                if let device = devices.first(where: { $0.name == candidate && ($0.isAvailable ?? false) }) {
                    logDiagnostic("No explicit UDID provided; using simulator \"\(device.name)\" (\(device.udid)) inferred from VCS root directory", prefix: "SimCtl")
                    return device
                }
            }
        }

        // Fall back to first booted simulator
        if let booted = devices.first(where: { $0.state == "Booted" }) {
            logDiagnostic("No explicit UDID provided; using first booted simulator \"\(booted.name)\" (\(booted.udid))", prefix: "SimCtl")
            return booted
        }

        throw SimCtlError.noBootedSimulator
    }

    /// Gets the UDID of the booted device, or uses the provided one.
    public static func resolveDeviceID(_ udid: String?) throws -> String {
        try resolveDevice(udid).udid
    }

    // MARK: - Device lookup by name or UDID

    /// Finds a device by name (via `findDeviceByName`) or by UDID.
    public static func findDeviceByNameOrUDID(_ identifier: String) throws -> DeviceInfo? {
        // Try name first
        if let device = try findDeviceByName(identifier) {
            return device
        }
        // Try UDID
        let devices = try getAllDevices()
        return devices.first(where: { $0.udid.caseInsensitiveCompare(identifier) == .orderedSame })
    }

    // MARK: - Simulator creation/deletion via simctl

    /// Returns the identifier of the latest iPhone device type compatible with the given runtime.
    /// Uses the runtime's `supportedDeviceTypes` list (newest-first) filtered by `productFamily == "iPhone"`.
    public static func getLatestDeviceType(forRuntime runtimeIdentifier: String) async throws -> String {
        let result = try await run("/usr/bin/xcrun", arguments: ["simctl", "list", "runtimes", "-j"])
        guard let data = result.stdout.data(using: .utf8) else {
            throw SimCtlError.parseError("Failed to parse runtimes JSON")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let runtimes = json?["runtimes"] as? [[String: Any]] else {
            throw SimCtlError.parseError("Missing 'runtimes' key in simctl output")
        }
        guard let runtime = runtimes.first(where: { ($0["identifier"] as? String) == runtimeIdentifier }),
              let supportedDeviceTypes = runtime["supportedDeviceTypes"] as? [[String: Any]] else {
            throw SimCtlError.parseError("Runtime '\(runtimeIdentifier)' not found or has no supportedDeviceTypes")
        }
        guard let first = supportedDeviceTypes.first(where: { ($0["productFamily"] as? String) == "iPhone" }),
              let identifier = first["identifier"] as? String else {
            throw SimCtlError.parseError("No compatible iPhone device type found for runtime '\(runtimeIdentifier)'")
        }
        return identifier
    }

    /// Returns the identifier of the latest available iOS runtime (e.g. `com.apple.CoreSimulator.SimRuntime.iOS-18-4`).
    public static func getLatestRuntime() async throws -> String {
        let result = try await run("/usr/bin/xcrun", arguments: ["simctl", "list", "runtimes", "-j"])
        guard let data = result.stdout.data(using: .utf8) else {
            throw SimCtlError.parseError("Failed to parse runtimes JSON")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let runtimes = json?["runtimes"] as? [[String: Any]] else {
            throw SimCtlError.parseError("Missing 'runtimes' key in simctl output")
        }
        // Find the last available iOS runtime
        guard let last = runtimes.last(where: {
            ($0["isAvailable"] as? Bool) == true &&
            ($0["identifier"] as? String)?.contains("iOS") == true
        }), let identifier = last["identifier"] as? String else {
            throw SimCtlError.parseError("No available iOS runtime found")
        }
        return identifier
    }

    /// Creates a new simulator and returns its UDID.
    public static func createSimulator(name: String, deviceType: String, runtime: String) async throws -> String {
        let result = try await run("/usr/bin/xcrun", arguments: ["simctl", "create", name, deviceType, runtime])
        let udid = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !udid.isEmpty else {
            throw SimCtlError.parseError("simctl create returned empty UDID")
        }
        return udid
    }

    /// Shuts down a simulator. Ignores errors if already shutdown.
    public static func shutdownSimulator(udid: String) async throws {
        do {
            _ = try await run("/usr/bin/xcrun", arguments: ["simctl", "shutdown", udid])
        } catch let error as SimCtlError {
            // Ignore "already shutdown" errors
            if case .commandFailed(_, _, _, let stderr) = error,
               stderr.lowercased().contains("current state: shutdown") {
                return
            }
            throw error
        }
    }

    /// Deletes a simulator.
    public static func deleteSimulator(udid: String) async throws {
        _ = try await run("/usr/bin/xcrun", arguments: ["simctl", "delete", udid])
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
