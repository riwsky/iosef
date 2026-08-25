import Foundation

/// Ensures the simulator runtime has accessibility enabled so AXP attribute
/// requests return real data.
///
/// Through iOS 26, connecting an AXP client was enough for the runtime to
/// serve the accessibility tree. On iOS 27 runtimes that implicit enablement
/// is gone: `frontmostApplicationWithDisplayId:` still returns a translation
/// object, but every attribute request (frame, label, children, ...) comes
/// back empty, which surfaced as `AXApplication (0±0, 0±0)`. Writing the
/// `com.apple.Accessibility` defaults inside the simulator (the same switch
/// Accessibility Inspector flips) restores the old behavior.
///
/// The defaults persist per device, so this runs once per simulator. Apps
/// already running when the defaults are written keep serving an empty tree
/// until relaunched, hence the stderr hint.
enum SimulatorAccessibilityEnabler {

    private static let lock = NSLock()
    nonisolated(unsafe) private static var checkedUDIDs: Set<String> = []

    /// Checks the device's accessibility defaults and enables them if needed.
    /// Returns true when the defaults were just written (a relaunch of the
    /// app under test is then required for it to serve accessibility data).
    ///
    /// Memoized per UDID for the process lifetime: this runs in every
    /// `AXPAccessibilityBridge` init, and the `simctl spawn defaults read`
    /// subprocess is too slow for that hot path. The defaults persist per
    /// device, so one check per process suffices (an `simctl erase` mid-process
    /// needs a process restart to re-trigger enablement).
    @discardableResult
    static func ensureEnabled(udid: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if checkedUDIDs.contains(udid) { return false }
        checkedUDIDs.insert(udid)

        let read = runSimctl(["spawn", udid, "defaults", "read",
                              "com.apple.Accessibility", "ApplicationAccessibilityEnabled"])
        if read.status == 0, read.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1" {
            return false
        }

        for key in ["AccessibilityEnabled", "ApplicationAccessibilityEnabled"] {
            _ = runSimctl(["spawn", udid, "defaults", "write",
                           "com.apple.Accessibility", key, "-bool", "true"])
        }
        logDiagnostic("enabled com.apple.Accessibility defaults on \(udid)", prefix: "AXEnabler")
        FileHandle.standardError.write(Data(
            "[iosef] Enabled accessibility in simulator \(udid). Apps already running must be relaunched before their accessibility tree is available.\n".utf8
        ))
        return true
    }

    private static func runSimctl(_ arguments: [String]) -> (status: Int32, stdout: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl"] + arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return (-1, "")
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
