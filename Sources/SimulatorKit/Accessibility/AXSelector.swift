import Foundation

/// Selector for finding accessibility tree nodes by role, name, and/or identifier.
/// All non-nil criteria compose with AND logic.
public struct AXSelector: Sendable, CustomStringConvertible {
    public let role: String?       // case-insensitive exact match on role
    public let name: String?       // case-insensitive substring match on label OR title
    public let identifier: String? // exact match on accessibilityIdentifier

    public init(role: String? = nil, name: String? = nil, identifier: String? = nil) {
        self.role = role
        self.name = name
        self.identifier = identifier
    }

    public var isEmpty: Bool {
        role == nil && name == nil && identifier == nil
    }

    public var description: String {
        [role.map { "role=\($0)" }, name.map { "name=\($0)" }, identifier.map { "identifier=\($0)" }]
            .compactMap { $0 }.joined(separator: ", ")
    }

    public func matches(_ node: TreeNode) -> Bool {
        if let role = role {
            guard let nodeRole = node.role,
                  nodeRole.caseInsensitiveCompare(role) == .orderedSame else {
                return false
            }
        }
        if let name = name {
            let nameLower = name.lowercased()
            let labelMatch = node.label.map { $0.lowercased().contains(nameLower) } ?? false
            let titleMatch = node.title.map { $0.lowercased().contains(nameLower) } ?? false
            guard labelMatch || titleMatch else {
                return false
            }
        }
        if let identifier = identifier {
            guard node.identifier == identifier else {
                return false
            }
        }
        return true
    }
}

/// Recursively searches a tree node array for nodes matching a selector.
/// - Parameters:
///   - selector: The criteria to match against.
///   - nodes: The root-level tree nodes to search.
///   - maxDepth: Maximum recursion depth (nil for unlimited).
/// - Returns: All matching nodes (flattened, depth-first).
public func findNodes(matching selector: AXSelector, in nodes: [TreeNode], maxDepth: Int? = nil) -> [TreeNode] {
    // Iterative pre-order DFS with an explicit stack. This walk previously
    // recursed once per tree level; deep system trees (e.g. SpringBoard's
    // widget gallery, ~1000 levels) overflowed the 512 KB cooperative-thread
    // stack and killed the process with SIGBUS. See LargeStackThread for the
    // walks where recursion is inherent.
    var results: [TreeNode] = []
    var stack: [(node: TreeNode, depth: Int)] = nodes.reversed().map { ($0, depth: 0) }
    while let (node, depth) = stack.popLast() {
        if selector.matches(node) {
            results.append(node)
        }
        if let max = maxDepth, depth >= max { continue }
        stack.append(contentsOf: node.children.reversed().map { ($0, depth: depth + 1) })
    }
    return results
}
