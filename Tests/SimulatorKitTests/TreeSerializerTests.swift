import Testing
@testable import SimulatorKit
import Foundation

@Suite("TreeSerializer Tests")
struct TreeSerializerTests {

    @Test("Serializes simple tree node to JSON")
    func serializesSimpleNode() throws {
        let node = TreeNode(
            role: "AXButton",
            label: "OK",
            title: nil,
            value: nil,
            identifier: "okButton",
            hint: nil,
            traits: ["button"],
            frame: TreeNode.FrameInfo(x: 10, y: 20, width: 80, height: 44),
            children: []
        )

        let json = try TreeSerializer.toJSON(node)
        #expect(json.contains("\"role\" : \"AXButton\""))
        #expect(json.contains("\"label\" : \"OK\""))
        #expect(json.contains("\"identifier\" : \"okButton\""))
        #expect(!json.contains("\"title\""))
        #expect(!json.contains("\"children\""))
    }

    @Test("Omits nil and empty values")
    func omitsNilValues() throws {
        let node = TreeNode(
            role: "AXStaticText",
            label: nil,
            title: nil,
            value: nil,
            identifier: nil,
            hint: nil,
            traits: nil,
            frame: nil,
            children: []
        )

        let json = try TreeSerializer.toJSON(node)
        #expect(json.contains("\"role\""))
        #expect(!json.contains("\"label\""))
        #expect(!json.contains("\"title\""))
        #expect(!json.contains("\"children\""))
        #expect(!json.contains("\"traits\""))
    }

    @Test("Serializes nested children")
    func serializesChildren() throws {
        let child = TreeNode(
            role: "AXStaticText",
            label: "Hello",
            title: nil, value: nil, identifier: nil, hint: nil, traits: nil, frame: nil,
            children: []
        )
        let parent = TreeNode(
            role: "AXGroup",
            label: nil, title: nil, value: nil, identifier: nil, hint: nil, traits: nil, frame: nil,
            children: [child]
        )

        let json = try TreeSerializer.toJSON(parent)
        #expect(json.contains("\"children\""))
        #expect(json.contains("\"Hello\""))
    }

    @Test("Serializes array of nodes")
    func serializesArray() throws {
        let nodes = [
            TreeNode(role: "AXButton", label: "A", title: nil, value: nil, identifier: nil, hint: nil, traits: nil, frame: nil, children: []),
            TreeNode(role: "AXButton", label: "B", title: nil, value: nil, identifier: nil, hint: nil, traits: nil, frame: nil, children: []),
        ]

        let json = try TreeSerializer.toJSON(nodes)
        #expect(json.hasPrefix("["))
        #expect(json.contains("\"A\""))
        #expect(json.contains("\"B\""))
    }
}
