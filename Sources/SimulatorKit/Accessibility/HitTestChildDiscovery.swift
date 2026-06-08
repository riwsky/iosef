import Foundation

/// Recovers children that a container hides from the accessibility tree-walk.
///
/// Some host views — notably the SwiftUI `NavigationStack` navigation-bar `AXGroup`
/// (GitHub issue #2) — report an empty `accessibilityChildren` array even though the
/// Back button, navigation title, and `.toolbar { }` items are present in the AX
/// hierarchy and reachable by hit-testing (point-query, VoiceOver, and XCTest all
/// find them). When that happens, sweeping hit-test points across the container's
/// frame recovers the missing children.
///
/// This is the same hit-test sweep the watchOS grid-scan fallback uses, factored out
/// so it can run per-container and be tested without the private
/// AccessibilityPlatformTranslation framework.
public enum HitTestChildDiscovery {

    /// Smallest side (in points) a container must have before we bother sweeping it.
    private static let minContainerSide: Double = 4

    /// Roles worth sweeping when they report no children. Restricted to grouping
    /// containers so we don't hit-test inside every leaf button or label.
    private static let containerRoles: Set<String> = ["AXGroup"]

    /// Whether to attempt hit-test discovery for an element that reported no children
    /// via `accessibilityChildren`. True only for grouping containers occupying
    /// non-trivial bounds — e.g. the nav-bar `AXGroup` from issue #2.
    public static func shouldDiscoverChildren(
        role: String?,
        frame: TreeNode.FrameInfo?,
        reportedChildCount: Int
    ) -> Bool {
        guard reportedChildCount == 0 else { return false }
        guard let frame, frame.width >= minContainerSide, frame.height >= minContainerSide
        else { return false }
        return containerRoles.contains(role ?? "")
    }

    /// Samples points across `frame` on a regular grid, collecting the deduped child
    /// nodes that `hitTest` reveals.
    ///
    /// - The container itself (a node whose frame equals `containerFrame`) and the
    ///   application root are excluded — hit-testing empty regions tends to return one
    ///   of those.
    /// - Results are deduped by frame, so an element spanning many sample points is
    ///   returned once.
    /// - Points already covered by an already-discovered element's frame are skipped,
    ///   bounding the number of `hitTest` calls.
    ///
    /// - Parameters:
    ///   - frame: The region to sweep, in the same coordinate space `hitTest` expects.
    ///   - containerFrame: The frame of the container being expanded; nodes matching it
    ///     are treated as self-hits and dropped.
    ///   - step: Grid spacing between sample points, in points.
    ///   - isCancelled: Polled before each sample point; return true to stop early
    ///     (used to honor the tree-walk deadline, since each `hitTest` is an XPC call).
    ///   - hitTest: Returns the element at a point, or nil if none.
    public static func discoverChildren(
        in frame: TreeNode.FrameInfo,
        containerFrame: TreeNode.FrameInfo?,
        step: Double = 10,
        isCancelled: () -> Bool = { false },
        hitTest: (_ x: Double, _ y: Double) -> TreeNode?
    ) -> [TreeNode] {
        guard frame.width > 0, frame.height > 0, step > 0 else { return [] }

        var seen = Set<String>()
        var discovered: [TreeNode] = []

        var y = frame.y + step / 2
        while y < frame.y + frame.height {
            var x = frame.x + step / 2
            while x < frame.x + frame.width {
                defer { x += step }

                if isCancelled() { return discovered }

                // Skip points already inside a discovered element's frame.
                if discovered.contains(where: { contains($0.frame, x: x, y: y) }) {
                    continue
                }

                guard let node = hitTest(x, y) else { continue }
                if node.role == "AXApplication" { continue }
                if let cf = containerFrame, framesEqual(node.frame, cf) { continue }

                let key = frameKey(for: node)
                if seen.insert(key).inserted {
                    discovered.append(node)
                }
            }
            y += step
        }

        return discovered
    }

    // MARK: - geometry helpers

    private static func contains(_ frame: TreeNode.FrameInfo?, x: Double, y: Double) -> Bool {
        guard let f = frame else { return false }
        return x >= f.x && x <= f.x + f.width && y >= f.y && y <= f.y + f.height
    }

    private static func framesEqual(_ a: TreeNode.FrameInfo?, _ b: TreeNode.FrameInfo) -> Bool {
        guard let a else { return false }
        return a.x == b.x && a.y == b.y && a.width == b.width && a.height == b.height
    }

    private static func frameKey(for node: TreeNode) -> String {
        if let f = node.frame {
            return "\(f.x),\(f.y),\(f.width),\(f.height)"
        }
        return "nil-\(node.identifier ?? node.label ?? UUID().uuidString)"
    }
}
