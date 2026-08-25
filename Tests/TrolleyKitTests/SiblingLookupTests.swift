import XCTest
@testable import TrolleyKit

/// Tests the pure "given parent.children() and a matched index, find the block
/// below" decision logic, and when it should fall back.
final class SiblingLookupTests: XCTestCase {
    private func nextSibling(of target: MockAXElement, in parent: MockAXElement) -> AXElementProviding? {
        let siblings = parent.children()
        guard let index = siblings.firstIndex(where: { $0 === target }), index + 1 < siblings.count else {
            return nil
        }
        return siblings[index + 1]
    }

    func testFindsSiblingImmediatelyBelow() {
        let heading = MockAXElement(value: "제목1")
        let bodyBlock = MockAXElement(value: "")
        let parent = MockAXElement(title: "page", children: [heading, bodyBlock])

        let result = nextSibling(of: heading, in: parent)
        XCTAssertTrue(result === bodyBlock)
    }

    func testFallsBackWhenHeadingIsLastChild() {
        let heading = MockAXElement(value: "제목1")
        let parent = MockAXElement(title: "page", children: [heading])

        XCTAssertNil(nextSibling(of: heading, in: parent))
    }

    func testFallsBackWhenNoParent() {
        // Simulates root-level match with no parent tracked -- primary path
        // should be skipped in favor of focus+End+Return.
        let heading = MockAXElement(value: "제목1")
        XCTAssertNil(heading.copyAttribute("parent")) // no parent concept on the element itself
    }
}
