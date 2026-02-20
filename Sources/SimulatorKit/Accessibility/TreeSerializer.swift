import Foundation

/// Represents an accessibility tree node for JSON serialization.
public struct TreeNode: Codable, Sendable {
    public let role: String?
    public let label: String?
    public let title: String?
    public let value: String?
    public let identifier: String?
    public let hint: String?
    public let traits: [String]?
    public let frame: FrameInfo?
    public let children: [TreeNode]

    public init(
        role: String?,
        label: String?,
        title: String?,
        value: String?,
        identifier: String?,
        hint: String?,
        traits: [String]?,
        frame: FrameInfo?,
        children: [TreeNode]
    ) {
        self.role = role
        self.label = label
        self.title = title
        self.value = value
        self.identifier = identifier
        self.hint = hint
        self.traits = traits
        self.frame = frame
        self.children = children
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(role, forKey: .role)
        try container.encodeIfPresent(label, forKey: .label)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(value, forKey: .value)
        try container.encodeIfPresent(identifier, forKey: .identifier)
        try container.encodeIfPresent(hint, forKey: .hint)
        if let traits = traits, !traits.isEmpty {
            try container.encode(traits, forKey: .traits)
        }
        try container.encodeIfPresent(frame, forKey: .frame)
        if !children.isEmpty {
            try container.encode(children, forKey: .children)
        }
    }

    enum CodingKeys: String, CodingKey {
        case role, label, title, value, identifier, hint, traits, frame, children
    }

    public struct FrameInfo: Codable, Sendable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        /// Center point of the frame (the tap target).
        public var center: (x: Double, y: Double) {
            (x + width / 2, y + height / 2)
        }
    }
}

/// Converts accessibility elements into serializable tree nodes.
public enum TreeSerializer {

    /// Serializes a tree node array to a pretty-printed JSON string.
    public static func toJSON(_ nodes: [TreeNode]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(nodes)
        guard let json = String(data: data, encoding: .utf8) else {
            throw SerializerError.encodingFailed
        }
        return json
    }

    /// Serializes a single tree node to a pretty-printed JSON string.
    public static func toJSON(_ node: TreeNode) throws -> String {
        try toJSON([node])
    }

    // MARK: - Markdown (indented text tree for LLM agents)

    /// Notable traits worth surfacing in markdown output.
    /// Traits that are redundant with the role (e.g. "staticText", "button") are excluded.
    private static let notableTraits: Set<String> = [
        "notEnabled", "selected", "link", "searchField",
        "adjustable", "header", "toggle",
    ]

    /// Serializes a tree node array to an indented plain-text tree optimized for LLM agents.
    /// - Parameter maxDepth: Maximum recursion depth (nil for unlimited). Depth 0 = root nodes only.
    public static func toMarkdown(_ nodes: [TreeNode], maxDepth: Int? = nil) -> String {
        var lines: [String] = []
        for node in nodes {
            appendMarkdown(node: node, indent: 0, depth: 0, maxDepth: maxDepth, lines: &lines)
        }
        return lines.joined(separator: "\n")
    }

    /// Serializes a single tree node to an indented plain-text tree.
    /// - Parameter maxDepth: Maximum recursion depth (nil for unlimited). Depth 0 = this node only.
    public static func toMarkdown(_ node: TreeNode, maxDepth: Int? = nil) -> String {
        var lines: [String] = []
        appendMarkdown(node: node, indent: 0, depth: 0, maxDepth: maxDepth, lines: &lines)
        return lines.joined(separator: "\n")
    }

    private static func appendMarkdown(node: TreeNode, indent: Int, depth: Int, maxDepth: Int?, lines: inout [String]) {
        let role = node.role ?? ""
        let name = node.label.flatMap({ $0.isEmpty ? nil : $0 })
            ?? node.title.flatMap({ $0.isEmpty ? nil : $0 })
            ?? ""
        let value = node.value.flatMap({ $0.isEmpty ? nil : $0 })
        let traits = node.traits?.filter { notableTraits.contains($0) } ?? []

        let hasContent = !role.isEmpty || !name.isEmpty || value != nil
        if !hasContent && node.children.isEmpty {
            return // skip empty containers
        }

        if hasContent {
            let prefix = String(repeating: "  ", count: indent)
            var parts: [String] = []

            // role "name"
            if !role.isEmpty && !name.isEmpty {
                parts.append("\(role) \"\(name)\"")
            } else if !role.isEmpty {
                parts.append(role)
            } else if !name.isEmpty {
                parts.append("\"\(name)\"")
            }

            // (cx±hw, cy±hh) — center point ± half-size
            if let f = node.frame {
                let cx = Int(round(f.x + f.width / 2))
                let cy = Int(round(f.y + f.height / 2))
                let hw = Int(round(f.width / 2))
                let hh = Int(round(f.height / 2))
                parts.append("(\(cx)±\(hw), \(cy)±\(hh))")
            }

            // value="..."
            if let v = value {
                parts.append("value=\"\(v)\"")
            }

            // [trait, trait]
            if !traits.isEmpty {
                parts.append("[\(traits.joined(separator: ", "))]")
            }

            lines.append(prefix + parts.joined(separator: " "))
        }

        let childIndent = hasContent ? indent + 1 : indent
        if let max = maxDepth, depth >= max { return }
        for child in node.children {
            appendMarkdown(node: child, indent: childIndent, depth: depth + 1, maxDepth: maxDepth, lines: &lines)
        }
    }

    public enum SerializerError: Error, LocalizedError {
        case encodingFailed

        public var errorDescription: String? {
            switch self {
            case .encodingFailed:
                return "Failed to encode tree node to JSON string"
            }
        }
    }
}
