import CoreGraphics
import XCTest
@testable import TrolleyKit

/// The tap callback and thread/run-loop wiring aren't unit-testable without
/// a real CGEventTap (same reasoning as CGMouseEventPoster's postToPid
/// branch) -- these cover the one pure, testable piece: the tagging
/// round-trip the callback relies on to tell "our own re-injected event"
/// apart from real hardware input.
final class RealInputLockTests: XCTestCase {
    private func makeEvent() throws -> CGEvent {
        try XCTUnwrap(CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: CGPoint(x: 1, y: 1),
            mouseButton: .left
        ))
    }

    func testAFreshEventIsNotMarked() throws {
        let event = try makeEvent()
        XCTAssertFalse(RealInputLock.isMarked(event))
    }

    func testMarkingAnEventMakesItReadAsMarked() throws {
        let event = try makeEvent()
        RealInputLock.mark(event)
        XCTAssertTrue(RealInputLock.isMarked(event))
    }
}
