import Foundation
import MCP
import SimulatorKit

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

    if !isFiltered("describe") {
        tools.append(Tool(
            name: "describe",
            description: "Describe accessibility elements in the iOS Simulator. Two modes: (1) Tree mode (default): dumps the full accessibility tree. Supports optional depth limit. (2) Point mode: pass x and y to get the element at those coordinates. Coordinates are (center±half-size) in iOS points — the center value is the tap target.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "depth": .object(["type": .string("integer"), "description": .string("Maximum tree depth to return (omit for full tree). 0 = root only, 1 = root + direct children, etc. Only valid in tree mode (without x/y).")]),
                    "x": .object(["type": .string("number"), "description": .string("The x-coordinate (point mode). Must be provided with y.")]),
                    "y": .object(["type": .string("number"), "description": .string("The y-coordinate (point mode). Must be provided with x.")]),
                    "udid": udidSchema,
                ]),
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

    if !isFiltered("tap") {
        var tapSchema = selectorSchema
        tapSchema["x"] = .object(["type": .string("number"), "description": .string("The x-coordinate (coordinate mode). Must be provided with y.")])
        tapSchema["y"] = .object(["type": .string("number"), "description": .string("The y-coordinate (coordinate mode). Must be provided with x.")])
        tapSchema["duration"] = .object([
            "type": .string("string"),
            "description": .string("Press duration for long-press (in seconds)"),
            "pattern": .string(#"^\d+(\.\d+)?$"#),
        ])
        tools.append(Tool(
            name: "tap",
            description: "Tap on the iOS Simulator screen. Two modes: (1) Selector mode: finds an accessibility element by role/name/identifier and taps its center. (2) Coordinate mode: pass x and y to tap at exact coordinates. Provide selectors OR coordinates, not both.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(tapSchema),
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
        case "describe":
            return try await handleDescribe(params)
        case "tap":
            return try await handleTap(params)
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
            return try await handleTap(params)
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
