import Foundation
import MCP
import SimulatorKit

// MARK: - Async timeout utility

/// Races a synchronous operation against a GCD timer. Uses DispatchQueue (not the
/// Swift cooperative thread pool) so the timeout fires even when the operation blocks
/// a thread on a synchronous ObjC call that can't be cancelled.
func log(_ msg: String) {
    logDiagnostic(msg)
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

// MARK: - Session state (types from SimulatorKit, wrappers for activeScope default)

/// Resolved scope mode for this invocation (set by applyScope before dispatch).
nonisolated(unsafe) var activeScope: ScopeMode = .auto

/// Convenience: resolveSessionDir using activeScope default.
func resolveSessionDir(_ scope: ScopeMode = activeScope) -> String {
    SimulatorKit.resolveSessionDir(scope)
}

/// Convenience: ensureSessionDir using activeScope default.
@discardableResult
func ensureSessionDir(_ scope: ScopeMode = activeScope) -> String {
    SimulatorKit.ensureSessionDir(scope)
}

/// Reads state.json from the active session directory, or nil if absent/invalid.
func readSessionState() -> SessionState? {
    let dir = resolveSessionDir()
    guard let state = SimulatorKit.readSessionState(from: dir) else {
        return nil
    }
    log("Loaded session from \(dir)/state.json")
    return state
}

/// Reads state.json and applies its device setting to SimCtlClient.
func applySessionState() {
    guard let state = readSessionState(),
          let device = state.device, !device.isEmpty else {
        return
    }
    // Session device overrides the VCS-root heuristic, but not explicit --device flags
    if SimCtlClient.defaultDeviceName == nil || SimCtlClient.defaultDeviceName == computeDefaultDeviceName() {
        SimCtlClient.defaultDeviceName = device
        log("Session: device = \(device)")
    }
}

/// Applies scope mode from parsed CommonOptions flags.
func applyScope(from common: CommonOptions) {
    if common.local {
        activeScope = .local
    } else if common.global {
        activeScope = .global
    }
}

// MARK: - Configuration

let serverVersion = "0.1.0"
let filteredTools: Set<String> = {
    guard let env = ProcessInfo.processInfo.environment["IOSEF_FILTERED_TOOLS"] else {
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
