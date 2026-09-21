import Foundation

/// Developer dir used when neither `DEVELOPER_DIR` nor `xcode-select` yield a usable Xcode.
public let fallbackDeveloperDir = "/Applications/Xcode.app/Contents/Developer"

/// The developer dir chosen via `xcode-select -s`, read straight from the symlink it
/// maintains to avoid a subprocess.
public func readXcodeSelectLink() -> String? {
    try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link")
}

/// Resolves the Xcode developer dir the same way Apple's tools do:
/// 1. `DEVELOPER_DIR` env var (a `…/Contents/Developer` dir, or a bare `.app` bundle)
/// 2. The `xcode-select` selection (ignored when it points at the Command Line Tools,
///    which don't ship SimulatorKit)
/// 3. `/Applications/Xcode.app/Contents/Developer`
public func resolveDeveloperDir(
    env: [String: String] = ProcessInfo.processInfo.environment,
    xcodeSelectLink: String? = readXcodeSelectLink(),
    fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
) -> String {
    for candidate in [env["DEVELOPER_DIR"], xcodeSelectLink] {
        guard let candidate, let dir = normalizeDeveloperDir(candidate, fileExists: fileExists) else { continue }
        return dir
    }
    return fallbackDeveloperDir
}

/// Returns the developer dir for `path`, or nil if it doesn't point at an Xcode.
private func normalizeDeveloperDir(_ path: String, fileExists: (String) -> Bool) -> String? {
    var path = path
    while path.count > 1, path.hasSuffix("/") { path.removeLast() }
    guard !path.isEmpty else { return nil }

    let nested = path + "/Contents/Developer"
    if fileExists(nested) { return nested }

    guard fileExists(path), !path.hasSuffix("/CommandLineTools") else { return nil }
    return path
}

public enum DeveloperDir {
    /// The developer dir for this process, resolved once.
    public static let resolved: String = resolveDeveloperDir()

    /// The environment for child processes, pinned to `resolved` so `xcrun` agrees with
    /// the frameworks loaded in-process.
    public static var childEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["DEVELOPER_DIR"] = resolved
        return env
    }
}
