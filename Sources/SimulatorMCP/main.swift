import Foundation
import MCP
import SimulatorKit

// MARK: - Configuration

let serverVersion = "2.0.0"
let filteredTools: Set<String> = {
    guard let env = ProcessInfo.processInfo.environment["IOS_SIMULATOR_MCP_FILTERED_TOOLS"] else {
        return []
    }
    return Set(env.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
}()

func isFiltered(_ name: String) -> Bool {
    filteredTools.contains(name)
}

// MARK: - Value extraction helpers

/// Extracts a Double from a Value, handling both .int and .double cases.
func extractDouble(_ value: Value?) -> Double? {
    guard let value = value else { return nil }
    return Double(value)
}

// MARK: - UDID Schema (reused across tools)

let udidSchema: Value = .object([
    "type": .string("string"),
    "description": .string("Udid of target, can also be set with the IDB_UDID env var"),
    "pattern": .string(#"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#),
])

// MARK: - Path helpers

func ensureAbsolutePath(_ filePath: String) -> String {
    if filePath.hasPrefix("/") { return filePath }

    if filePath.hasPrefix("~/") {
        return NSHomeDirectory() + "/" + String(filePath.dropFirst(2))
    }

    var defaultDir = NSHomeDirectory() + "/Downloads"
    if let customDir = ProcessInfo.processInfo.environment["IOS_SIMULATOR_MCP_DEFAULT_OUTPUT_DIR"] {
        if customDir.hasPrefix("~/") {
            defaultDir = NSHomeDirectory() + "/" + String(customDir.dropFirst(2))
        } else {
            defaultDir = customDir
        }
    }

    return defaultDir + "/" + filePath
}

// MARK: - Simulator cache

/// Caches device info, AXP accessibility bridge, and HID clients.
/// Device info (UDID + name) is cached for 60s. The AXPAccessibilityBridge
/// is cached per UDID (it holds a SimDevice reference).
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

    private let deviceTTL: Duration = .seconds(60)

    /// Resolves device UDID, using cache when possible.
    /// Delegates to SimCtlClient.resolveDeviceID which checks:
    /// 1. Explicit udid parameter
    /// 2. Default device by name (from VCS root)
    /// 3. First booted simulator
    func resolveDeviceID(_ udid: String?) async throws -> String {
        if let udid = udid { return udid }

        let now = ContinuousClock.now
        if let cached = deviceCache,
           now - cached.timestamp < deviceTTL {
            return cached.udid
        }

        let resolvedUdid = try await SimCtlClient.resolveDeviceID(nil)
        let name = try await SimCtlClient.getDeviceName(udid: resolvedUdid)
        deviceCache = DeviceCache(udid: resolvedUdid, name: name, timestamp: now)
        return resolvedUdid
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

    func invalidate() {
        deviceCache = nil
        axpBridges.removeAll()
        hidClients.removeAll()
    }
}

enum MCPToolError: Error, LocalizedError {
    case simulatorNotRunning

    var errorDescription: String? {
        switch self {
        case .simulatorNotRunning:
            return "iOS Simulator is not running"
        }
    }
}

// MARK: - Tool definitions

func allTools() -> [Tool] {
    var tools: [Tool] = []

    if !isFiltered("get_booted_sim_id") {
        tools.append(Tool(
            name: "get_booted_sim_id",
            description: "Get the ID of the currently booted iOS simulator",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])])
        ))
    }

    if !isFiltered("open_simulator") {
        tools.append(Tool(
            name: "open_simulator",
            description: "Opens the iOS Simulator application",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])])
        ))
    }

    if !isFiltered("ui_describe_all") {
        tools.append(Tool(
            name: "ui_describe_all",
            description: "Describes accessibility information for the entire screen in the iOS Simulator",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "udid": udidSchema,
                ]),
            ])
        ))
    }

    if !isFiltered("ui_describe_point") {
        tools.append(Tool(
            name: "ui_describe_point",
            description: "Returns the accessibility element at given co-ordinates on the iOS Simulator's screen",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "x": .object(["type": .string("number"), "description": .string("The x-coordinate")]),
                    "y": .object(["type": .string("number"), "description": .string("The y-coordinate")]),
                    "udid": udidSchema,
                ]),
                "required": .array([.string("x"), .string("y")]),
            ])
        ))
    }

    if !isFiltered("ui_tap") {
        tools.append(Tool(
            name: "ui_tap",
            description: "Tap on the screen in the iOS Simulator",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "x": .object(["type": .string("number"), "description": .string("The x-coordinate")]),
                    "y": .object(["type": .string("number"), "description": .string("The y-coordinate")]),
                    "duration": .object([
                        "type": .string("string"),
                        "description": .string("Press duration"),
                        "pattern": .string(#"^\d+(\.\d+)?$"#),
                    ]),
                    "udid": udidSchema,
                ]),
                "required": .array([.string("x"), .string("y")]),
            ])
        ))
    }

    if !isFiltered("ui_type") {
        tools.append(Tool(
            name: "ui_type",
            description: "Input text into the iOS Simulator",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "text": .object([
                        "type": .string("string"),
                        "description": .string("Text to input"),
                        "maxLength": .int(500),
                        "pattern": .string(#"^[\x20-\x7E]+$"#),
                    ]),
                    "udid": udidSchema,
                ]),
                "required": .array([.string("text")]),
            ])
        ))
    }

    if !isFiltered("ui_swipe") {
        tools.append(Tool(
            name: "ui_swipe",
            description: "Swipe on the screen in the iOS Simulator",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "x_start": .object(["type": .string("number"), "description": .string("The starting x-coordinate")]),
                    "y_start": .object(["type": .string("number"), "description": .string("The starting y-coordinate")]),
                    "x_end": .object(["type": .string("number"), "description": .string("The ending x-coordinate")]),
                    "y_end": .object(["type": .string("number"), "description": .string("The ending y-coordinate")]),
                    "delta": .object([
                        "type": .string("number"),
                        "description": .string("The size of each step in the swipe (default is 1)"),
                    ]),
                    "duration": .object([
                        "type": .string("string"),
                        "description": .string("Swipe duration in seconds (e.g., 0.1)"),
                        "pattern": .string(#"^\d+(\.\d+)?$"#),
                    ]),
                    "udid": udidSchema,
                ]),
                "required": .array([.string("x_start"), .string("y_start"), .string("x_end"), .string("y_end")]),
            ])
        ))
    }

    if !isFiltered("ui_view") {
        tools.append(Tool(
            name: "ui_view",
            description: "Get the image content of a compressed screenshot of the current simulator view",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "udid": udidSchema,
                ]),
            ])
        ))
    }

    if !isFiltered("screenshot") {
        tools.append(Tool(
            name: "screenshot",
            description: "Takes a screenshot of the iOS Simulator",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "output_path": .object([
                        "type": .string("string"),
                        "maxLength": .int(1024),
                        "description": .string("File path where the screenshot will be saved"),
                    ]),
                    "type": .object([
                        "type": .string("string"),
                        "enum": .array([.string("png"), .string("tiff"), .string("bmp"), .string("gif"), .string("jpeg")]),
                        "description": .string("Image format. Default is png."),
                    ]),
                    "display": .object([
                        "type": .string("string"),
                        "enum": .array([.string("internal"), .string("external")]),
                        "description": .string("Display to capture (internal or external)."),
                    ]),
                    "mask": .object([
                        "type": .string("string"),
                        "enum": .array([.string("ignored"), .string("alpha"), .string("black")]),
                        "description": .string("For non-rectangular displays, handle the mask by policy"),
                    ]),
                    "udid": udidSchema,
                ]),
                "required": .array([.string("output_path")]),
            ])
        ))
    }

    if !isFiltered("record_video") {
        tools.append(Tool(
            name: "record_video",
            description: "Records a video of the iOS Simulator",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "output_path": .object([
                        "type": .string("string"),
                        "maxLength": .int(1024),
                        "description": .string("Optional output path for the recording"),
                    ]),
                    "codec": .object([
                        "type": .string("string"),
                        "enum": .array([.string("h264"), .string("hevc")]),
                        "description": .string("Codec type. Default is hevc."),
                    ]),
                    "display": .object([
                        "type": .string("string"),
                        "enum": .array([.string("internal"), .string("external")]),
                        "description": .string("Display to capture."),
                    ]),
                    "mask": .object([
                        "type": .string("string"),
                        "enum": .array([.string("ignored"), .string("alpha"), .string("black")]),
                        "description": .string("Mask policy for non-rectangular displays."),
                    ]),
                    "force": .object([
                        "type": .string("boolean"),
                        "description": .string("Force overwrite if file exists."),
                    ]),
                    "udid": udidSchema,
                ]),
            ])
        ))
    }

    if !isFiltered("stop_recording") {
        tools.append(Tool(
            name: "stop_recording",
            description: "Stops the simulator video recording",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])])
        ))
    }

    if !isFiltered("install_app") {
        tools.append(Tool(
            name: "install_app",
            description: "Installs an app bundle (.app or .ipa) on the iOS Simulator",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app_path": .object([
                        "type": .string("string"),
                        "maxLength": .int(1024),
                        "description": .string("Path to the app bundle (.app directory or .ipa file) to install"),
                    ]),
                    "udid": udidSchema,
                ]),
                "required": .array([.string("app_path")]),
            ])
        ))
    }

    if !isFiltered("launch_app") {
        tools.append(Tool(
            name: "launch_app",
            description: "Launches an app on the iOS Simulator by bundle identifier",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "bundle_id": .object([
                        "type": .string("string"),
                        "maxLength": .int(256),
                        "description": .string("Bundle identifier of the app to launch (e.g., com.apple.mobilesafari)"),
                    ]),
                    "terminate_running": .object([
                        "type": .string("boolean"),
                        "description": .string("Terminate the app if it is already running before launching"),
                    ]),
                    "udid": udidSchema,
                ]),
                "required": .array([.string("bundle_id")]),
            ])
        ))
    }

    return tools
}

// MARK: - Tool call dispatch

func handleToolCall(_ params: CallTool.Parameters) async -> CallTool.Result {
    do {
        switch params.name {
        case "get_booted_sim_id":
            return try await handleGetBootedSimID()
        case "open_simulator":
            return try await handleOpenSimulator()
        case "ui_describe_all":
            return try await handleUIDescribeAll(params)
        case "ui_describe_point":
            return try await handleUIDescribePoint(params)
        case "ui_tap":
            return try await handleUITap(params)
        case "ui_type":
            return try await handleUIType(params)
        case "ui_swipe":
            return try await handleUISwipe(params)
        case "ui_view":
            return try await handleUIView(params)
        case "screenshot":
            return try await handleScreenshot(params)
        case "record_video":
            return try await handleRecordVideo(params)
        case "stop_recording":
            return try await handleStopRecording()
        case "install_app":
            return try await handleInstallApp(params)
        case "launch_app":
            return try await handleLaunchApp(params)
        default:
            return .init(content: [.text("Unknown tool: \(params.name)")], isError: true)
        }
    } catch {
        return .init(content: [.text("Error: \(error.localizedDescription)")], isError: true)
    }
}

// MARK: - Tool implementations

func handleGetBootedSimID() async throws -> CallTool.Result {
    let device = try await SimCtlClient.getBootedDevice()
    return .init(content: [.text("Booted Simulator: \"\(device.name)\". UUID: \"\(device.udid)\"")])
}

func handleOpenSimulator() async throws -> CallTool.Result {
    _ = try await SimCtlClient.run("/usr/bin/open", arguments: ["-a", "Simulator.app"])
    return .init(content: [.text("Simulator.app opened successfully")])
}

func handleUIDescribeAll(_ params: CallTool.Parameters) async throws -> CallTool.Result {
    let udid = try await SimulatorCache.shared.resolveDeviceID(params.arguments?["udid"]?.stringValue)
    let axpBridge = try await SimulatorCache.shared.getAXPBridge(udid: udid)

    let nodes = try axpBridge.accessibilityElements()
    let json = try TreeSerializer.toJSON(nodes)
    return .init(content: [.text(json)])
}

func handleUIDescribePoint(_ params: CallTool.Parameters) async throws -> CallTool.Result {
    let udid = try await SimulatorCache.shared.resolveDeviceID(params.arguments?["udid"]?.stringValue)

    guard let x = extractDouble(params.arguments?["x"]),
          let y = extractDouble(params.arguments?["y"]) else {
        return .init(content: [.text("Missing required parameters: x, y")], isError: true)
    }

    let axpBridge = try await SimulatorCache.shared.getAXPBridge(udid: udid)
    let node = try axpBridge.accessibilityElementAtPoint(x: x, y: y)
    let json = try TreeSerializer.toJSON(node)
    return .init(content: [.text(json)])
}

func handleUITap(_ params: CallTool.Parameters) async throws -> CallTool.Result {
    guard let x = extractDouble(params.arguments?["x"]),
          let y = extractDouble(params.arguments?["y"]) else {
        return .init(content: [.text("Missing required parameters: x, y")], isError: true)
    }

    let udid = try await SimulatorCache.shared.resolveDeviceID(params.arguments?["udid"]?.stringValue)
    let hidClient = try await SimulatorCache.shared.getHIDClient(udid: udid)

    if let durationStr = params.arguments?["duration"]?.stringValue,
       let duration = Double(durationStr) {
        hidClient.longPress(x: x, y: y, duration: duration)
    } else {
        hidClient.tap(x: x, y: y)
    }

    return .init(content: [.text("Tapped successfully")])
}

func handleUIType(_ params: CallTool.Parameters) async throws -> CallTool.Result {
    guard let text = params.arguments?["text"]?.stringValue else {
        return .init(content: [.text("Missing required parameter: text")], isError: true)
    }

    let udid = try await SimulatorCache.shared.resolveDeviceID(params.arguments?["udid"]?.stringValue)
    let hidClient = try await SimulatorCache.shared.getHIDClient(udid: udid)
    hidClient.typeText(text)

    return .init(content: [.text("Typed successfully")])
}

func handleUISwipe(_ params: CallTool.Parameters) async throws -> CallTool.Result {
    guard let xStart = extractDouble(params.arguments?["x_start"]),
          let yStart = extractDouble(params.arguments?["y_start"]),
          let xEnd = extractDouble(params.arguments?["x_end"]),
          let yEnd = extractDouble(params.arguments?["y_end"]) else {
        return .init(content: [.text("Missing required parameters: x_start, y_start, x_end, y_end")], isError: true)
    }

    let udid = try await SimulatorCache.shared.resolveDeviceID(params.arguments?["udid"]?.stringValue)
    let hidClient = try await SimulatorCache.shared.getHIDClient(udid: udid)

    let delta = extractDouble(params.arguments?["delta"]) ?? 1.0
    let steps = max(1, Int(20.0 / delta))

    let durationSeconds: Double?
    if let durationStr = params.arguments?["duration"]?.stringValue {
        durationSeconds = Double(durationStr)
    } else {
        durationSeconds = nil
    }

    hidClient.swipe(
        startX: xStart, startY: yStart,
        endX: xEnd, endY: yEnd,
        steps: steps,
        durationSeconds: durationSeconds
    )

    return .init(content: [.text("Swiped successfully")])
}

func handleUIView(_ params: CallTool.Parameters) async throws -> CallTool.Result {
    let udid = try await SimulatorCache.shared.resolveDeviceID(params.arguments?["udid"]?.stringValue)

    let capture = try ScreenCapture.captureSimulator(udid: udid)

    return .init(content: [
        .image(data: capture.base64, mimeType: "image/jpeg", metadata: nil),
        .text("Screenshot captured"),
    ])
}

func handleScreenshot(_ params: CallTool.Parameters) async throws -> CallTool.Result {
    let udid = try await SimCtlClient.resolveDeviceID(params.arguments?["udid"]?.stringValue)

    guard let outputPath = params.arguments?["output_path"]?.stringValue else {
        return .init(content: [.text("Missing required parameter: output_path")], isError: true)
    }

    let absolutePath = ensureAbsolutePath(outputPath)

    var args = ["simctl", "io", udid, "screenshot"]

    if let type = params.arguments?["type"]?.stringValue {
        args.append("--type=\(type)")
    }
    if let display = params.arguments?["display"]?.stringValue {
        args.append("--display=\(display)")
    }
    if let mask = params.arguments?["mask"]?.stringValue {
        args.append("--mask=\(mask)")
    }

    args.append(contentsOf: ["--", absolutePath])

    // simctl screenshot outputs success message to stderr
    let result = try await SimCtlClient.run("/usr/bin/xcrun", arguments: args)
    let output = result.stderr.isEmpty ? result.stdout : result.stderr

    return .init(content: [.text(output)])
}

func handleRecordVideo(_ params: CallTool.Parameters) async throws -> CallTool.Result {
    let defaultFileName = "simulator_recording_\(Int(Date().timeIntervalSince1970 * 1000)).mp4"
    let outputPath = ensureAbsolutePath(params.arguments?["output_path"]?.stringValue ?? defaultFileName)

    var args = ["simctl", "io", "booted", "recordVideo"]

    if let codec = params.arguments?["codec"]?.stringValue {
        args.append("--codec=\(codec)")
    }
    if let display = params.arguments?["display"]?.stringValue {
        args.append("--display=\(display)")
    }
    if let mask = params.arguments?["mask"]?.stringValue {
        args.append("--mask=\(mask)")
    }
    if let forceValue = params.arguments?["force"], Bool(forceValue) == true {
        args.append("--force")
    }

    args.append(contentsOf: ["--", outputPath])

    // Start recording as a background process
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = args
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice

    try process.run()

    // Wait briefly for recording to start
    try await Task.sleep(for: .seconds(3))

    return .init(content: [
        .text("Recording started. The video will be saved to: \(outputPath)\nTo stop recording, use the stop_recording command.")
    ])
}

func handleStopRecording() async throws -> CallTool.Result {
    _ = try await SimCtlClient.run("/usr/bin/pkill", arguments: ["-SIGINT", "-f", "simctl.*recordVideo"])

    // Wait for video to finalize
    try await Task.sleep(for: .seconds(1))

    return .init(content: [.text("Recording stopped successfully.")])
}

func handleInstallApp(_ params: CallTool.Parameters) async throws -> CallTool.Result {
    let udid = try await SimCtlClient.resolveDeviceID(params.arguments?["udid"]?.stringValue)

    guard let appPath = params.arguments?["app_path"]?.stringValue else {
        return .init(content: [.text("Missing required parameter: app_path")], isError: true)
    }

    let absolutePath: String
    if appPath.hasPrefix("/") {
        absolutePath = appPath
    } else if appPath.hasPrefix("~/") {
        absolutePath = NSHomeDirectory() + "/" + String(appPath.dropFirst(2))
    } else {
        absolutePath = FileManager.default.currentDirectoryPath + "/" + appPath
    }

    guard FileManager.default.fileExists(atPath: absolutePath) else {
        return .init(content: [.text("App bundle not found at: \(absolutePath)")], isError: true)
    }

    _ = try await SimCtlClient.simctl("install", udid, absolutePath)

    return .init(content: [.text("App installed successfully from: \(absolutePath)")])
}

func handleLaunchApp(_ params: CallTool.Parameters) async throws -> CallTool.Result {
    let udid = try await SimCtlClient.resolveDeviceID(params.arguments?["udid"]?.stringValue)

    guard let bundleID = params.arguments?["bundle_id"]?.stringValue else {
        return .init(content: [.text("Missing required parameter: bundle_id")], isError: true)
    }

    var args = ["simctl", "launch"]

    if let terminateValue = params.arguments?["terminate_running"], Bool(terminateValue) == true {
        args.append("--terminate-running-process")
    }

    args.append(contentsOf: [udid, bundleID])

    let result = try await SimCtlClient.run("/usr/bin/xcrun", arguments: args)

    // Extract PID from output if available
    if let match = result.stdout.range(of: #"^\d+"#, options: .regularExpression) {
        let pid = result.stdout[match]
        return .init(content: [.text("App \(bundleID) launched successfully with PID: \(pid)")])
    }

    return .init(content: [.text("App \(bundleID) launched successfully")])
}

// MARK: - Default device name from VCS root

/// Run a command and return trimmed stdout, or nil on failure. Times out after `timeout` (default 5s).
func runForOutput(_ executable: String, _ arguments: String..., timeout: Duration = .seconds(5)) -> String? {
    runForOutputImpl(executable, arguments: Array(arguments), timeout: timeout)
}

private func runForOutputImpl(_ executable: String, arguments: [String], timeout: Duration) -> String? {
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

    let timeoutSeconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
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
    // Explicit env var takes priority
    if let name = ProcessInfo.processInfo.environment["IOS_SIMULATOR_MCP_DEFAULT_DEVICE_NAME"] {
        return name.isEmpty ? nil : name
    }

    // Try jj root first (Jujutsu), then git
    let root = runForOutput("/usr/bin/env", "jj", "root")
             ?? runForOutput("/usr/bin/git", "rev-parse", "--show-toplevel")

    guard let root else { return nil }
    return URL(fileURLWithPath: root).lastPathComponent
}

SimCtlClient.defaultDeviceName = computeDefaultDeviceName()

// Configure global process timeout from environment
if let timeoutStr = ProcessInfo.processInfo.environment["IOS_SIMULATOR_MCP_TIMEOUT"],
   let timeoutSecs = Double(timeoutStr), timeoutSecs > 0 {
    SimCtlClient.defaultTimeout = .seconds(Int64(timeoutSecs))
}

// MARK: - Server setup

let server = Server(
    name: "ios-simulator",
    version: serverVersion,
    capabilities: .init(tools: .init(listChanged: false))
)

await server.withMethodHandler(ListTools.self) { _ in
    return .init(tools: allTools())
}

await server.withMethodHandler(CallTool.self) { params in
    return await handleToolCall(params)
}

let transport = StdioTransport()
try await server.start(transport: transport)

// Keep the process alive — StdioTransport will handle the event loop.
// If the transport closes (stdin EOF), the process should exit.
try await Task.sleep(for: .seconds(365 * 24 * 3600))
