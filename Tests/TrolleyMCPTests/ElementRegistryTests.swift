import XCTest
@testable import TrolleyMCP

final class ElementRegistryTests: XCTestCase {
    func testRegisterReturnsDistinctIdsAndResolvesBack() throws {
        let registry = ElementRegistry()
        let first = FakeElement(role: "AXButton")
        let second = FakeElement(role: "AXTextField")

        let firstID = registry.register(first)
        let secondID = registry.register(second)

        XCTAssertNotEqual(firstID, secondID)
        XCTAssertTrue(try registry.resolve(firstID) === first)
        XCTAssertTrue(try registry.resolve(secondID) === second)
    }

    func testResolvingADeadElementReportsItAsStale() {
        let registry = ElementRegistry()
        let element = FakeElement(role: "AXButton")
        let id = registry.register(element)

        element.alive = false

        XCTAssertThrowsError(try registry.resolve(id)) { error in
            XCTAssertEqual((error as? ToolError)?.code, .elementStale)
        }
    }

    func testUnknownIdIsDistinguishedFromStale() {
        XCTAssertThrowsError(try ElementRegistry().resolve("e99")) { error in
            XCTAssertEqual((error as? ToolError)?.code, .invalidElementID)
        }
    }

    /// An evicted id must not silently come back pointing at a different
    /// element, which is what id reuse would cause.
    func testIdsAreNeverReusedAfterEviction() {
        let registry = ElementRegistry(capacity: 2)
        let firstID = registry.register(FakeElement())
        registry.register(FakeElement())
        let thirdID = registry.register(FakeElement())

        XCTAssertEqual(registry.count, 2)
        XCTAssertNotEqual(firstID, thirdID)
        XCTAssertThrowsError(try registry.resolve(firstID))
    }
}
