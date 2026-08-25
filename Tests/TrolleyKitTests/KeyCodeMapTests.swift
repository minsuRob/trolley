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

    // MARK: - asciiKeyStroke

    private func stroke(_ character: Character) -> (key: CGKeyCode, shift: Bool)? {
        KeyCodeMap.asciiKeyStroke(for: character)
    }

    /// Tuples aren't Equatable, so compare the pair through one assertion site.
    private func assertStroke(
        _ character: Character,
        _ key: CGKeyCode,
        shift: Bool,
        line: UInt = #line
    ) {
        guard let actual = stroke(character) else {
            return XCTFail("no keystroke for \(character)", line: line)
        }
        XCTAssertEqual(actual.key, key, "key code for \(character)", line: line)
        XCTAssertEqual(actual.shift, shift, "shift for \(character)", line: line)
    }

    func testLettersMapToTheirKeyPositionAndShiftForCapitals() {
        assertStroke("a", 0, shift: false)
        assertStroke("A", 0, shift: true)
        assertStroke("z", 6, shift: false)
        assertStroke("Z", 6, shift: true)
    }

    func testDigitsAndWhitespace() {
        assertStroke("1", 18, shift: false)
        assertStroke("0", 29, shift: false)
        assertStroke(" ", 49, shift: false)
        assertStroke("\n", 36, shift: false)
        assertStroke("\t", 48, shift: false)
    }

    /// The digit row is not in numeric key-code order, so the shifted symbols
    /// are the easy ones to get wrong.
    func testShiftedDigitSymbolsUseTheRightPhysicalKey() {
        assertStroke("!", 18, shift: true)
        assertStroke("%", 23, shift: true)
        assertStroke("^", 22, shift: true)
        assertStroke("&", 26, shift: true)
        assertStroke("*", 28, shift: true)
        assertStroke("(", 25, shift: true)
        assertStroke(")", 29, shift: true)
    }

    func testPunctuationPairsShareAKeyPosition() {
        XCTAssertEqual(stroke(",")?.key, stroke("<")?.key)
        XCTAssertEqual(stroke("<")?.shift, true)
        XCTAssertEqual(stroke("/")?.key, stroke("?")?.key)
        XCTAssertEqual(stroke("'")?.key, stroke("\"")?.key)
    }

    func testNonASCIIHasNoKeystroke() {
        XCTAssertNil(stroke("한"))
        XCTAssertNil(stroke("€"))
        XCTAssertNil(stroke("🎉"))
    }
}
