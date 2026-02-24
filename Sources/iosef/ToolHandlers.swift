import Foundation
import MCP
import SimulatorKit

// MARK: - Tool implementations

func handleGetBootedSimID() async throws -> CallTool.Result {
    let device = try SimCtlClient.getBootedDevice()
    return .init(content: [.text("Booted Simulator: \"\(device.name)\". UUID: \"\(device.udid)\"")])
}

func handleDescribe(_ params: CallTool.Parameters) async throws -> CallTool.Result {
    let hasX = extractDouble(params.arguments?["x"]) != nil
    let hasY = extractDouble(params.arguments?["y"]) != nil
    let hasDepth = params.arguments?["depth"].flatMap({ Int($0, strict: false) }) != nil

    if hasX != hasY {
        return .init(content: [.text("Both x and y are required for point mode (got only \(hasX ? "x" : "y"))")], isError: true)
    }

    let hasPoint = hasX && hasY

    if hasPoint && hasDepth {
        return .init(content: [.text("Cannot combine depth with point coordinates — depth is only for tree mode")], isError: true)
    }

    let udid = try await SimulatorCache.shared.resolveDeviceID(params.arguments?["udid"]?.stringValue)
    let axpBridge = try await SimulatorCache.shared.getAXPBridge(udid: udid)

    if hasPoint {
        let x = extractDouble(params.arguments?["x"])!
        let y = extractDouble(params.arguments?["y"])!
        let markdown = try await withTimeout("describe", .seconds(12)) {
            let node = try axpBridge.accessibilityElementAtPoint(x: x, y: y)
            return TreeSerializer.toMarkdown(node)
        }
        return .init(content: [.text(markdown)])
    } else {
        let depth = params.arguments?["depth"].flatMap({ Int($0, strict: false) })
        let markdown = try await withTimeout("describe", .seconds(12)) {
            let nodes = try axpBridge.accessibilityElements()
            return TreeSerializer.toMarkdown(nodes, maxDepth: depth)
        }
        return .init(content: [.text(markdown)])
    }
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

    let absolutePath = ensureAbsolutePath(appPath, defaultDir: FileManager.default.currentDirectoryPath)

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
    let found = !matches.isEmpty
    return .init(content: [.text(found ? "true" : "false")], isError: !found)
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

func handleTap(_ params: CallTool.Parameters) async throws -> CallTool.Result {
    let hasSelector = params.arguments?["role"]?.stringValue != nil
        || params.arguments?["name"]?.stringValue != nil
        || params.arguments?["identifier"]?.stringValue != nil
    let hasX = extractDouble(params.arguments?["x"]) != nil
    let hasY = extractDouble(params.arguments?["y"]) != nil

    if hasX != hasY {
        return .init(content: [.text("Both x and y are required for coordinate mode (got only \(hasX ? "x" : "y"))")], isError: true)
    }

    let hasPoint = hasX && hasY

    if hasSelector && hasPoint {
        return .init(content: [.text("Cannot combine selectors (role/name/identifier) with coordinates (x/y) — use one mode or the other")], isError: true)
    }

    if !hasSelector && !hasPoint {
        return .init(content: [.text("Provide either selectors (role/name/identifier) or coordinates (x/y)")], isError: true)
    }

    if hasPoint {
        let x = extractDouble(params.arguments?["x"])!
        let y = extractDouble(params.arguments?["y"])!
        let udid = try await SimulatorCache.shared.resolveDeviceID(params.arguments?["udid"]?.stringValue)
        let hidClient = try await SimulatorCache.shared.getHIDClient(udid: udid)

        if let duration = extractDouble(params.arguments?["duration"]) {
            hidClient.longPress(x: x, y: y, duration: duration)
        } else {
            hidClient.tap(x: x, y: y)
        }

        return .init(content: [.text("Tapped successfully")])
    }

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
