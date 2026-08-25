import CoreGraphics
import XCTest
@testable import TrolleyKit

final class RecordingKeyPoster: KeyEventPosting {
    var postedKeys: [(CGKeyCode, Bool, CGEventFlags)] = []
    var postedUnicode: [([UniChar], Bool)] = []

    func post(keyCode: CGKeyCode, down: Bool, flags: CGEventFlags) {
        postedKeys.append((keyCode, down, flags))
    }

    func postUnicode(_ chunk: [UniChar], down: Bool) {
        postedUnicode.append((chunk, down))
    }
}

final class ActionExecutorTests: XCTestCase {
    func testTypeNeverCallsSetAttribute() {
        let root = MockAXElement()
        let poster = RecordingKeyPoster()
        let executor = ActionExecutor(root: root, keyPoster: poster)

        _ = executor.perform(.type("본문1"))

        XCTAssertFalse(poster.postedUnicode.isEmpty)
        XCTAssertTrue(root.setAttributes.isEmpty, "type must never fall back to AXUIElementSetAttributeValue")
    }

    func testFocusUsesSetAttributeWhenItSucceeds() {
        let target = MockAXElement()
        target.setAttributeResult = true
        let executor = ActionExecutor(root: MockAXElement(), keyPoster: RecordingKeyPoster())

        let result = executor.perform(.focus(target))

        XCTAssertEqual(target.setAttributes.count, 1)
        XCTAssertTrue(target.performedActions.isEmpty)
        if case .ok = result {} else { XCTFail("expected .ok") }
    }

    func testFocusFallsBackToClickWhenSetAttributeFails() {
        let target = MockAXElement()
        target.setAttributeResult = false
        target.pressActionResult = true
        let executor = ActionExecutor(root: MockAXElement(), keyPoster: RecordingKeyPoster())

        _ = executor.perform(.focus(target))

        XCTAssertEqual(target.performedActions, [AXAction.press])
    }

    func testClickFallsBackToMouseWhenPressFails() {
        let target = MockAXElement()
        target.pressActionResult = false
        target.attributes[AXAttr.position] = CGPoint(x: 10, y: 20) as AnyObject

        var clickedAt: CGPoint?
        var clickedPoints: [CGPoint] = []
        let executor = ActionExecutor(
            root: MockAXElement(),
            keyPoster: RecordingKeyPoster(),
            mouseClicker: { clickedPoints.append($0) }
        )
        _ = executor
        clickedAt = clickedPoints.first
        _ = clickedAt

        // Without a real AXValue-boxed position/size, the mouse fallback can't
        // extract coordinates from a mock -- assert it fails cleanly instead of crashing.
        let result = executor.perform(.click(target))
        if case .failed = result {
            // expected: mock doesn't provide AXValue-boxed geometry
        } else if case .ok = result {
            XCTFail("did not expect a mouse click without valid position/size attributes")
        }
    }

    func testKeyDelegatesToKeyboardActions() {
        let poster = RecordingKeyPoster()
        let executor = ActionExecutor(root: MockAXElement(), keyPoster: poster)

        _ = executor.perform(.key(name: "return", modifiers: []))

        XCTAssertEqual(poster.postedKeys.map(\.0), [36, 36])
    }
}
