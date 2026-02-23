import Foundation

// MARK: - Scope mode

/// Which state directory to use: local (./.iosef/) or global (~/.iosef/).
public enum ScopeMode {
    case auto      // local if ./.iosef/config.json exists, else global
    case local     // force ./.iosef/
    case global    // force ~/.iosef/
}

// MARK: - Project config

/// Contents of config.json.
public struct ProjectConfig: Codable, Equatable {
    public var device: String?

    public init(device: String? = nil) {
        self.device = device
    }
}

// MARK: - State directory resolution

/// Returns the state directory path for the given scope and base directories.
/// Does NOT create the directory — callers that write must ensure it exists first.
public func resolveStateDir(_ scope: ScopeMode, cwd: String = FileManager.default.currentDirectoryPath) -> String {
    let localDir = cwd + "/.iosef"
    let globalDir = NSHomeDirectory() + "/.iosef"

    switch scope {
    case .local:
        return localDir
    case .global:
        return globalDir
    case .auto:
        let configPath = localDir + "/config.json"
        if FileManager.default.fileExists(atPath: configPath) {
            return localDir
        }
        return globalDir
    }
}

/// Ensures the state directory (and cache/ subdirectory) exist.
@discardableResult
public func ensureStateDir(_ scope: ScopeMode, cwd: String = FileManager.default.currentDirectoryPath) -> String {
    let dir = resolveStateDir(scope, cwd: cwd)
    let cacheDir = dir + "/cache"
    try? FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
    return dir
}

// MARK: - Config I/O

/// Reads config.json from the given state directory, or nil if absent/invalid.
public func readProjectConfig(from dir: String) -> ProjectConfig? {
    let configPath = dir + "/config.json"
    guard let data = FileManager.default.contents(atPath: configPath),
          let config = try? JSONDecoder().decode(ProjectConfig.self, from: data) else {
        return nil
    }
    return config
}

/// Writes a config.json to the given state directory.
public func writeProjectConfig(_ config: ProjectConfig, to dir: String) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(config)
    let configPath = dir + "/config.json"
    FileManager.default.createFile(atPath: configPath, contents: data)
}

// MARK: - Device cache validation

/// Cached device entry from disk.
public struct DeviceCacheEntry: Codable, Equatable {
    public let udid: String
    public let name: String?

    public init(udid: String, name: String?) {
        self.udid = udid
        self.name = name
    }

    /// Whether this cache entry matches the expected default device name.
    /// Returns true if no default is set, or if the cached name matches
    /// (including the "-main" suffix convention).
    /// Returns false if names don't match — the cache is stale.
    public func matches(defaultDeviceName: String?) -> Bool {
        guard let expected = defaultDeviceName else { return true }
        guard let cachedName = name else { return false }
        return cachedName == expected || cachedName == "\(expected)-main"
    }
}

// MARK: - Device cache I/O

public func readDeviceCache(from dir: String, ttl: TimeInterval = 30) -> DeviceCacheEntry? {
    let path = dir + "/cache/device.json"
    let fm = FileManager.default
    guard fm.fileExists(atPath: path) else { return nil }

    guard let attrs = try? fm.attributesOfItem(atPath: path),
          let mtime = attrs[.modificationDate] as? Date,
          Date().timeIntervalSince(mtime) < ttl else {
        return nil
    }

    guard let data = fm.contents(atPath: path),
          let cached = try? JSONDecoder().decode(DeviceCacheEntry.self, from: data) else {
        return nil
    }
    return cached
}

public func writeDeviceCache(_ entry: DeviceCacheEntry, to dir: String) {
    let cacheDir = dir + "/cache"
    try? FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
    guard let data = try? JSONEncoder().encode(entry) else { return }
    FileManager.default.createFile(atPath: cacheDir + "/device.json", contents: data)
}
