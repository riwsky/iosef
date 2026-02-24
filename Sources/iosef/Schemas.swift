import Foundation
import MCP
import SimulatorKit

// MARK: - UDID Schema (reused across tools)

let udidSchema: Value = .object([
    "type": .string("string"),
    "description": .string("Name or UDID of target simulator (auto-detected from session or VCS root if omitted)"),
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
            return "No element found matching: \(sel)"
        case .noFrame(let sel):
            return "Element found but has no frame: \(sel)"
        }
    }
}

// MARK: - Path helpers

func ensureAbsolutePath(_ filePath: String, defaultDir: String? = nil) -> String {
    if filePath.hasPrefix("/") { return filePath }

    if filePath.hasPrefix("~/") {
        return NSHomeDirectory() + "/" + String(filePath.dropFirst(2))
    }

    let base = defaultDir ?? {
        if let customDir = ProcessInfo.processInfo.environment["IOSEF_DEFAULT_OUTPUT_DIR"] {
            if customDir.hasPrefix("~/") {
                return NSHomeDirectory() + "/" + String(customDir.dropFirst(2))
            }
            return customDir
        }
        return NSHomeDirectory() + "/Downloads"
    }()

    return base + "/" + filePath
}

// MARK: - Device errors

struct DeviceNotBootedError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
