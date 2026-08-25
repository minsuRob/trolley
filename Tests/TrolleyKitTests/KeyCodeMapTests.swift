import XCTest
@testable import TrolleyKit

final class KeyCodeMapTests: XCTestCase {
    func testKnownKeysMapToDocumentedCarbonKeyCodes() {
        XCTAssertEqual(KeyCodeMap.keyCode(forName: "return"), 36)
        XCTAssertEqual(KeyCodeMap.keyCode(forName: "tab"), 48)
        XCTAssertEqual(KeyCodeMap.keyCode(forName: "escape"), 53)
        XCTAssertEqual(KeyCodeMap.keyCode(forName: "left"), 123)
        XCTAssertEqual(KeyCodeMap.keyCode(forName: "right"), 124)
        XCTAssertEqual(KeyCodeMap.keyCode(forName: "down"), 125)
        XCTAssertEqual(KeyCodeMap.keyCode(forName: "up"), 126)
        XCTAssertEqual(KeyCodeMap.keyCode(forName: "end"), 119)
    }

    func testKeyLookupIsCaseInsensitive() {
        XCTAssertEqual(KeyCodeMap.keyCode(forName: "RETURN"), KeyCodeMap.keyCode(forName: "return"))
    }

    func testUnknownKeyReturnsNil() {
        XCTAssertNil(KeyCodeMap.keyCode(forName: "not-a-real-key"))
    }

    func testParseComboWithSingleModifier() {
        let combo = KeyCodeMap.parseCombo("cmd+return")
        XCTAssertEqual(combo?.key, 36)
        XCTAssertEqual(combo?.flags, .maskCommand)
    }

    func testParseComboWithNoModifier() {
        let combo = KeyCodeMap.parseCombo("return")
        XCTAssertEqual(combo?.key, 36)
        XCTAssertEqual(combo?.flags, [])
    }

    func testParseComboWithUnknownModifierReturnsNil() {
        XCTAssertNil(KeyCodeMap.parseCombo("bogus+return"))
    }
}
