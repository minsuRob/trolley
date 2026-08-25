import XCTest
@testable import TrolleyKit

final class ElementMatcherTests: XCTestCase {
    func testMatchesByValueSubstring() {
        let element = MockAXElement(value: "제목1 heading block")
        XCTAssertTrue(ElementMatcher.matches(element, query: ElementQuery(textContains: "제목1")))
    }

    func testMatchesCaseInsensitively() {
        let element = MockAXElement(title: "Hello World")
        XCTAssertTrue(ElementMatcher.matches(element, query: ElementQuery(textContains: "hello")))
    }

    func testDoesNotMatchUnrelatedText() {
        let element = MockAXElement(value: "본문1")
        XCTAssertFalse(ElementMatcher.matches(element, query: ElementQuery(textContains: "제목1")))
    }

    func testRoleFilterExcludesWrongRole() {
        let element = MockAXElement(role: "AXGroup", value: "제목1")
        XCTAssertFalse(ElementMatcher.matches(
            element,
            query: ElementQuery(textContains: "제목1", roleFilter: "AXStaticText")
        ))
    }

    func testEmptyQueryNeverMatches() {
        let element = MockAXElement(value: "anything")
        XCTAssertFalse(ElementMatcher.matches(element, query: ElementQuery(textContains: "")))
    }

    func testRankByLeafinessPrefersFewestChildren() {
        let leaf = MockAXElement(value: "제목1")
        let container = MockAXElement(value: "제목1 container", children: [MockAXElement(), MockAXElement()])
        let ranked = ElementMatcher.rankByLeafiness([container, leaf])
        XCTAssertTrue(ranked.first === leaf)
    }
}
