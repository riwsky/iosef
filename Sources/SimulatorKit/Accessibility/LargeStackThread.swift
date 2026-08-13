import Foundation

/// Runs stack-hungry tree work on a dedicated thread with an explicit 8 MB stack
/// (matching the main thread) instead of the 512 KB a Swift Concurrency
/// cooperative thread gets.
///
/// Deep system trees — e.g. SpringBoard's Home Screen widget gallery, which
/// nests ~1000 levels — kill the process with SIGBUS ("stack guard"
/// KERN_PROTECTION_FAILURE) when walked recursively on a cooperative thread.
/// Two recursions are inherent and stay recursive behind this helper: the
/// AXPMacPlatformElement walk in `serializeElement` (holds live ObjC elements)
/// and `JSONEncoder`'s synthesized Codable descent in `TreeSerializer.toJSON`.
/// Trivially-iterative walks (`findNodes`) drop recursion instead.
///
/// The wrapped APIs are synchronous and already block their calling thread for
/// the duration of the walk; this changes only whose stack the work consumes,
/// so the depth budget no longer depends on which executor the caller happens
/// to run on.
enum LargeStackThread {
    private static let stackSize = 64 << 20

    /// Carries the result across the thread boundary. Written once by the walk
    /// thread, read once by the blocked caller after the semaphore fires — no
    /// concurrent access.
    private final class ResultBox<T>: @unchecked Sendable {
        var result: Result<T, Error>?
    }

    static func run<T>(_ body: @escaping @Sendable () throws -> T) throws -> T {
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            box.result = Result { try body() }
            done.signal()
        }
        thread.stackSize = stackSize
        thread.name = "iosef.axp.tree-walk"
        thread.start()
        done.wait()
        return try box.result!.get()
    }
}
