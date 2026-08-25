import XCTest
@testable import TrolleyMCP

final class TreeSnapshotterTests: XCTestCase {
    private func snapshot(
        _ root: FakeElement,
        options: TreeSnapshotter.Options = TreeSnapshotter.Options()
    ) -> TreeSnapshotter.Result {
        TreeSnapshotter(registry: ElementRegistry(), options: options).snapshot(root: root)
    }

    func testTextlessWrappersAreCollapsedAndTheirChildrenSpliceUpward() throws {
        let button = FakeElement(role: "AXButton", title: "저장")
        let wrapper = FakeElement(role: "AXGroup", children: [button])
        let root = FakeElement(role: "AXApplication", children: [wrapper])

        let result = snapshot(root)

        let children = try XCTUnwrap(result.tree.first?["children"]?.arrayValue)
        XCTAssertEqual(children.count, 1)
        XCTAssertEqual(children[0]["role"]?.stringValue, "AXButton", "the AXGroup should have been collapsed away")
        XCTAssertEqual(children[0]["title"]?.stringValue, "저장")
    }

    func testInterestingOnlyFalseKeepsWrappers() throws {
        let root = FakeElement(role: "AXApplication", children: [
            FakeElement(role: "AXGroup", children: [FakeElement(role: "AXButton", title: "OK")])
        ])

        let result = snapshot(root, options: .init(interestingOnly: false))

        let children = try XCTUnwrap(result.tree.first?["children"]?.arrayValue)
        XCTAssertEqual(children[0]["role"]?.stringValue, "AXGroup")
    }

    func testEveryEmittedNodeCarriesAnId() throws {
        let root = FakeElement(role: "AXApplication", children: [
            FakeElement(role: "AXButton", title: "A"),
            FakeElement(role: "AXButton", title: "B")
        ])

        let result = snapshot(root)

        let children = try XCTUnwrap(result.tree.first?["children"]?.arrayValue)
        XCTAssertEqual(children.compactMap { $0["id"]?.stringValue }.count, 2)
    }

    /// A clipped tree that doesn't say so reads to a model as "that's
    /// everything", which is how it concludes an element doesn't exist.
    func testHittingTheNodeBudgetIsReported() {
        let root = FakeElement(role: "AXApplication", children: (0..<10).map {
            FakeElement(role: "AXButton", title: "b\($0)")
        })

        let result = snapshot(root, options: .init(maxNodes: 4))

        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.nodeCount, 4)
    }

    func testUntruncatedTreeIsNotFlaggedAsTruncated() {
        let root = FakeElement(role: "AXApplication", children: [FakeElement(role: "AXButton", title: "only")])

        let result = snapshot(root, options: .init(maxNodes: 50))

        XCTAssertFalse(result.truncated)
        XCTAssertEqual(result.nodeCount, 2)
    }

    func testMaxDepthStopsDescent() throws {
        let deep = FakeElement(role: "AXButton", title: "deep")
        let mid = FakeElement(role: "AXButton", title: "mid", children: [deep])
        let root = FakeElement(role: "AXApplication", children: [mid])

        let result = snapshot(root, options: .init(maxDepth: 1))

        let children = try XCTUnwrap(result.tree.first?["children"]?.arrayValue)
        XCTAssertEqual(children[0]["title"]?.stringValue, "mid")
        XCTAssertNil(children[0]["children"], "depth 1 is the last level walked")
    }

    func testLongValuesAreTruncatedAndFlagged() throws {
        let long = String(repeating: "가", count: 300)
        let root = FakeElement(role: "AXApplication", children: [
            FakeElement(role: "AXTextArea", value: long)
        ])

        let result = snapshot(root)

        let node = try XCTUnwrap(result.tree.first?["children"]?.arrayValue?.first)
        XCTAssertEqual(node["valueTruncated"]?.boolValue, true)
        XCTAssertEqual(node["value"]?.stringValue?.count, 121, "120 characters plus the ellipsis")
    }

    func testTextFilterKeepsOnlyMatchingNodes() throws {
        let root = FakeElement(role: "AXApplication", children: [
            FakeElement(role: "AXButton", title: "Save"),
            FakeElement(role: "AXButton", title: "Cancel")
        ])

        let result = snapshot(root, options: .init(textContains: "cancel"))

        let children = try XCTUnwrap(result.tree.first?["children"]?.arrayValue)
        XCTAssertEqual(children.count, 1)
        XCTAssertEqual(children[0]["title"]?.stringValue, "Cancel")
    }

    func testRoleFilterKeepsOnlyMatchingRoles() throws {
        let root = FakeElement(role: "AXApplication", children: [
            FakeElement(role: "AXButton", title: "Save"),
            FakeElement(role: "AXStaticText", value: "Save")
        ])

        let result = snapshot(root, options: .init(role: "AXStaticText"))

        let children = try XCTUnwrap(result.tree.first?["children"]?.arrayValue)
        XCTAssertEqual(children.count, 1)
        XCTAssertEqual(children[0]["role"]?.stringValue, "AXStaticText")
    }

    /// Third-party apps don't guarantee an acyclic children graph.
    func testCyclesDoNotHang() {
        let root = FakeElement(role: "AXApplication")
        let child = FakeElement(role: "AXButton", title: "loop")
        child.fakeChildren = [root]
        root.fakeChildren = [child]

        let result = snapshot(root)

        XCTAssertEqual(result.nodeCount, 2)
    }
}
