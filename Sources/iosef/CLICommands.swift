import ArgumentParser
import Foundation
import MCP
import SimulatorKit

// MARK: - Default device name from VCS root

/// Run a command and return trimmed stdout, or nil on failure. Times out after `timeout` (default 5s).
func runForOutput(_ executable: String, _ arguments: [String], timeout: Duration = .seconds(5)) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice

    let semaphore = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in
        semaphore.signal()
    }

    do {
        try process.run()
    } catch {
        return nil
    }

    let timeoutSeconds = timeout.totalSeconds
    let waitResult = semaphore.wait(timeout: .now() + timeoutSeconds)

    if waitResult == .timedOut {
        process.terminate()
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
        }
        return nil
    }

    guard process.terminationStatus == 0 else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let output = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
          !output.isEmpty else { return nil }
    return output
}

func computeDefaultDeviceName() -> String? {
    // Try jj root first (Jujutsu), then git
    let root = runForOutput("/usr/bin/env", ["jj", "root"])
             ?? runForOutput("/usr/bin/git", ["rev-parse", "--show-toplevel"])

    guard let root else { return nil }
    return URL(fileURLWithPath: root).lastPathComponent
}

// MARK: - Setup

func setupGlobals() {
    SimCtlClient.defaultDeviceName = computeDefaultDeviceName()

    // Session state overrides VCS heuristic (but not explicit --device flags)
    applySessionState()

    if let timeoutStr = ProcessInfo.processInfo.environment["IOSEF_TIMEOUT"],
       let timeoutSecs = Double(timeoutStr), timeoutSecs > 0 {
        SimCtlClient.defaultTimeout = .seconds(Int64(timeoutSecs))
    }
}

// MARK: - Common CLI options

struct CommonOptions: ParsableArguments {
    @Flag(name: .long, help: "Enable diagnostic logging")
    var verbose: Bool = false

    @Flag(name: .long, help: "Output results as JSON")
    var json: Bool = false

    @Option(name: [.long, .customLong("udid", withSingleDash: false)], help: "Simulator name or UDID (auto-detected if omitted)")
    var device: String? = nil

    @Flag(name: .long, help: "Use local session (./.iosef/)")
    var local: Bool = false

    @Flag(name: .long, help: "Use global session (~/.iosef/)")
    var global: Bool = false

    /// Adds the device identifier to a tool arguments dictionary (as "udid" key for MCP compatibility).
    func addDevice(to args: inout [String: Value]) {
        if let device { args["udid"] = .string(device) }
    }
}

// MARK: - Selector CLI options

struct SelectorOptions: ParsableArguments {
    @Option(name: .long, help: "Match accessibility role (e.g. AXButton)")
    var role: String? = nil

    @Option(name: .long, help: "Match label or title (substring, case-insensitive)")
    var name: String? = nil

    @Option(name: .long, help: "Match accessibilityIdentifier (exact)")
    var identifier: String? = nil

    func toArguments() -> [String: Value] {
        var args: [String: Value] = [:]
        if let role { args["role"] = .string(role) }
        if let name { args["name"] = .string(name) }
        if let identifier { args["identifier"] = .string(identifier) }
        return args
    }
}

// MARK: - Shared CLI output helper

/// Runs a tool via handleToolCall and formats the result for terminal output.
/// Used by all CLI subcommands to avoid duplicating output logic.
func runToolCLI(toolName: String, arguments: [String: Value], json: Bool, output: String?, verbose: Bool = false, common: CommonOptions? = nil) async throws {
    verboseLogging = verbose
    if let common { applyScope(from: common) }
    setupGlobals()

    log("CLI: running tool '\(toolName)' with args: \(arguments)")
    let params = CallTool.Parameters(name: toolName, arguments: arguments.isEmpty ? nil : arguments)
    let result = await handleToolCall(params)

    if json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(result)
        print(String(data: data, encoding: .utf8)!)
    } else {
        for content in result.content {
            switch content {
            case .text(let text):
                print(text)
            case .image(let data, let mimeType, _):
                guard let imageData = Data(base64Encoded: data) else {
                    fputs("Error: failed to decode base64 image data\n", stderr)
                    continue
                }
                if let outputPath = output {
                    let path = ensureAbsolutePath(outputPath)
                    try imageData.write(to: URL(fileURLWithPath: path))
                    print("Image (\(mimeType)) saved to \(path)")
                } else {
                    let cacheDir = ensureSessionDir() + "/cache"
                    let timestamp = Int(Date().timeIntervalSince1970)
                    let ext = mimeType.split(separator: "/").last.map(String.init) ?? "jpg"
                    let screenshotPath = cacheDir + "/screenshot_\(timestamp).\(ext)"
                    try imageData.write(to: URL(fileURLWithPath: screenshotPath))
                    print(screenshotPath)
                }
            case .audio(let data, let mimeType):
                if let outputPath = output {
                    let path = ensureAbsolutePath(outputPath)
                    guard let audioData = Data(base64Encoded: data) else {
                        fputs("Error: failed to decode base64 audio data\n", stderr)
                        continue
                    }
                    try audioData.write(to: URL(fileURLWithPath: path))
                    print("Audio (\(mimeType)) saved to \(path)")
                } else {
                    print("Audio (\(mimeType), \(data.count) bytes base64). Use --output <path> to save.")
                }
            default:
                print("<unknown content type>")
            }
        }
    }

    if result.isError == true {
        fputs("Tool returned error\n", stderr)
        throw ExitCode.failure
    }
    log("CLI: done")
}

// MARK: - ArgumentParser commands

@main
struct SimulatorCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "iosef",
        abstract: "Control iOS Simulator — tap, type, swipe, inspect, and screenshot.",
        discussion: """
            Tap, type, swipe, inspect accessibility elements, and capture screenshots \
            in iOS Simulator. Runs as a standalone CLI or as an MCP server (stdio \
            transport) for agent integration.

            Getting Started:
              iosef start --local --device "my-sim"

              Creates a session directory (.iosef/) with state.json in the current \
              directory, boots the simulator (creating it if needed), and opens \
              Simulator.app. Subsequent commands auto-detect the device from the session.

            Lifecycle:
              iosef start       Create/boot a simulator and set up a session.
              iosef stop        Shut down, delete the simulator, and remove the session.
              iosef connect     Associate with an existing simulator.
              iosef status      Show current simulator and session status.

            Session:
              Local:  ./.iosef/   (created with start --local)
              Global: ~/.iosef/   (default)

              The local directory takes priority when ./.iosef/state.json exists. \
              Use --local or --global on any command to override. The session stores \
              the device name and cached state (screenshots without --output).

            Coordinates:
              All commands use iOS points. The accessibility tree reports positions as
              (center±half-size) — the center value is the tap target. Screenshots are
              coordinate-aligned: 1 pixel = 1 iOS point.

            Device Resolution:
              When --device is omitted, the CLI resolves the target simulator in order:
              1. state.json device field (local session, then global)
              2. VCS root directory name (git or jj)
              3. Any booted simulator
              Pass --device explicitly (name or UDID) to override.

            Environment Variables:
              IOSEF_DEFAULT_OUTPUT_DIR      Default directory for screenshots.
              IOSEF_TIMEOUT                 Override default timeout (seconds).
              IOSEF_FILTERED_TOOLS          Comma-separated tools to hide from MCP.

            Example — selector-based (preferred):
              # Tap a button by name
              iosef tap_element --name "Sign In"

              # Type into a field by role
              iosef input --role AXTextField --text "hello"

              # Wait for a screen to load
              iosef wait --name "Welcome"

              # Check if an element exists
              iosef exists --role AXButton --name "Submit"

            Example — coordinate-based (when elements lack labels):
              iosef describe
              iosef tap --x 195 --y 420
              iosef swipe --x-start 200 --y-start 600 --x-end 200 --y-end 200

              See 'iosef help <subcommand>' for detailed help.

            Exit Codes:
              0  Success.
              1  Check failed (exists returned false) or tool error.
              2  Bad arguments or usage error.
            """,
        version: serverVersion,
        subcommands: [MCPServe.self],
        groupedSubcommands: [
            CommandGroup(name: "Lifecycle:", subcommands: [
                Start.self,
                Stop.self,
                Connect.self,
                Status.self,
                InstallApp.self,
                LaunchApp.self,
            ]),
            CommandGroup(name: "Inspection:", subcommands: [
                Describe.self,
                UIView.self,
            ]),
            CommandGroup(name: "Interaction:", subcommands: [
                Tap.self,
                UIType.self,
                UISwipe.self,
            ]),
            CommandGroup(name: "Selectors:", subcommands: [
                Find.self,
                Exists.self,
                Count.self,
                Text.self,
                TapElement.self,
                Input.self,
                Wait.self,
            ]),
            CommandGroup(name: "Logging:", subcommands: [
                LogShow.self,
                LogStream.self,
            ]),
        ]
    )
}

// MARK: - mcp (MCP server mode)

struct MCPServe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Start the MCP server (stdio transport).",
        discussion: """
            Starts a Model Context Protocol server on stdin/stdout. \
            Use this when configuring the tool as an MCP server for AI agents.
            """
    )

    func run() async throws {
        verboseLogging = true
        setupGlobals()

        let server = Server(
            name: "iosef",
            version: serverVersion,
            capabilities: .init(tools: .init(listChanged: false))
        )

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: allTools())
        }

        await server.withMethodHandler(CallTool.self) { params in
            await handleToolCall(params)
        }

        let transport = StdioTransport()
        try await server.start(transport: transport)

        // Wait for SIGINT/SIGTERM/SIGHUP or stdin EOF instead of sleeping forever.
        // This lets us run deterministic cleanup before exit.
        nonisolated(unsafe) var signalSources: [DispatchSourceSignal] = []
        let sigStream = AsyncStream<Int32> { continuation in
            for sig: Int32 in [SIGINT, SIGTERM, SIGHUP] {
                signal(sig, SIG_IGN)   // ignore default handler
                let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
                source.setEventHandler { continuation.yield(sig) }
                source.resume()
                signalSources.append(source)
            }

            // Detect parent disconnect: poll stdin for POLLHUP (pipe closed).
            // macOS requires events=POLLIN for POLLHUP to be reported in revents.
            // poll() only checks fd state — doesn't read data — so it won't
            // interfere with StdioTransport's readLoop.
            DispatchQueue.global(qos: .utility).async {
                var fds = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
                while true {
                    let ret = withUnsafeMutablePointer(to: &fds) { poll($0, 1, 1000) }
                    if ret > 0 {
                        let r = Int32(fds.revents)
                        if (r & POLLHUP) != 0 || (r & POLLNVAL) != 0 || (r & POLLERR) != 0 {
                            continuation.yield(SIGHUP)
                            break
                        }
                        fds.revents = 0  // POLLIN only (data for transport) — keep polling
                    }
                    if ret < 0 && errno != EINTR { break }
                }
            }

            continuation.onTermination = { @Sendable _ in
                for source in signalSources { source.cancel() }
            }
        }
        for await sig in sigStream {
            log("Received signal \(sig), shutting down...")
            break
        }

        await SimulatorCache.shared.shutdown()
        log("Cleanup complete, exiting.")
    }
}

// MARK: - Tool subcommands

struct Start: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Set up a session and boot the simulator.",
        discussion: """
            Creates a session directory, resolves the target device, boots the \
            simulator if needed, and opens Simulator.app. If no simulator with the \
            given name exists, one is created automatically.

            With --local, creates ./.iosef/ in the current directory. \
            Without --local, uses the global ~/.iosef/ directory.

            Device resolution order:
              1. --device flag
              2. Existing state.json device field
              3. VCS root directory name

            Examples:
              iosef start --local --device "my-sim"
              iosef start
              iosef start --device 6C07B68F-...
              iosef start --local --device-type "iPhone 16 Pro" --runtime "iOS 18.4"
            """
    )

    @OptionGroup var common: CommonOptions

    @Option(name: .customLong("device-type"), help: "Device type (e.g. \"iPhone 16 Pro\"). Default: latest iPhone. See: xcrun simctl list devicetypes")
    var deviceType: String? = nil

    @Option(name: .long, help: "Runtime (e.g. \"iOS 18.4\"). Default: latest iOS. See: xcrun simctl list runtimes")
    var runtime: String? = nil

    func run() async throws {
        verboseLogging = common.verbose
        applyScope(from: common)

        // 1. Resolve device name
        let vcsName = computeDefaultDeviceName()
        let existingState = readSessionState()
        let deviceName = common.device ?? existingState?.device ?? vcsName

        // 2. Create session directory and write state
        let dir = ensureSessionDir()
        let state = SessionState(device: deviceName)
        try writeSessionState(state, to: dir)
        log("Wrote session to \(dir)/state.json")

        if common.local && !isIosefGitignored(in: FileManager.default.currentDirectoryPath) {
            fputs("[iosef] Warning: .iosef/ is not in your .gitignore. Add it to keep session state out of version control.\n", stderr)
        }

        // 3. Boot the simulator if not already booted, creating if needed
        if let name = deviceName {
            var device = try SimCtlClient.findDeviceByName(name)
            if device == nil {
                // Create the simulator
                let resolvedType: String
                if let deviceType {
                    resolvedType = deviceType
                } else {
                    resolvedType = try await SimCtlClient.getLatestDeviceType()
                }
                let resolvedRuntime: String
                if let runtime {
                    resolvedRuntime = runtime
                } else {
                    resolvedRuntime = try await SimCtlClient.getLatestRuntime()
                }
                let udid = try await SimCtlClient.createSimulator(name: name, deviceType: resolvedType, runtime: resolvedRuntime)
                print("Created simulator \"\(name)\" (\(resolvedType), \(resolvedRuntime))")
                device = DeviceInfo(name: name, udid: udid, state: "Shutdown", isAvailable: true)
            }
            if let device, device.state != "Booted" {
                print("Booting simulator \"\(name)\"...")
                _ = try await SimCtlClient.run("/usr/bin/xcrun", arguments: ["simctl", "boot", device.udid])
            }
        } else {
            let device = try SimCtlClient.getBootedDevice()
            print("Using already-booted simulator: \"\(device.name)\"")
        }

        // 4. Open Simulator.app
        _ = try await SimCtlClient.run("/usr/bin/open", arguments: ["-a", "Simulator.app"])

        let displayName = deviceName ?? "default"
        let scopeLabel = common.local ? "local" : "global"
        print("Started (\(scopeLabel)): \(displayName)")
        print("Session: \(dir)/state.json")
    }
}

struct Stop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Shut down, delete the simulator, and remove the session.",
        discussion: """
            Reads state.json to find the device, shuts it down, deletes it from \
            the simulator runtime, and removes the session directory.

            If the device is not found (e.g. already deleted), just cleans up the \
            session directory.

            Examples:
              iosef stop
              iosef stop --local
            """
    )

    @OptionGroup var common: CommonOptions

    func run() async throws {
        verboseLogging = common.verbose
        applyScope(from: common)

        let sessionDir = resolveSessionDir()
        let state = SimulatorKit.readSessionState(from: sessionDir)

        if let deviceName = state?.device {
            let device = try SimCtlClient.findDeviceByName(deviceName)
            if let device {
                if device.state == "Booted" {
                    print("Shutting down simulator \"\(deviceName)\"...")
                    try await SimCtlClient.shutdownSimulator(udid: device.udid)
                }
                print("Deleting simulator \"\(deviceName)\"...")
                try await SimCtlClient.deleteSimulator(udid: device.udid)
                print("Stopped and removed simulator \"\(deviceName)\"")
            } else {
                print("Simulator \"\(deviceName)\" not found, cleaning up session only")
            }
        } else {
            print("No device in session state, cleaning up session directory only")
        }

        // Remove session directory
        let fm = FileManager.default
        if fm.fileExists(atPath: sessionDir) {
            try fm.removeItem(atPath: sessionDir)
            print("Removed session: \(sessionDir)")
        }
    }
}

struct Connect: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "connect",
        abstract: "Associate with an existing simulator.",
        discussion: """
            Looks up a simulator by name or UDID, boots it if needed, opens \
            Simulator.app, and creates a session pointing to it.

            Examples:
              iosef connect "iPhone 16"
              iosef connect 6C07B68F-... --local
            """
    )

    @OptionGroup var common: CommonOptions

    @Argument(help: "Simulator name or UDID")
    var nameOrUDID: String

    func run() async throws {
        verboseLogging = common.verbose
        applyScope(from: common)

        guard let device = try SimCtlClient.findDeviceByNameOrUDID(nameOrUDID) else {
            fputs("Error: No simulator found matching \"\(nameOrUDID)\"\n", stderr)
            throw ExitCode.failure
        }

        // Boot if needed
        if device.state != "Booted" {
            print("Booting simulator \"\(device.name)\"...")
            _ = try await SimCtlClient.run("/usr/bin/xcrun", arguments: ["simctl", "boot", device.udid])
        }

        // Open Simulator.app
        _ = try await SimCtlClient.run("/usr/bin/open", arguments: ["-a", "Simulator.app"])

        // Create session
        let dir = ensureSessionDir()
        let state = SessionState(device: device.name)
        try writeSessionState(state, to: dir)

        if common.local && !isIosefGitignored(in: FileManager.default.currentDirectoryPath) {
            fputs("[iosef] Warning: .iosef/ is not in your .gitignore. Add it to keep session state out of version control.\n", stderr)
        }

        print("Connected to \"\(device.name)\" (\(device.udid))")
        print("Session: \(dir)/state.json")
    }
}

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show current simulator and session status.",
        discussion: """
            Displays the active simulator's name, UDID, state, and session info. \
            Use --json for machine-readable output.

            Examples:
              iosef status
              iosef status --json
            """
    )

    @OptionGroup var common: CommonOptions

    func run() async throws {
        verboseLogging = common.verbose
        applyScope(from: common)
        setupGlobals()

        // Determine session info
        let sessionDir = resolveSessionDir()
        let sessionState = SimulatorKit.readSessionState(from: sessionDir)
        let sessionLabel: String
        if activeScope == .local || sessionDir.hasSuffix(".iosef") {
            sessionLabel = "local (\(sessionDir))"
        } else if sessionDir.hasPrefix(NSHomeDirectory()) && sessionDir.contains("/.iosef") {
            sessionLabel = "global (\(sessionDir))"
        } else {
            sessionLabel = "none"
        }

        // Try to resolve device
        let device: DeviceInfo?
        if let deviceName = common.device {
            device = try SimCtlClient.findDeviceByNameOrUDID(deviceName)
        } else if let sessionDevice = sessionState?.device {
            device = try SimCtlClient.findDeviceByName(sessionDevice)
        } else {
            device = try? SimCtlClient.getBootedDevice()
        }

        if common.json {
            var info: [String: Any] = [:]
            if let device {
                info["device"] = device.name
                info["udid"] = device.udid
                info["state"] = device.state
            }
            info["session"] = sessionLabel
            let data = try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
            print(String(data: data, encoding: .utf8)!)
        } else {
            if let device {
                print("Device:  \(device.name)")
                print("UDID:    \(device.udid)")
                print("State:   \(device.state)")
            } else {
                print("Device:  (none)")
            }
            print("Session: \(sessionLabel)")
        }
    }
}

struct Describe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "describe",
        abstract: "Describe accessibility elements (full tree or at a point).",
        discussion: """
            Two modes:

            Tree mode (default): dumps the full accessibility tree. Use --depth to limit \
            depth (0 = root only). Use --json for machine-readable output.

            Point mode: pass --x and --y to get the element at those coordinates.

            Coordinates are (center±half-size) in iOS points — the center value is the tap target.

            Examples:
              iosef describe
              iosef describe --depth 2
              iosef describe --json | jq '.. | objects | select(.role == "button")'
              iosef describe --x 200 --y 400
              iosef describe --x 200 --y 400 --json
            """
    )

    @OptionGroup var common: CommonOptions

    @Option(name: .long, help: "Maximum tree depth (omit for full tree, tree mode only)")
    var depth: Int?

    @Option(name: .long, help: "The x-coordinate (point mode)")
    var x: Double?

    @Option(name: .long, help: "The y-coordinate (point mode)")
    var y: Double?

    func validate() throws {
        let hasX = x != nil
        let hasY = y != nil
        if hasX != hasY {
            throw ValidationError("Both --x and --y are required for point mode (got only \(hasX ? "--x" : "--y"))")
        }
        if hasX && hasY && depth != nil {
            throw ValidationError("Cannot combine --depth with --x/--y — depth is only for tree mode")
        }
    }

    func run() async throws {
        var args: [String: Value] = [:]
        common.addDevice(to: &args)
        if let depth { args["depth"] = .int(depth) }
        if let x { args["x"] = .double(x) }
        if let y { args["y"] = .double(y) }
        try await runToolCLI(toolName: "describe", arguments: args, json: common.json, output: nil, verbose: common.verbose, common: common)
    }
}

struct Tap: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tap",
        abstract: "Tap by selector or at (x, y) coordinates.",
        discussion: """
            Two modes:

            Selector mode: searches the accessibility tree for the first matching element \
            and taps its center. Use --role, --name, --identifier.

            Coordinate mode: pass --x and --y to tap at exact coordinates. \
            Coordinates are in iOS points. Use describe to find element positions.

            Provide selectors OR coordinates, not both. \
            For long-press, pass --duration (in seconds).

            Examples:
              iosef tap --name "Sign In"
              iosef tap --role AXButton --name "Submit"
              iosef tap --name "Menu" --duration 0.5
              iosef tap --x 200 --y 400
              iosef tap --x 100 --y 300 --duration 0.5
            """
    )

    @OptionGroup var common: CommonOptions
    @OptionGroup var selector: SelectorOptions

    @Option(name: .long, help: "The x-coordinate (coordinate mode)")
    var x: Double?

    @Option(name: .long, help: "The y-coordinate (coordinate mode)")
    var y: Double?

    @Option(name: .long, help: "Press duration in seconds (for long-press)")
    var duration: Double?

    func validate() throws {
        let hasSelector = selector.role != nil || selector.name != nil || selector.identifier != nil
        let hasX = x != nil
        let hasY = y != nil
        if hasX != hasY {
            throw ValidationError("Both --x and --y are required for coordinate mode (got only \(hasX ? "--x" : "--y"))")
        }
        let hasPoint = hasX && hasY
        if hasSelector && hasPoint {
            throw ValidationError("Cannot combine selectors (--role/--name/--identifier) with coordinates (--x/--y)")
        }
        if !hasSelector && !hasPoint {
            throw ValidationError("Provide either selectors (--role/--name/--identifier) or coordinates (--x/--y)")
        }
    }

    func run() async throws {
        var args = selector.toArguments()
        if let x { args["x"] = .double(x) }
        if let y { args["y"] = .double(y) }
        if let duration { args["duration"] = .double(duration) }
        common.addDevice(to: &args)
        try await runToolCLI(toolName: "tap", arguments: args, json: common.json, output: nil, verbose: common.verbose, common: common)
    }
}

struct UIType: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "type",
        abstract: "Type text into the focused field.",
        discussion: """
            Sends keyboard HID events to type text into whatever field currently has \
            focus in the simulator. Only printable ASCII characters (0x20-0x7E) are supported.

            Tip: prefer input to find a field, tap it, and type in one step.

            Tap a text field first with tap to ensure it has focus.

            Examples:
              iosef type --text hello
              iosef type --text "Hello World"
            """
    )

    @OptionGroup var common: CommonOptions

    @Option(name: .long, help: "Text to input")
    var text: String

    func run() async throws {
        var args: [String: Value] = ["text": .string(text)]
        common.addDevice(to: &args)
        try await runToolCLI(toolName: "type", arguments: args, json: common.json, output: nil, verbose: common.verbose, common: common)
    }
}

struct UISwipe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swipe",
        abstract: "Swipe between two points on the simulator screen.",
        discussion: """
            Sends a multi-step HID touch drag from (x_start, y_start) to (x_end, y_end). \
            Coordinates are in iOS points.

            Use --delta to control step granularity (smaller = more steps = smoother). \
            Use --duration to control speed (in seconds).

            Examples:
              iosef swipe --x-start 200 --y-start 600 --x-end 200 --y-end 200
              iosef swipe --x-start 200 --y-start 600 --x-end 200 --y-end 200 --duration 0.3
            """
    )

    @OptionGroup var common: CommonOptions

    @Option(name: .customLong("x-start"), help: "The starting x-coordinate")
    var xStart: Double

    @Option(name: .customLong("y-start"), help: "The starting y-coordinate")
    var yStart: Double

    @Option(name: .customLong("x-end"), help: "The ending x-coordinate")
    var xEnd: Double

    @Option(name: .customLong("y-end"), help: "The ending y-coordinate")
    var yEnd: Double

    @Option(name: .long, help: "The size of each step in the swipe (default is 1)")
    var delta: Double?

    @Option(name: .long, help: "Swipe duration in seconds")
    var duration: Double?

    func run() async throws {
        var args: [String: Value] = [
            "x_start": .double(xStart),
            "y_start": .double(yStart),
            "x_end": .double(xEnd),
            "y_end": .double(yEnd),
        ]
        if let delta { args["delta"] = .double(delta) }
        if let duration { args["duration"] = .double(duration) }
        common.addDevice(to: &args)
        try await runToolCLI(toolName: "swipe", arguments: args, json: common.json, output: nil, verbose: common.verbose, common: common)
    }
}

struct UIView: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "view",
        abstract: "Capture a screenshot of the simulator screen.",
        discussion: """
            In CLI mode, saves the screenshot to a file and prints the path. \
            Use --output to specify a path, otherwise a temp file is created.

            In MCP mode, returns base64 image data unless output_path is provided.

            The screenshot is coordinate-aligned with tap and describe — \
            pixels correspond to iOS points.

            Examples:
              iosef view
              iosef view --output /tmp/screen.jpg
              iosef view --output /tmp/screen.png --type png
            """
    )

    @OptionGroup var common: CommonOptions

    @Option(name: .long, help: "Save screenshot to this file path")
    var output: String?

    @Option(name: .long, help: "Image format: png, tiff, bmp, gif, jpeg (default: png)")
    var type: String?

    func run() async throws {
        var args: [String: Value] = [:]
        if let output { args["output_path"] = .string(output) }
        if let type { args["type"] = .string(type) }
        common.addDevice(to: &args)
        try await runToolCLI(toolName: "view", arguments: args, json: common.json, output: output, verbose: common.verbose, common: common)
    }
}

struct InstallApp: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install_app",
        abstract: "Install a .app or .ipa bundle on the simulator.",
        discussion: """
            Installs an application bundle using CoreSimulator's private API \
            (faster than simctl install). Supports .app directories and .ipa files.

            Examples:
              iosef install_app --app-path /path/to/MyApp.app
              iosef install_app --app-path ./build/MyApp.app
            """
    )

    @OptionGroup var common: CommonOptions

    @Option(name: .customLong("app-path"), help: "Path to the app bundle (.app directory or .ipa file) to install")
    var appPath: String

    func run() async throws {
        var args: [String: Value] = ["app_path": .string(appPath)]
        common.addDevice(to: &args)
        try await runToolCLI(toolName: "install_app", arguments: args, json: common.json, output: nil, verbose: common.verbose, common: common)
    }
}

struct LaunchApp: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "launch_app",
        abstract: "Launch an app by bundle identifier.",
        discussion: """
            Launches an installed app on the simulator using CoreSimulator's private API. \
            Optionally terminates the app first if it's already running.

            Examples:
              iosef launch_app --bundle-id com.apple.mobilesafari
              iosef launch_app --bundle-id com.example.myapp --terminate-running
            """
    )

    @OptionGroup var common: CommonOptions

    @Option(name: .customLong("bundle-id"), help: "Bundle identifier of the app to launch (e.g., com.apple.mobilesafari)")
    var bundleID: String

    @Flag(name: .customLong("terminate-running"), help: "Terminate the app if it is already running before launching")
    var terminateRunning: Bool = false

    func run() async throws {
        var args: [String: Value] = ["bundle_id": .string(bundleID)]
        if terminateRunning { args["terminate_running"] = .bool(true) }
        common.addDevice(to: &args)
        try await runToolCLI(toolName: "launch_app", arguments: args, json: common.json, output: nil, verbose: common.verbose, common: common)
    }
}

// MARK: - Selector-based CLI subcommands

struct Find: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "find",
        abstract: "Find accessibility elements by selector.",
        discussion: """
            Searches the accessibility tree for elements matching the given criteria. \
            At least one of --role, --name, or --identifier must be provided. \
            Multiple criteria are combined with AND logic.

            Examples:
              iosef find --role AXButton
              iosef find --name "Sign In"
              iosef find --role AXStaticText --name "count"
            """
    )

    @OptionGroup var common: CommonOptions
    @OptionGroup var selector: SelectorOptions

    func run() async throws {
        var args = selector.toArguments()
        common.addDevice(to: &args)
        try await runToolCLI(toolName: "find", arguments: args, json: common.json, output: nil, verbose: common.verbose, common: common)
    }
}

struct Exists: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "exists",
        abstract: "Check if a matching element exists.",
        discussion: """
            Returns "true" if at least one element matches the selector, "false" otherwise. \
            Useful for conditional logic in scripts.

            Examples:
              iosef exists --name "Sign In"
              iosef exists --role AXButton --name "Submit"
            """
    )

    @OptionGroup var common: CommonOptions
    @OptionGroup var selector: SelectorOptions

    func run() async throws {
        var args = selector.toArguments()
        common.addDevice(to: &args)
        try await runToolCLI(toolName: "exists", arguments: args, json: common.json, output: nil, verbose: common.verbose, common: common)
    }
}

struct Count: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "count",
        abstract: "Count matching accessibility elements.",
        discussion: """
            Returns the number of elements matching the selector.

            Examples:
              iosef count --role AXButton
              iosef count --name "Row"
            """
    )

    @OptionGroup var common: CommonOptions
    @OptionGroup var selector: SelectorOptions

    func run() async throws {
        var args = selector.toArguments()
        common.addDevice(to: &args)
        try await runToolCLI(toolName: "count", arguments: args, json: common.json, output: nil, verbose: common.verbose, common: common)
    }
}

struct Text: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "text",
        abstract: "Extract text from the first matching element.",
        discussion: """
            Returns the text content of the first element matching the selector. \
            Checks value, then label, then title. Errors if no element matches.

            Examples:
              iosef text --name "Tap count"
              iosef text --role AXStaticText --name "score"
            """
    )

    @OptionGroup var common: CommonOptions
    @OptionGroup var selector: SelectorOptions

    func run() async throws {
        var args = selector.toArguments()
        common.addDevice(to: &args)
        try await runToolCLI(toolName: "text", arguments: args, json: common.json, output: nil, verbose: common.verbose, common: common)
    }
}

struct TapElement: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tap_element",
        abstract: "Find an element by selector and tap it.",
        discussion: """
            Searches the accessibility tree for the first matching element and taps \
            its center. Combines find + tap into one step. Errors if no match.

            For long-press, pass --duration (in seconds).

            Examples:
              iosef tap_element --name "Sign In"
              iosef tap_element --role AXButton --name "Submit"
              iosef tap_element --name "Menu" --duration 0.5
            """
    )

    @OptionGroup var common: CommonOptions
    @OptionGroup var selector: SelectorOptions

    @Option(name: .long, help: "Press duration in seconds (for long-press)")
    var duration: Double?

    func run() async throws {
        var args = selector.toArguments()
        if let duration { args["duration"] = .double(duration) }
        common.addDevice(to: &args)
        try await runToolCLI(toolName: "tap_element", arguments: args, json: common.json, output: nil, verbose: common.verbose, common: common)
    }
}

struct Input: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "input",
        abstract: "Find an element, tap it, then type text.",
        discussion: """
            Searches for an element by selector, taps its center to focus, \
            waits briefly for the keyboard, then types the given text. \
            Combines find + tap + type into one step.

            Examples:
              iosef input --role AXTextField --text "hello"
              iosef input --name "Search" --text "query"
            """
    )

    @OptionGroup var common: CommonOptions
    @OptionGroup var selector: SelectorOptions

    @Option(name: .long, help: "Text to type after tapping the element")
    var text: String

    func run() async throws {
        var args = selector.toArguments()
        args["text"] = .string(text)
        common.addDevice(to: &args)
        try await runToolCLI(toolName: "input", arguments: args, json: common.json, output: nil, verbose: common.verbose, common: common)
    }
}

struct Wait: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wait",
        abstract: "Wait for an element matching the selector to appear.",
        discussion: """
            Polls the accessibility tree until a matching element appears \
            or the timeout expires. Default timeout is 10 seconds.

            Returns the matched element on success, or exits with an error \
            on timeout.

            Examples:
              iosef wait --name "Welcome"
              iosef wait --role AXButton --name "Continue" --timeout 5
            """
    )

    @OptionGroup var common: CommonOptions
    @OptionGroup var selector: SelectorOptions

    @Option(name: .long, help: "Maximum seconds to wait (default 10)")
    var timeout: Double?

    func run() async throws {
        var args = selector.toArguments()
        if let timeout { args["timeout"] = .double(timeout) }
        common.addDevice(to: &args)
        try await runToolCLI(toolName: "wait", arguments: args, json: common.json, output: nil, verbose: common.verbose, common: common)
    }
}

// MARK: - Log CLI subcommands

struct LogShow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "log_show",
        abstract: "Show recent simulator log entries.",
        discussion: """
            Reads the simulator's unified log via 'xcrun simctl spawn <udid> log show'. \
            Filter by process name or NSPredicate. Default: last 5 minutes, compact style.

            Examples:
              iosef log_show --process SpringBoard --last 5s
              iosef log_show --predicate 'subsystem == "com.apple.UIKit"' --last 3s
              iosef log_show --level debug --last 1m
            """
    )

    @OptionGroup var common: CommonOptions

    @Option(name: .long, help: "Time range to show (e.g. '5m', '1h', '30s'). Default: '5m'")
    var last: String?

    @Option(name: .long, help: "NSPredicate filter (mutually exclusive with --process)")
    var predicate: String?

    @Option(name: .long, help: "Process name filter (mutually exclusive with --predicate)")
    var process: String?

    @Option(name: .long, help: "Output style: compact (default), json, ndjson, syslog")
    var style: String?

    @Option(name: .long, help: "Log level: info or debug")
    var level: String?

    func run() async throws {
        var args: [String: Value] = [:]
        common.addDevice(to: &args)
        if let last { args["last"] = .string(last) }
        if let predicate { args["predicate"] = .string(predicate) }
        if let process { args["process"] = .string(process) }
        if let style { args["style"] = .string(style) }
        if let level { args["level"] = .string(level) }
        try await runToolCLI(toolName: "log_show", arguments: args, json: common.json, output: nil, verbose: common.verbose, common: common)
    }
}

struct LogStream: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "log_stream",
        abstract: "Stream live simulator log entries.",
        discussion: """
            Streams the simulator's unified log for a fixed duration via \
            'xcrun simctl spawn <udid> log stream --timeout'. \
            Filter by process name or NSPredicate. Default: 5 seconds, compact style.

            Examples:
              iosef log_stream --process SpringBoard --duration 3
              iosef log_stream --predicate 'process == "MyApp"' --duration 10
              iosef log_stream --level info --duration 5
            """
    )

    @OptionGroup var common: CommonOptions

    @Option(name: .long, help: "Seconds to stream (1-30, default: 5)")
    var duration: Int?

    @Option(name: .long, help: "NSPredicate filter (mutually exclusive with --process)")
    var predicate: String?

    @Option(name: .long, help: "Process name filter (mutually exclusive with --predicate)")
    var process: String?

    @Option(name: .long, help: "Output style: compact (default), json, ndjson, syslog")
    var style: String?

    @Option(name: .long, help: "Log level: info or debug")
    var level: String?

    func run() async throws {
        var args: [String: Value] = [:]
        common.addDevice(to: &args)
        if let duration { args["duration"] = .double(Double(duration)) }
        if let predicate { args["predicate"] = .string(predicate) }
        if let process { args["process"] = .string(process) }
        if let style { args["style"] = .string(style) }
        if let level { args["level"] = .string(level) }
        try await runToolCLI(toolName: "log_stream", arguments: args, json: common.json, output: nil, verbose: common.verbose, common: common)
    }
}
