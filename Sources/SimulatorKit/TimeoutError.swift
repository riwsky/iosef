import Foundation

/// Errors thrown when MCP server operations exceed their timeout.
public enum TimeoutError: Error, LocalizedError {
    case processTimedOut(command: String, timeoutSeconds: Double)
    case accessibilityTimedOut(timeoutSeconds: Double)

    public var errorDescription: String? {
        switch self {
        case .processTimedOut(let command, let timeout):
            return "Process '\(command)' timed out after \(Int(timeout))s"
        case .accessibilityTimedOut(let timeout):
            return "Accessibility request timed out after \(Int(timeout))s"
        }
    }
}
