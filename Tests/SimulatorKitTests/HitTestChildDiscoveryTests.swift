import Testing
@testable import SimulatorKit
import Foundation

/// Regression tests for GitHub issue #2: `describe()` tree-walk skips the children
/// of the SwiftUI `NavigationStack` navigation-bar `AXGroup`. The group reports an
/// empty `accessibilityChildren` array even though Back / title / toolbar items are
/// reachable via hit-testing (point-query, VoiceOver, XCTest all find them).
///
/// The fix is a per-container hit-test fallback: when a container reports no children
/// but occupies non-trivial bounds, sample points across its frame and collect the
/// elements that hit-testing reveals. These tests exercise that fallback logic in
/// isolation from the private AccessibilityPlatformTranslation framework.
@Suite("HitTestChildDiscovery Tests")
struct HitTestChildDiscoveryTests {

    // MARK: - shouldDiscoverChildren

    @Test("Discovers children for an empty AXGroup with non-trivial bounds (the nav-bar group)")
    func discoversForEmptyNavBarGroup() {
        // The nav-bar group from issue #2: AXGroup (201±201, 155±27), no children.
        let frame = TreeNode.FrameInfo(x: 0, y: 142, width: 402, height: 54)
        #expect(HitTestChildDiscovery.shouldDiscoverChildren(
            role: "AXGroup", frame: frame, reportedChildCount: 0))
    }

    @Test("Does not re-discover when the container already reported children")
    func skipsWhenChildrenReported() {
        let frame = TreeNode.FrameInfo(x: 0, y: 142, width: 402, height: 54)
        #expect(!HitTestChildDiscovery.shouldDiscoverChildren(
            role: "AXGroup", frame: frame, reportedChildCount: 3))
    }

    @Test("Does not sweep leaf-like roles (would hit-test every button)")
    func skipsLeafRoles() {
        let frame = TreeNode.FrameInfo(x: 8, y: 144, width: 40, height: 22)
        #expect(!HitTestChildDiscovery.shouldDiscoverChildren(
            role: "AXButton", frame: frame, reportedChildCount: 0))
    }

    @Test("Does not sweep zero- or missing-bounds containers")
    func skipsTrivialBounds() {
        #expect(!HitTestChildDiscovery.shouldDiscoverChildren(
            role: "AXGroup", frame: TreeNode.FrameInfo(x: 0, y: 0, width: 0, height: 0),
            reportedChildCount: 0))
        #expect(!HitTestChildDiscovery.shouldDiscoverChildren(
            role: "AXGroup", frame: nil, reportedChildCount: 0))
    }

    // MARK: - discoverChildren

    /// Models the nav-bar group: hit-testing across its frame reveals Back (left),
    /// the title heading (center), and the "More" toolbar item (right) — none of
    /// which appear in `accessibilityChildren`.
    @Test("Recovers Back / title / More from the nav-bar group via hit-testing")
    func recoversNavBarItems() {
        let container = TreeNode.FrameInfo(x: 0, y: 142, width: 402, height: 54)

        let back = makeNode(role: "AXButton", label: "Back",
                            frame: .init(x: 8, y: 150, width: 60, height: 38))
        let title = makeNode(role: "AXHeading", label: "Item",
                             frame: .init(x: 160, y: 150, width: 80, height: 38))
        let more = makeNode(role: "AXPopUpButton", label: "More",
                            identifier: "itemDetailMoreMenu",
                            frame: .init(x: 330, y: 150, width: 60, height: 38))

        let discovered = HitTestChildDiscovery.discoverChildren(
            in: container, containerFrame: container
        ) { x, _ in
            if x < 130 { return back }
            if x < 280 { return title }
            return more
        }

        let labels = discovered.compactMap { $0.label }
        #expect(labels.contains("Back"))
        #expect(labels.contains("Item"))
        #expect(labels.contains("More"))
        // Each element discovered exactly once despite many sample points landing on it.
        #expect(discovered.count == 3)
    }

    @Test("Excludes the container itself and the application root")
    func excludesContainerAndAppRoot() {
        let container = TreeNode.FrameInfo(x: 0, y: 142, width: 402, height: 54)
        let containerNode = makeNode(role: "AXGroup", label: nil, frame: container)
        let appRoot = makeNode(role: "AXApplication", label: "noonfox",
                               frame: .init(x: 0, y: 0, width: 402, height: 874))
        let real = makeNode(role: "AXButton", label: "Back",
                            frame: .init(x: 8, y: 150, width: 60, height: 38))

        let discovered = HitTestChildDiscovery.discoverChildren(
            in: container, containerFrame: container
        ) { x, _ in
            if x < 100 { return real }
            if x < 250 { return containerNode }   // hit-test sometimes returns the group itself
            return appRoot                          // ...or the app root in empty regions
        }

        #expect(discovered.count == 1)
        #expect(discovered.first?.label == "Back")
    }

    // MARK: - helpers

    private func makeNode(role: String?, label: String?, identifier: String? = nil,
                          frame: TreeNode.FrameInfo) -> TreeNode {
        TreeNode(role: role, label: label, title: nil, value: nil,
                 identifier: identifier, hint: nil, traits: nil,
                 frame: frame, children: [])
    }
}
