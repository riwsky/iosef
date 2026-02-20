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
    let seconds = timeout.totalSeconds
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
    "description": .string("Name or UDID of target simulator, can also be set with the IDB_UDID env var"),
])

// MARK: - Selector schema (reused across selector-based tools)

let selectorProperties: [String: Value] = [
    "role": .object(["type": .string("string"), "description": .string("Case-insensitive exact match on accessibility role (e.g. AXButton, AXStaticText)")]),
    "name": .object(["type": .string("string"), "description": .string("Case-insensitive substring match on label or title")]),
    "identifier": .object(["type": .string("string"), "description": .string("Exact match on accessibilityIdentifier")]),
]

/// Extracts an AXSelector from MCP tool params. Throws if all selector fields are empty.
func extractSelector(from arguments: [String: Value]?) throws -> AXSelector {
    let selector = AXSelector(
        role: arguments?["role"]?.stringValue,
        name: arguments?["name"]?.stringValue,
        identifier: arguments?["identifier"]?.stringValue
    )
    guard !selector.isEmpty else {
        throw SelectorError.emptySelector
    }
    return selector
}

/// Resolves a selector against the AX tree for a given UDID.
/// Returns the selector, the full tree, and the matching nodes.
func resolveSelector(from params: CallTool.Parameters) async throws -> (selector: AXSelector, matches: [TreeNode]) {
    let selector = try extractSelector(from: params.arguments)
    let udid = try await SimulatorCache.shared.resolveDeviceID(params.arguments?["udid"]?.stringValue)
    let axpBridge = try await SimulatorCache.shared.getAXPBridge(udid: udid)

    let nodes = try await withTimeout("selector_query", .seconds(12)) {
        try axpBridge.accessibilityElements()
    }
    let matches = findNodes(matching: selector, in: nodes)
    return (selector, matches)
}

enum SelectorError: Error, LocalizedError {
    case emptySelector
    case noMatch(AXSelector)
    case noFrame(AXSelector)

    var errorDescription: String? {
        switch self {
        case .emptySelector:
            return "At least one selector field (role, name, identifier) must be provided"
        case .noMatch(let sel):
            let parts = [
                sel.role.map { "role=\($0)" },
                sel.name.map { "name=\($0)" },
                sel.identifier.map { "identifier=\($0)" },
            ].compactMap { $0 }
            return "No element found matching: \(parts.joined(separator: ", "))"
        case .noFrame(let sel):
            let parts = [
                sel.role.map { "role=\($0)" },
                sel.name.map { "name=\($0)" },
                sel.identifier.map { "identifier=\($0)" },
            ].compactMap { $0 }
            return "Element found but has no frame: \(parts.joined(separator: ", "))"
        }
    }
}

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

// MARK: - Device errors

struct DeviceNotBootedError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
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
    /// 1. Explicit identifier (UUID or simulator name)
    /// 2. In-memory cache (for MCP server mode)
    /// 3. Filesystem cache at /tmp (for CLI mode)
    /// 4. Direct CoreSimulator API call
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
            return device.udid
        }

        let now = ContinuousClock.now
        if let cached = deviceCache,
           now - cached.timestamp < deviceTTL {
            return cached.udid
        }

        // Try filesystem cache (survives across CLI invocations)
        if let fsDevice = Self.readDeviceCacheFromDisk() {
            // Validate the cached device is still booted
            let device = try SimCtlClient.resolveDevice(fsDevice.udid)
            try Self.validateBooted(device)
            deviceCache = DeviceCache(udid: fsDevice.udid, name: fsDevice.name, timestamp: now)
            return fsDevice.udid
        }

        let device = try SimCtlClient.resolveDevice(nil)
        try Self.validateBooted(device)
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
            description: "Describes accessibility information for the entire screen in the iOS Simulator. Coordinates are (center±half-size) in iOS points — the center value is the tap target. Use find for targeted queries by role, name, or identifier.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "depth": .object(["type": .string("integer"), "description": .string("Maximum tree depth to return (omit for full tree). 0 = root only, 1 = root + direct children, etc.")]),
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
            description: "Tap at (x, y) on the iOS Simulator screen. Prefer tap_element when targeting a named/accessible element.",
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
            description: "Type text into the focused field in the iOS Simulator. Prefer input to find, focus, and type in one step.",
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

    // MARK: - Selector-based tools

    let selectorSchema: [String: Value] = selectorProperties.merging(["udid": udidSchema]) { a, _ in a }

    if !isFiltered("find") {
        tools.append(Tool(
            name: "find",
            description: "Search the accessibility tree by selector (role, name, identifier). Returns matching nodes as an indented text tree.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(selectorSchema),
            ])
        ))
    }

    if !isFiltered("exists") {
        tools.append(Tool(
            name: "exists",
            description: "Check if an accessibility element matching the selector exists. Returns \"true\" or \"false\".",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(selectorSchema),
            ])
        ))
    }

    if !isFiltered("count") {
        tools.append(Tool(
            name: "count",
            description: "Count accessibility elements matching the selector.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(selectorSchema),
            ])
        ))
    }

    if !isFiltered("text") {
        tools.append(Tool(
            name: "text",
            description: "Extract the text content (value, label, or title) of the first element matching the selector.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(selectorSchema),
            ])
        ))
    }

    if !isFiltered("tap_element") {
        var tapElSchema = selectorSchema
        tapElSchema["duration"] = .object([
            "type": .string("string"),
            "description": .string("Press duration for long-press (in seconds)"),
            "pattern": .string(#"^\d+(\.\d+)?$"#),
        ])
        tools.append(Tool(
            name: "tap_element",
            description: "Find an accessibility element by selector and tap its center. Combines find + tap into one step.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(tapElSchema),
            ])
        ))
    }

    if !isFiltered("input") {
        var inputSchema = selectorSchema
        inputSchema["text"] = .object([
            "type": .string("string"),
            "description": .string("Text to type after tapping the element"),
            "maxLength": .int(500),
        ])
        tools.append(Tool(
            name: "input",
            description: "Find an element by selector, tap it to focus, then type text. Combines find + tap + type into one step.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(inputSchema),
                "required": .array([.string("text")]),
            ])
        ))
    }

    if !isFiltered("wait") {
        var waitSchema = selectorSchema
        waitSchema["timeout"] = .object([
            "type": .string("number"),
            "description": .string("Maximum seconds to wait (default 10)"),
        ])
        tools.append(Tool(
            name: "wait",
            description: "Poll the accessibility tree until an element matching the selector appears. Returns the matched element on success, or an error on timeout.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(waitSchema),
            ])
        ))
    }

    // MARK: - Log tools

    let logFilterProperties: [String: Value] = [
        "udid": udidSchema,
        "predicate": .object(["type": .string("string"), "description": .string("NSPredicate filter (e.g. 'subsystem == \"com.example\"'). Mutually exclusive with 'process'.")]),
        "process": .object(["type": .string("string"), "description": .string("Shorthand process name filter (becomes process == \"<value>\"). Mutually exclusive with 'predicate'.")]),
        "style": .object(["type": .string("string"), "enum": .array([.string("compact"), .string("json"), .string("ndjson"), .string("syslog")]), "description": .string("Output style (default: compact)")]),
        "level": .object(["type": .string("string"), "enum": .array([.string("info"), .string("debug")]), "description": .string("Include info or debug level messages (default: default level only)")]),
    ]

    if !isFiltered("log_show") {
        var logShowProps = logFilterProperties
        logShowProps["last"] = .object(["type": .string("string"), "description": .string("Time range to show (e.g. '5m', '1h', '30s'). Default: '5m'")])
        tools.append(Tool(
            name: "log_show",
            description: "Show recent log entries from the simulator's unified log. Uses 'xcrun simctl spawn <udid> log show'.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(logShowProps),
            ])
        ))
    }

    if !isFiltered("log_stream") {
        var logStreamProps = logFilterProperties
        logStreamProps["duration"] = .object(["type": .string("number"), "description": .string("Seconds to stream (1-30, default: 5)")])
        tools.append(Tool(
            name: "log_stream",
            description: "Stream live log entries from the simulator for a fixed duration. Uses 'xcrun simctl spawn <udid> log stream --timeout'.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(logStreamProps),
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
        case "find":
            return try await handleFind(params)
        case "exists":
            return try await handleExists(params)
        case "count":
            return try await handleCount(params)
        case "text":
            return try await handleText(params)
        case "tap_element":
            return try await handleTapElement(params)
        case "input":
            return try await handleInput(params)
        case "wait":
            return try await handleWait(params)
        case "log_show":
            return try await handleLogShow(params)
        case "log_stream":
            return try await handleLogStream(params)
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
    let depth = params.arguments?["depth"].flatMap({ Int($0, strict: false) })

    let markdown = try await withTimeout("describe_all", .seconds(12)) {
        let nodes = try axpBridge.accessibilityElements()
        return TreeSerializer.toMarkdown(nodes, maxDepth: depth)
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
    let udid = try await SimulatorCache.shared.resolveDeviceID(params.arguments?["udid"]?.stringValue)

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
    let udid = try await SimulatorCache.shared.resolveDeviceID(params.arguments?["udid"]?.stringValue)

    guard let bundleID = params.arguments?["bundle_id"]?.stringValue else {
        return .init(content: [.text("Missing required parameter: bundle_id")], isError: true)
    }

    let terminateExisting = params.arguments?["terminate_running"].flatMap({ Bool($0) }) ?? false

    let bridge = PrivateFrameworkBridge.shared
    let device = try bridge.lookUpDevice(udid: udid)
    let pid = try bridge.launchApp(device: device, bundleID: bundleID, terminateExisting: terminateExisting)

    return .init(content: [.text("App \(bundleID) launched successfully with PID: \(pid)")])
}

// MARK: - Selector-based tool implementations

func handleFind(_ params: CallTool.Parameters) async throws -> CallTool.Result {
    let (_, matches) = try await resolveSelector(from: params)
    if matches.isEmpty {
        return .init(content: [.text("No matching elements found")])
    }
    return .init(content: [.text(TreeSerializer.toMarkdown(matches))])
}

func handleExists(_ params: CallTool.Parameters) async throws -> CallTool.Result {
    let (_, matches) = try await resolveSelector(from: params)
    return .init(content: [.text(matches.isEmpty ? "false" : "true")])
}

func handleCount(_ params: CallTool.Parameters) async throws -> CallTool.Result {
    let (_, matches) = try await resolveSelector(from: params)
    return .init(content: [.text("\(matches.count)")])
}

func handleText(_ params: CallTool.Parameters) async throws -> CallTool.Result {
    let (selector, matches) = try await resolveSelector(from: params)
    guard let first = matches.first else {
        throw SelectorError.noMatch(selector)
    }
    let text = first.value ?? first.label ?? first.title ?? ""
    return .init(content: [.text(text)])
}

/// Resolves a selector, finds the first match, and returns its center + HID client for tapping.
func resolveAndTapFirstMatch(from params: CallTool.Parameters) async throws -> (center: (x: Double, y: Double), hidClient: IndigoHIDClient) {
    let (selector, matches) = try await resolveSelector(from: params)
    guard let first = matches.first else { throw SelectorError.noMatch(selector) }
    guard let frame = first.frame else { throw SelectorError.noFrame(selector) }
    let udid = try await SimulatorCache.shared.resolveDeviceID(params.arguments?["udid"]?.stringValue)
    let hidClient = try await SimulatorCache.shared.getHIDClient(udid: udid)
    return (frame.center, hidClient)
}

func handleTapElement(_ params: CallTool.Parameters) async throws -> CallTool.Result {
    let (center, hidClient) = try await resolveAndTapFirstMatch(from: params)

    if let duration = extractDouble(params.arguments?["duration"]) {
        hidClient.longPress(x: center.x, y: center.y, duration: duration)
    } else {
        hidClient.tap(x: center.x, y: center.y)
    }

    return .init(content: [.text("Tapped element at (\(Int(center.x)), \(Int(center.y)))")])
}

func handleInput(_ params: CallTool.Parameters) async throws -> CallTool.Result {
    guard let text = params.arguments?["text"]?.stringValue else {
        return .init(content: [.text("Missing required parameter: text")], isError: true)
    }

    let (center, hidClient) = try await resolveAndTapFirstMatch(from: params)

    hidClient.tap(x: center.x, y: center.y)
    usleep(100_000) // 100ms delay for keyboard to appear
    hidClient.typeText(text)

    return .init(content: [.text("Tapped (\(Int(center.x)), \(Int(center.y))) and typed \"\(text)\"")])
}

func handleWait(_ params: CallTool.Parameters) async throws -> CallTool.Result {
    let selector = try extractSelector(from: params.arguments)
    let timeoutSecs = extractDouble(params.arguments?["timeout"]) ?? 10.0
    let udid = try await SimulatorCache.shared.resolveDeviceID(params.arguments?["udid"]?.stringValue)
    let axpBridge = try await SimulatorCache.shared.getAXPBridge(udid: udid)

    let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int64(timeoutSecs * 1000)))

    while ContinuousClock.now < deadline {
        let nodes = try await withTimeout("wait_poll", .seconds(5)) {
            try axpBridge.accessibilityElements()
        }
        let matches = findNodes(matching: selector, in: nodes)
        if let first = matches.first {
            return .init(content: [.text(TreeSerializer.toMarkdown(first))])
        }
        try await Task.sleep(for: .milliseconds(250))
    }

    throw SelectorError.noMatch(selector)
}

// MARK: - Log tool helpers

enum LogToolError: Error, LocalizedError {
    case conflictingFilters

    var errorDescription: String? {
        switch self {
        case .conflictingFilters:
            return "Cannot specify both 'predicate' and 'process' — use one or the other"
        }
    }
}

func buildLogArguments(udid: String, subcommand: String, predicate: String?, process: String?, style: String?, level: String?, extraArgs: [String]) -> [String] {
    var args = ["/usr/bin/xcrun", "simctl", "spawn", udid, "log", subcommand]
    args += extraArgs

    if let predicate {
        args += ["--predicate", predicate]
    } else if let process {
        args += ["--predicate", "process == \"\(process)\""]
    }

    if let style {
        args += ["--style", style]
    }

    if let level {
        switch level {
        case "debug":
            args += ["--info", "--debug"]
        case "info":
            args += ["--info"]
        default:
            break
        }
    }

    return args
}

func processLogOutput(_ raw: String) -> String {
    let maxLines = 500
    var lines = raw.components(separatedBy: "\n")

    // Strip the "Filtering the log data..." preamble line
    if let first = lines.first, first.hasPrefix("Filtering the log data") {
        lines.removeFirst()
    }

    // Remove leading/trailing empty lines
    while lines.first?.isEmpty == true { lines.removeFirst() }
    while lines.last?.isEmpty == true { lines.removeLast() }

    if lines.count > maxLines {
        let truncated = Array(lines.prefix(maxLines))
        return truncated.joined(separator: "\n") + "\n\n[Truncated: showing \(maxLines) of \(lines.count) lines]"
    }

    return lines.joined(separator: "\n")
}

func handleLogShow(_ params: CallTool.Parameters) async throws -> CallTool.Result {
    let predicate = params.arguments?["predicate"]?.stringValue
    let process = params.arguments?["process"]?.stringValue
    if predicate != nil && process != nil {
        throw LogToolError.conflictingFilters
    }

    let udid = try await SimulatorCache.shared.resolveDeviceID(params.arguments?["udid"]?.stringValue)
    let last = params.arguments?["last"]?.stringValue ?? "5m"
    let style = params.arguments?["style"]?.stringValue ?? "compact"
    let level = params.arguments?["level"]?.stringValue

    let args = buildLogArguments(udid: udid, subcommand: "show", predicate: predicate, process: process, style: style, level: level, extraArgs: ["--last", last])
    let result = try await SimCtlClient.run(args[0], arguments: Array(args.dropFirst()))
    let output = processLogOutput(result.stdout)

    if output.isEmpty {
        return .init(content: [.text("No log entries found")])
    }
    return .init(content: [.text(output)])
}

func handleLogStream(_ params: CallTool.Parameters) async throws -> CallTool.Result {
    let predicate = params.arguments?["predicate"]?.stringValue
    let process = params.arguments?["process"]?.stringValue
    if predicate != nil && process != nil {
        throw LogToolError.conflictingFilters
    }

    let udid = try await SimulatorCache.shared.resolveDeviceID(params.arguments?["udid"]?.stringValue)
    let rawDuration = extractDouble(params.arguments?["duration"]) ?? 5.0
    let duration = max(1, min(30, Int(rawDuration)))
    let style = params.arguments?["style"]?.stringValue ?? "compact"
    let level = params.arguments?["level"]?.stringValue

    let args = buildLogArguments(udid: udid, subcommand: "stream", predicate: predicate, process: process, style: style, level: level, extraArgs: ["--timeout", "\(duration)"])
    let timeout = Duration.seconds(duration + 5)
    let result = try await SimCtlClient.run(args[0], arguments: Array(args.dropFirst()), timeout: timeout)
    let output = processLogOutput(result.stdout)

    if output.isEmpty {
        return .init(content: [.text("No log entries captured")])
    }
    return .init(content: [.text(output)])
}

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
    // Explicit env var takes priority
    if let name = ProcessInfo.processInfo.environment["IOS_SIMULATOR_MCP_DEFAULT_DEVICE_NAME"] {
        return name.isEmpty ? nil : name
    }

    // Try jj root first (Jujutsu), then git
    let root = runForOutput("/usr/bin/env", ["jj", "root"])
             ?? runForOutput("/usr/bin/git", ["rev-parse", "--show-toplevel"])

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

    @Option(name: [.long, .customLong("udid", withSingleDash: false)], help: "Simulator name or UDID (auto-detected if omitted)")
    var device: String? = nil

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
                guard let imageData = Data(base64Encoded: data) else {
                    fputs("Error: failed to decode base64 image data\n", stderr)
                    continue
                }
                if let outputPath = output {
                    let path = ensureAbsolutePath(outputPath)
                    try imageData.write(to: URL(fileURLWithPath: path))
                    print("Image (\(mimeType)) saved to \(path)")
                } else {
                    let timestamp = Int(Date().timeIntervalSince1970)
                    let ext = mimeType.split(separator: "/").last.map(String.init) ?? "jpg"
                    let tempPath = "/tmp/ios_sim_screenshot_\(timestamp).\(ext)"
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
              When --device is omitted, the CLI auto-detects the booted simulator. If
              multiple simulators are booted, pass --device explicitly (name or UDID).
              The IDB_UDID environment variable is also respected as a fallback.

            Environment Variables:
              IDB_UDID                                  Fallback simulator UDID.
              IOS_SIMULATOR_MCP_DEFAULT_DEVICE_NAME     Override auto-detected device name.
              IOS_SIMULATOR_MCP_DEFAULT_OUTPUT_DIR      Default directory for screenshots.
              IOS_SIMULATOR_MCP_TIMEOUT                 Override default timeout (seconds).
              IOS_SIMULATOR_MCP_FILTERED_TOOLS          Comma-separated tools to hide from MCP.

            Example — selector-based (preferred):
              # Tap a button by name
              ios_simulator_cli tap_element --name "Sign In"

              # Type into a field by role
              ios_simulator_cli input --role AXTextField --text "hello"

              # Wait for a screen to load
              ios_simulator_cli wait --name "Welcome"

              # Check if an element exists
              ios_simulator_cli exists --role AXButton --name "Submit"

            Example — coordinate-based (when elements lack labels):
              ios_simulator_cli describe_all
              ios_simulator_cli tap --x 195 --y 420
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
            Find.self,
            Exists.self,
            Count.self,
            Text.self,
            TapElement.self,
            Input.self,
            Wait.self,
            LogShow.self,
            LogStream.self,
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

            Tip: use find for targeted queries instead of scanning the full tree.

            Coordinates are (center±half-size) in iOS points — the center value is the tap target.

            Use --depth to limit tree depth (0 = root only). Use --json for machine-readable \
            output. Combine with jq to filter:

            Examples:
              ios_simulator_cli describe_all
              ios_simulator_cli describe_all --depth 2
              ios_simulator_cli describe_all --json
              ios_simulator_cli describe_all --json | jq '.. | objects | select(.role == "button")'
            """
    )

    @OptionGroup var common: CommonOptions

    @Option(name: .long, help: "Maximum tree depth (omit for full tree)")
    var depth: Int?

    func run() async throws {
        var args: [String: Value] = [:]
        common.addDevice(to: &args)
        if let depth { args["depth"] = .int(depth) }
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
        common.addDevice(to: &args)
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

            Tip: prefer tap_element when targeting a named element (no coordinate lookup needed).

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
        common.addDevice(to: &args)
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

            Tip: prefer input to find a field, tap it, and type in one step.

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
        common.addDevice(to: &args)
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
        common.addDevice(to: &args)
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
        common.addDevice(to: &args)
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
        common.addDevice(to: &args)
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
        common.addDevice(to: &args)
        try await runToolCLI(toolName: "launch_app", arguments: args, json: common.json, output: nil, verbose: common.verbose)
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
              ios_simulator_cli find --role AXButton
              ios_simulator_cli find --name "Sign In"
              ios_simulator_cli find --role AXStaticText --name "count"
            """
    )

    @OptionGroup var common: CommonOptions
    @OptionGroup var selector: SelectorOptions

    func run() async throws {
        var args = selector.toArguments()
        common.addDevice(to: &args)
        try await runToolCLI(toolName: "find", arguments: args, json: common.json, output: nil, verbose: common.verbose)
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
              ios_simulator_cli exists --name "Sign In"
              ios_simulator_cli exists --role AXButton --name "Submit"
            """
    )

    @OptionGroup var common: CommonOptions
    @OptionGroup var selector: SelectorOptions

    func run() async throws {
        var args = selector.toArguments()
        common.addDevice(to: &args)
        try await runToolCLI(toolName: "exists", arguments: args, json: common.json, output: nil, verbose: common.verbose)
    }
}

struct Count: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "count",
        abstract: "Count matching accessibility elements.",
        discussion: """
            Returns the number of elements matching the selector.

            Examples:
              ios_simulator_cli count --role AXButton
              ios_simulator_cli count --name "Row"
            """
    )

    @OptionGroup var common: CommonOptions
    @OptionGroup var selector: SelectorOptions

    func run() async throws {
        var args = selector.toArguments()
        common.addDevice(to: &args)
        try await runToolCLI(toolName: "count", arguments: args, json: common.json, output: nil, verbose: common.verbose)
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
              ios_simulator_cli text --name "Tap count"
              ios_simulator_cli text --role AXStaticText --name "score"
            """
    )

    @OptionGroup var common: CommonOptions
    @OptionGroup var selector: SelectorOptions

    func run() async throws {
        var args = selector.toArguments()
        common.addDevice(to: &args)
        try await runToolCLI(toolName: "text", arguments: args, json: common.json, output: nil, verbose: common.verbose)
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
              ios_simulator_cli tap_element --name "Sign In"
              ios_simulator_cli tap_element --role AXButton --name "Submit"
              ios_simulator_cli tap_element --name "Menu" --duration 0.5
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
        try await runToolCLI(toolName: "tap_element", arguments: args, json: common.json, output: nil, verbose: common.verbose)
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
              ios_simulator_cli input --role AXTextField --text "hello"
              ios_simulator_cli input --name "Search" --text "query"
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
        try await runToolCLI(toolName: "input", arguments: args, json: common.json, output: nil, verbose: common.verbose)
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
              ios_simulator_cli wait --name "Welcome"
              ios_simulator_cli wait --role AXButton --name "Continue" --timeout 5
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
        try await runToolCLI(toolName: "wait", arguments: args, json: common.json, output: nil, verbose: common.verbose)
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
              ios_simulator_cli log_show --process SpringBoard --last 5s
              ios_simulator_cli log_show --predicate 'subsystem == "com.apple.UIKit"' --last 3s
              ios_simulator_cli log_show --level debug --last 1m
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
        try await runToolCLI(toolName: "log_show", arguments: args, json: common.json, output: nil, verbose: common.verbose)
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
              ios_simulator_cli log_stream --process SpringBoard --duration 3
              ios_simulator_cli log_stream --predicate 'process == "MyApp"' --duration 10
              ios_simulator_cli log_stream --level info --duration 5
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
        try await runToolCLI(toolName: "log_stream", arguments: args, json: common.json, output: nil, verbose: common.verbose)
    }
}
