import XCTest
@testable import TrolleyKit

final class AXTreeWalkerTests: XCTestCase {
    func testWalkVisitsAllNodesInDepthFirstOrder() {
        let grandchild = MockAXElement(title: "grandchild")
        let child = MockAXElement(title: "child", children: [grandchild])
        let root = MockAXElement(title: "root", children: [child])

        var visitedTitles: [String] = []
        AXTreeWalker().walk(root: root, limits: AXTraversalLimits()) { element, _, _ in
            visitedTitles.append(element.stringAttribute(AXAttr.title) ?? "")
        }

        XCTAssertEqual(visitedTitles, ["root", "child", "grandchild"])
    }

    func testMaxDepthStopsDescending() {
        let grandchild = MockAXElement(title: "grandchild")
        let child = MockAXElement(title: "child", children: [grandchild])
        let root = MockAXElement(title: "root", children: [child])

        var visitedTitles: [String] = []
        AXTreeWalker().walk(root: root, limits: AXTraversalLimits(maxDepth: 1)) { element, _, _ in
            visitedTitles.append(element.stringAttribute(AXAttr.title) ?? "")
        }

        XCTAssertEqual(visitedTitles, ["root", "child"])
    }

    func testMaxNodesCapsTotalVisits() {
        let children = (0..<10).map { MockAXElement(title: "child\($0)") }
        let root = MockAXElement(title: "root", children: children)

        var count = 0
        AXTreeWalker().walk(root: root, limits: AXTraversalLimits(maxNodes: 3)) { _, _, _ in
            count += 1
        }

        XCTAssertEqual(count, 3)
    }

    func testCycleGuardPreventsInfiniteLoop() {
        let root = MockAXElement(title: "root")
        root.mockChildren = [root] // self-referencing cycle

        var count = 0
        AXTreeWalker().walk(root: root, limits: AXTraversalLimits()) { _, _, _ in
            count += 1
        }

        XCTAssertEqual(count, 1)
    }

    func testFindAllReturnsMatchesWithParent() {
        let target = MockAXElement(value: "제목1")
        let parent = MockAXElement(title: "parent", children: [target])
        let root = MockAXElement(title: "root", children: [parent])

        let matches = AXTreeWalker().findAll(
            root: root,
            query: ElementQuery(textContains: "제목1"),
            limits: AXTraversalLimits()
        )

        XCTAssertEqual(matches.count, 1)
        XCTAssertTrue(matches[0].parent === parent)
    }
}
