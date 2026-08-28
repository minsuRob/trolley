import XCTest
@testable import TrolleyWidget

final class CountBadgeCopyTests: XCTestCase {
    func testNoCountHidesTheBadge() {
        XCTAssertNil(CountBadgeCopy.text(for: nil))
    }

    /// Unlike `WikiButtonCopy.title`, which keeps its zero, the badge has no room for a
    /// parenthetical "nothing open" -- a circle reading "0" reads as a stuck glitch.
    func testAnEmptyBoardHidesTheBadgeToo() {
        XCTAssertNil(CountBadgeCopy.text(for: 0))
    }

    func testANormalCountIsShownAsIs() {
        XCTAssertEqual(CountBadgeCopy.text(for: 4), "4")
        XCTAssertEqual(CountBadgeCopy.text(for: 99), "99")
    }

    func testOver99CollapsesRatherThanWideningTheCircle() {
        XCTAssertEqual(CountBadgeCopy.text(for: 100), "+99")
        XCTAssertEqual(CountBadgeCopy.text(for: 250), "+99")
    }
}
