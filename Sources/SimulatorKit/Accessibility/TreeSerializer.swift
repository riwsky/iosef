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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(node)
        guard let json = String(data: data, encoding: .utf8) else {
            throw SerializerError.encodingFailed
        }
        return json
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
