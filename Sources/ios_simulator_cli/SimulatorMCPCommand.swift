import ArgumentParser
import Foundation
import MCP
import SimulatorKit

// MARK: - Async timeout utility

/// Races a synchronous operation against a GCD timer. Uses DispatchQueue (not the
/// Swift cooperative thread pool) so the timeout fires even when the operation blocks
/// a thread on a synchronous ObjC call that can't be cancelled.
func log(_ msg: String) {
    guard verboseLogging else { return }
    let ts = String(format: "%.3f", CFAbsoluteTimeGetCurrent())
    FileHandle.standardError.write(Data("[ios_simulator_cli \(ts)] \(msg)\n".utf8))
}

func withTimeout<T: Sendable>(
    _ label: String = "op",
    _ timeout: Duration,
    _ operation: @escaping @Sendable () throws -> T
) async throws -> T {
    let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
    return try await withCheckedThrowingContinuation { continuation in
        let lock = NSLock()
        nonisolated(unsafe) var resumed = false
        let start = CFAbsoluteTimeGetCurrent()

        let resume: @Sendable (Result<T, Error>) -> Void = { result in
            lock.lock()
            guard !resumed else { lock.unlock(); return }
            resumed = true
            lock.unlock()
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            switch result {
            case .success:
                log("withTimeout(\(label)): ok in \(Int(elapsed * 1000))ms")
            case .failure(let error):
                log("withTimeout(\(label)): failed after \(Int(elapsed * 1000))ms: \(error)")
            }
            continuation.resume(with: result)
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try operation()
                resume(.success(result))
            } catch {
                resume(.failure(error))
            }
        }

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) {
            resume(.failure(TimeoutError.accessibilityTimedOut(timeoutSeconds: seconds)))
        }
    }
}

// MARK: - Configuration

let serverVersion = "3.0.0"
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
    return Double(value, strict: false)
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
/// Device info (UDID + name) is cached both in-memory (for MCP server mode)
/// and on disk at /tmp (for CLI mode, where each invocation is a fresh process).
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

    // MARK: - Filesystem device cache

    /// Resolves device UDID, checking (in order):
    /// 1. Explicit udid parameter
    /// 2. In-memory cache (for MCP server mode)
    /// 3. Filesystem cache at /tmp (for CLI mode)
    /// 4. Direct CoreSimulator API call
    func resolveDeviceID(_ udid: String?) throws -> String {
        if let udid = udid { return udid }

        let now = ContinuousClock.now
        if let cached = deviceCache,
           now - cached.timestamp < deviceTTL {
            return cached.udid
        }

        // Try filesystem cache (survives across CLI invocations)
        if let fsDevice = Self.readDeviceCacheFromDisk() {
            deviceCache = DeviceCache(udid: fsDevice.udid, name: fsDevice.name, timestamp: now)
            return fsDevice.udid
        }

        let device = try SimCtlClient.resolveDevice(nil)
        deviceCache = DeviceCache(udid: device.udid, name: device.name, timestamp: now)
        Self.writeDeviceCacheToDisk(udid: device.udid, name: device.name)
        return device.udid
    }

    /// Cache file path, keyed by the default device name so different projects
    /// don't collide if they target different simulators.
    private static var diskCachePath: String {
        let key = SimCtlClient.defaultDeviceName ?? "default"
        return "/tmp/ios-sim-mcp-device-\(key).json"
    }

    private static let diskCacheTTL: TimeInterval = 30

    private struct DiskDeviceCache: Codable {
        let udid: String
        let name: String?
    }

    private static func readDeviceCacheFromDisk() -> DiskDeviceCache? {
        let path = diskCachePath
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return nil }

        // Check mtime for TTL
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(mtime) < diskCacheTTL else {
            return nil
        }

        guard let data = fm.contents(atPath: path),
              let cached = try? JSONDecoder().decode(DiskDeviceCache.self, from: data) else {
            return nil
        }
        return cached
    }

    private static func writeDeviceCacheToDisk(udid: String, name: String?) {
        let cached = DiskDeviceCache(udid: udid, name: name)
        guard let data = try? JSONEncoder().encode(cached) else { return }
        FileManager.default.createFile(atPath: diskCachePath, contents: data)
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

    func invalidate() {
        deviceCache = nil
        axpBridges.removeAll()
        hidClients.removeAll()
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

enum MCPToolError: Error, LocalizedError {
    case simulatorNotRunning

    var errorDescription: String? {
        switch self {
        case .simulatorNotRunning:
            return "iOS Simulator is not running"
        }
    }
}

// MARK: - Tool definitions (for MCP server mode)

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

    if !isFiltered("describe_all") {
        tools.append(Tool(
            name: "describe_all",
            description: "Describes accessibility information for the entire screen in the iOS Simulator. Coordinates are (center±half-size) in iOS points — the center value is the tap target.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "udid": udidSchema,
                ]),
            ])
        ))
    }

    if !isFiltered("describe_point") {
        tools.append(Tool(
            name: "describe_point",
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

    if !isFiltered("tap") {
        tools.append(Tool(
            name: "tap",
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

    if !isFiltered("type") {
        tools.append(Tool(
            name: "type",
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

    if !isFiltered("swipe") {
        tools.append(Tool(
            name: "swipe",
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

    if !isFiltered("view") {
        tools.append(Tool(
            name: "view",
            description: "Get the image content of a compressed screenshot of the current simulator view",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "output_path": .object([
                        "type": .string("string"),
                        "maxLength": .int(1024),
                        "description": .string("Optional file path to save screenshot to. If provided, saves to file instead of returning base64 image data."),
                    ]),
                    "type": .object([
                        "type": .string("string"),
                        "enum": .array([.string("png"), .string("tiff"), .string("bmp"), .string("gif"), .string("jpeg")]),
                        "description": .string("Image format when saving to file. Default is png."),
                    ]),
                    "udid": udidSchema,
                ]),
            ])
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

// MARK: - Tool call dispatch (used by both MCP server and CLI subcommands)

func handleToolCall(_ params: CallTool.Parameters) async -> CallTool.Result {
    do {
        switch params.name {
        case "get_booted_sim_id":
            return try await handleGetBootedSimID()
        case "open_simulator":
            return try await handleOpenSimulator()
        case "describe_all":
            return try await handleUIDescribeAll(params)
        case "describe_point":
            return try await handleUIDescribePoint(params)
        case "tap":
            return try await handleUITap(params)
        case "type":
            return try await handleUIType(params)
        case "swipe":
            return try await handleUISwipe(params)
        case "view":
            return try await handleUIView(params)
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
    let device = try SimCtlClient.getBootedDevice()
    return .init(content: [.text("Booted Simulator: \"\(device.name)\". UUID: \"\(device.udid)\"")])
}

func handleOpenSimulator() async throws -> CallTool.Result {
    _ = try await SimCtlClient.run("/usr/bin/open", arguments: ["-a", "Simulator.app"])
    return .init(content: [.text("Simulator.app opened successfully")])
}

func handleUIDescribeAll(_ params: CallTool.Parameters) async throws -> CallTool.Result {
    let udid = try await SimulatorCache.shared.resolveDeviceID(params.arguments?["udid"]?.stringValue)
    let axpBridge = try await SimulatorCache.shared.getAXPBridge(udid: udid)

    let markdown = try await withTimeout("describe_all", .seconds(12)) {
        let nodes = try axpBridge.accessibilityElements()
        return TreeSerializer.toMarkdown(nodes)
    }
    return .init(content: [.text(markdown)])
}

func handleUIDescribePoint(_ params: CallTool.Parameters) async throws -> CallTool.Result {
    let udid = try await SimulatorCache.shared.resolveDeviceID(params.arguments?["udid"]?.stringValue)

    guard let x = extractDouble(params.arguments?["x"]),
          let y = extractDouble(params.arguments?["y"]) else {
        return .init(content: [.text("Missing required parameters: x, y")], isError: true)
    }

    let axpBridge = try await SimulatorCache.shared.getAXPBridge(udid: udid)

    let markdown = try await withTimeout("describe_point", .seconds(12)) {
        let node = try axpBridge.accessibilityElementAtPoint(x: x, y: y)
        return TreeSerializer.toMarkdown(node)
    }
    return .init(content: [.text(markdown)])
}

func handleUITap(_ params: CallTool.Parameters) async throws -> CallTool.Result {
    guard let x = extractDouble(params.arguments?["x"]),
          let y = extractDouble(params.arguments?["y"]) else {
        return .init(content: [.text("Missing required parameters: x, y")], isError: true)
    }

    let udid = try await SimulatorCache.shared.resolveDeviceID(params.arguments?["udid"]?.stringValue)
    let hidClient = try await SimulatorCache.shared.getHIDClient(udid: udid)

    if let duration = extractDouble(params.arguments?["duration"]) {
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

    let durationSeconds = extractDouble(params.arguments?["duration"])

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

    // If output_path is provided, save to file instead of returning base64
    if let outputPath = params.arguments?["output_path"]?.stringValue {
        let absolutePath = ensureAbsolutePath(outputPath)
        let format = params.arguments?["type"]?.stringValue ?? "png"
        try ScreenCapture.captureToFile(udid: udid, outputPath: absolutePath, format: format)
        return .init(content: [.text("Screenshot saved to \(absolutePath)")])
    }

    // Default: return base64 image data
    let screenScale = try await SimulatorCache.shared.getScreenScale(udid: udid)
    let capture = try ScreenCapture.captureSimulator(udid: udid, screenScale: screenScale)

    return .init(content: [
        .image(data: capture.base64, mimeType: "image/jpeg", metadata: nil),
        .text("Screenshot captured"),
    ])
}

func handleInstallApp(_ params: CallTool.Parameters) async throws -> CallTool.Result {
    let udid = try SimCtlClient.resolveDeviceID(params.arguments?["udid"]?.stringValue)

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

    let bridge = PrivateFrameworkBridge.shared
    let device = try bridge.lookUpDevice(udid: udid)
    try bridge.installApp(device: device, appURL: URL(fileURLWithPath: absolutePath))

    return .init(content: [.text("App installed successfully from: \(absolutePath)")])
}

func handleLaunchApp(_ params: CallTool.Parameters) async throws -> CallTool.Result {
    let udid = try SimCtlClient.resolveDeviceID(params.arguments?["udid"]?.stringValue)

    guard let bundleID = params.arguments?["bundle_id"]?.stringValue else {
        return .init(content: [.text("Missing required parameter: bundle_id")], isError: true)
    }

    let terminateExisting: Bool
    if let terminateValue = params.arguments?["terminate_running"], Bool(terminateValue) == true {
        terminateExisting = true
    } else {
        terminateExisting = false
    }

    let bridge = PrivateFrameworkBridge.shared
    let device = try bridge.lookUpDevice(udid: udid)
    let pid = try bridge.launchApp(device: device, bundleID: bundleID, terminateExisting: terminateExisting)

    return .init(content: [.text("App \(bundleID) launched successfully with PID: \(pid)")])
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

// MARK: - Setup

func setupGlobals() {
    SimCtlClient.defaultDeviceName = computeDefaultDeviceName()

    if let timeoutStr = ProcessInfo.processInfo.environment["IOS_SIMULATOR_MCP_TIMEOUT"],
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

    @Option(name: .long, help: "Simulator UDID (auto-detected if omitted)")
    var udid: String? = nil
}

// MARK: - Shared CLI output helper

/// Runs a tool via handleToolCall and formats the result for terminal output.
/// Used by all CLI subcommands to avoid duplicating output logic.
func runToolCLI(toolName: String, arguments: [String: Value], json: Bool, output: String?, verbose: Bool = false) async throws {
    verboseLogging = verbose
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
                if let outputPath = output {
                    let path = ensureAbsolutePath(outputPath)
                    guard let imageData = Data(base64Encoded: data) else {
                        fputs("Error: failed to decode base64 image data\n", stderr)
                        continue
                    }
                    try imageData.write(to: URL(fileURLWithPath: path))
                    print("Image (\(mimeType)) saved to \(path)")
                } else {
                    // CLI mode: save to temp file instead of printing base64
                    let timestamp = Int(Date().timeIntervalSince1970)
                    let ext = mimeType.split(separator: "/").last.map(String.init) ?? "jpg"
                    let tempPath = "/tmp/ios_sim_screenshot_\(timestamp).\(ext)"
                    guard let imageData = Data(base64Encoded: data) else {
                        fputs("Error: failed to decode base64 image data\n", stderr)
                        continue
                    }
                    try imageData.write(to: URL(fileURLWithPath: tempPath))
                    print(tempPath)
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
        commandName: "ios_simulator_cli",
        abstract: "Control iOS Simulator — tap, type, swipe, inspect, and screenshot.",
        discussion: """
            Tap, type, swipe, inspect accessibility elements, and capture screenshots \
            in iOS Simulator. Runs as a standalone CLI or as an MCP server (stdio \
            transport) for agent integration.

            Coordinates:
              All commands use iOS points. The accessibility tree reports positions as
              (center±half-size) — the center value is the tap target. Screenshots are
              coordinate-aligned: 1 pixel = 1 iOS point.

            Device Resolution:
              When --udid is omitted, the CLI auto-detects the booted simulator. If
              multiple simulators are booted, pass --udid explicitly. The IDB_UDID
              environment variable is also respected as a fallback.

            Environment Variables:
              IDB_UDID                                  Fallback simulator UDID.
              IOS_SIMULATOR_MCP_DEFAULT_DEVICE_NAME     Override auto-detected device name.
              IOS_SIMULATOR_MCP_DEFAULT_OUTPUT_DIR      Default directory for screenshots.
              IOS_SIMULATOR_MCP_TIMEOUT                 Override default timeout (seconds).
              IOS_SIMULATOR_MCP_FILTERED_TOOLS          Comma-separated tools to hide from MCP.

            Example:
              # See which simulator is booted
              ios_simulator_cli get_booted_sim_id

              # Inspect the UI
              ios_simulator_cli describe_all

              # Tap a button discovered at (195, 420)
              ios_simulator_cli tap --x 195 --y 420

              # Type into the now-focused text field
              ios_simulator_cli type --text "hello world"

              # Take a screenshot
              ios_simulator_cli view --output /tmp/screen.png

              # Swipe up to scroll
              ios_simulator_cli swipe --x-start 200 --y-start 600 --x-end 200 --y-end 200

              See 'ios_simulator_cli help <subcommand>' for detailed help.
            """,
        version: serverVersion,
        subcommands: [
            MCPServe.self,
            GetBootedSimID.self,
            OpenSimulator.self,
            UIDescribeAll.self,
            UIDescribePoint.self,
            UITap.self,
            UIType.self,
            UISwipe.self,
            UIView.self,
            InstallApp.self,
            LaunchApp.self,
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
            name: "ios-simulator",
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

struct GetBootedSimID: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get_booted_sim_id",
        abstract: "Get the UDID of the currently booted simulator.",
        discussion: """
            Queries CoreSimulator for the booted device. Returns the device name and UUID. \
            Useful for verifying which simulator is active before running other commands.

            Examples:
              ios_simulator_cli get_booted_sim_id
              ios_simulator_cli get_booted_sim_id --json
            """
    )

    @OptionGroup var common: CommonOptions

    func run() async throws {
        try await runToolCLI(toolName: "get_booted_sim_id", arguments: [:], json: common.json, output: nil, verbose: common.verbose)
    }
}

struct OpenSimulator: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open_simulator",
        abstract: "Launch the Simulator.app.",
        discussion: """
            Opens the iOS Simulator application if it's not already running. \
            Run this before other commands if the simulator isn't open.

            Examples:
              ios_simulator_cli open_simulator
            """
    )

    @OptionGroup var common: CommonOptions

    func run() async throws {
        try await runToolCLI(toolName: "open_simulator", arguments: [:], json: common.json, output: nil, verbose: common.verbose)
    }
}

struct UIDescribeAll: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "describe_all",
        abstract: "Dump the full accessibility tree.",
        discussion: """
            Returns an indented text tree of every accessibility element on screen, \
            including roles, labels, frames, and values. Use this to discover element \
            positions for tap, or to understand the current UI state.

            Coordinates are (center±half-size) in iOS points — the center value is the tap target.

            Use --json for machine-readable output. Combine with jq to filter:

            Examples:
              ios_simulator_cli describe_all
              ios_simulator_cli describe_all --json
              ios_simulator_cli describe_all --json | jq '.. | objects | select(.role == "button")'
              ios_simulator_cli describe_all --json | jq '.. | objects | select(.label? // "" | test("Sign"))'
            """
    )

    @OptionGroup var common: CommonOptions

    func run() async throws {
        var args: [String: Value] = [:]
        if let udid = common.udid { args["udid"] = .string(udid) }
        try await runToolCLI(toolName: "describe_all", arguments: args, json: common.json, output: nil, verbose: common.verbose)
    }
}

struct UIDescribePoint: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "describe_point",
        abstract: "Get the accessibility element at (x, y).",
        discussion: """
            Returns the accessibility element at the given coordinates. Useful for \
            identifying what's at a specific point on screen.

            Coordinates are (center±half-size) in iOS points — the center value is the tap target.

            Examples:
              ios_simulator_cli describe_point --x 200 --y 400
              ios_simulator_cli describe_point --x 200 --y 400 --json
              ios_simulator_cli describe_point --x 200 --y 400 --json | jq '.content[0].text'
            """
    )

    @OptionGroup var common: CommonOptions

    @Option(name: .long, help: "The x-coordinate")
    var x: Double

    @Option(name: .long, help: "The y-coordinate")
    var y: Double

    func run() async throws {
        var args: [String: Value] = ["x": .double(x), "y": .double(y)]
        if let udid = common.udid { args["udid"] = .string(udid) }
        try await runToolCLI(toolName: "describe_point", arguments: args, json: common.json, output: nil, verbose: common.verbose)
    }
}

struct UITap: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tap",
        abstract: "Tap at (x, y) coordinates on the iOS Simulator screen.",
        discussion: """
            Sends a HID touch event directly to the simulator (no simctl overhead). \
            Coordinates are in iOS points. Use describe_all to find element positions.

            For long-press, pass --duration (in seconds).

            Examples:
              ios_simulator_cli tap --x 200 --y 400
              ios_simulator_cli tap --x 100 --y 300 --duration 0.5
            """
    )

    @OptionGroup var common: CommonOptions

    @Option(name: .long, help: "The x-coordinate")
    var x: Double

    @Option(name: .long, help: "The y-coordinate")
    var y: Double

    @Option(name: .long, help: "Press duration in seconds")
    var duration: Double?

    func run() async throws {
        var args: [String: Value] = ["x": .double(x), "y": .double(y)]
        if let duration { args["duration"] = .double(duration) }
        if let udid = common.udid { args["udid"] = .string(udid) }
        try await runToolCLI(toolName: "tap", arguments: args, json: common.json, output: nil, verbose: common.verbose)
    }
}

struct UIType: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "type",
        abstract: "Type text into the focused field.",
        discussion: """
            Sends keyboard HID events to type text into whatever field currently has \
            focus in the simulator. Only printable ASCII characters (0x20-0x7E) are supported.

            Tap a text field first with tap to ensure it has focus.

            Examples:
              ios_simulator_cli type --text hello
              ios_simulator_cli type --text "Hello World"
            """
    )

    @OptionGroup var common: CommonOptions

    @Option(name: .long, help: "Text to input")
    var text: String

    func run() async throws {
        var args: [String: Value] = ["text": .string(text)]
        if let udid = common.udid { args["udid"] = .string(udid) }
        try await runToolCLI(toolName: "type", arguments: args, json: common.json, output: nil, verbose: common.verbose)
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
              ios_simulator_cli swipe --x-start 200 --y-start 600 --x-end 200 --y-end 200
              ios_simulator_cli swipe --x-start 200 --y-start 600 --x-end 200 --y-end 200 --duration 0.3
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
        if let udid = common.udid { args["udid"] = .string(udid) }
        try await runToolCLI(toolName: "swipe", arguments: args, json: common.json, output: nil, verbose: common.verbose)
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

            The screenshot is coordinate-aligned with tap and describe_all — \
            pixels correspond to iOS points.

            Examples:
              ios_simulator_cli view
              ios_simulator_cli view --output /tmp/screen.jpg
              ios_simulator_cli view --output /tmp/screen.png --type png
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
        if let udid = common.udid { args["udid"] = .string(udid) }
        try await runToolCLI(toolName: "view", arguments: args, json: common.json, output: output, verbose: common.verbose)
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
              ios_simulator_cli install_app --app-path /path/to/MyApp.app
              ios_simulator_cli install_app --app-path ./build/MyApp.app
            """
    )

    @OptionGroup var common: CommonOptions

    @Option(name: .customLong("app-path"), help: "Path to the app bundle (.app directory or .ipa file) to install")
    var appPath: String

    func run() async throws {
        var args: [String: Value] = ["app_path": .string(appPath)]
        if let udid = common.udid { args["udid"] = .string(udid) }
        try await runToolCLI(toolName: "install_app", arguments: args, json: common.json, output: nil, verbose: common.verbose)
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
              ios_simulator_cli launch_app --bundle-id com.apple.mobilesafari
              ios_simulator_cli launch_app --bundle-id com.example.myapp --terminate-running
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
        if let udid = common.udid { args["udid"] = .string(udid) }
        try await runToolCLI(toolName: "launch_app", arguments: args, json: common.json, output: nil, verbose: common.verbose)
    }
}
