import Foundation

/// When false, diagnostic log output is suppressed. Defaults to false (quiet).
/// CLI sets this based on --verbose; MCP server always enables it.
nonisolated(unsafe) public var verboseLogging = false

/// Writes a timestamped diagnostic message to stderr when verbose logging is enabled.
public func logDiagnostic(_ message: String, prefix: String = "iosef") {
    guard verboseLogging else { return }
    let ts = String(format: "%.3f", CFAbsoluteTimeGetCurrent())
    FileHandle.standardError.write(Data("[\(prefix) \(ts)] \(message)\n".utf8))
}
