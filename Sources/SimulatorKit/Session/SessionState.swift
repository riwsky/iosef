import Foundation

// MARK: - Scope mode

/// Which session directory to use: local (./.iosef/) or global (~/.iosef/).
public enum ScopeMode {
    case auto      // local if ./.iosef/state.json exists, else global
    case local     // force ./.iosef/
    case global    // force ~/.iosef/
}

// MARK: - Session state

/// Contents of state.json — the directory-scoped session file written by `iosef start`.
public struct SessionState: Codable, Equatable {
    public var device: String?

    public init(device: String? = nil) {
        self.device = device
    }
}

// MARK: - Session directory resolution

/// Returns the session directory path for the given scope and base directories.
/// Does NOT create the directory — callers that write must ensure it exists first.
public func resolveSessionDir(_ scope: ScopeMode, cwd: String = FileManager.default.currentDirectoryPath) -> String {
    let localDir = cwd + "/.iosef"
    let globalDir = NSHomeDirectory() + "/.iosef"

    switch scope {
    case .local:
        return localDir
    case .global:
        return globalDir
    case .auto:
        let statePath = localDir + "/state.json"
        if FileManager.default.fileExists(atPath: statePath) {
            return localDir
        }
        return globalDir
    }
}

/// Ensures the session directory (and cache/ subdirectory) exist.
@discardableResult
public func ensureSessionDir(_ scope: ScopeMode, cwd: String = FileManager.default.currentDirectoryPath) -> String {
    let dir = resolveSessionDir(scope, cwd: cwd)
    let cacheDir = dir + "/cache"
    try? FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
    return dir
}

// MARK: - Session I/O

/// Reads state.json from the given session directory, or nil if absent/invalid.
public func readSessionState(from dir: String) -> SessionState? {
    let statePath = dir + "/state.json"
    guard let data = FileManager.default.contents(atPath: statePath),
          let state = try? JSONDecoder().decode(SessionState.self, from: data) else {
        return nil
    }
    return state
}

/// Writes state.json to the given session directory.
public func writeSessionState(_ state: SessionState, to dir: String) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(state)
    let statePath = dir + "/state.json"
    FileManager.default.createFile(atPath: statePath, contents: data)
}
