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

/// `dump-tree --frames`: the fact that makes a layout checkable without a second
/// automation stack beside trolley's own.
final class AXTreeDumperFrameTests: XCTestCase {
    func testAnElementWithNoGeometryIsSaidToHaveNone() {
        XCTAssertEqual(AXTreeDumper.frameField(position: nil, size: nil), "frame=?")
    }

    /// Halves are what a Retina screen hands back, and nobody verifies a layout to half
    /// a point.
    func testPointsAreRounded() {
        XCTAssertEqual(
            AXTreeDumper.frameField(
                position: CGPoint(x: 489.5, y: 107.4), size: CGSize(width: 939.5, height: 652)
            ),
            "frame=490,107 940x652"
        )
    }

    /// One half missing is not both missing: a column reports a size and no position.
    func testAHalfKnownFrameStillSaysWhatItKnows() {
        XCTAssertEqual(
            AXTreeDumper.frameField(position: nil, size: CGSize(width: 96, height: 24)),
            "frame=? 96x24"
        )
    }

    func testTheWalkCarriesFramesOnlyWhenAsked() {
        let element = MockAXElement(role: "AXWindow", title: "위키")
        element.attributes[AXAttr.position] = axValue(CGPoint(x: 10, y: 20), .cgPoint)
        element.attributes[AXAttr.size] = axValue(CGSize(width: 100, height: 50), .cgSize)
        let limits = AXTraversalLimits(maxDepth: 2)

        let plain = AXTreeDumper().dump(root: element, limits: limits)
        XCTAssertFalse(plain.contains("frame="), plain)

        let framed = AXTreeDumper().dump(root: element, limits: limits, includeFrames: true)
        XCTAssertTrue(framed.contains("frame=10,20 100x50"), framed)
    }

    private func axValue<T>(_ value: T, _ type: AXValueType) -> AnyObject {
        var copy = value
        return AXValueCreate(type, &copy)!
    }
}
