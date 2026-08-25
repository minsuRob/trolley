import Foundation
import XCTest
@testable import TrolleyMCP

final class PromptQueueTests: XCTestCase {
    func testDrainReturnsOldestFirstAndClears() {
        let queue = PromptQueue()
        queue.submit("first")
        queue.submit("second")

        XCTAssertEqual(queue.drain().map(\.text), ["first", "second"])
        XCTAssertEqual(queue.drain(), [])
        XCTAssertEqual(queue.pendingCount, 0)
    }

    func testIdsAreUniquePerSessionEvenForRepeatedText() {
        let queue = PromptQueue()

        let first = queue.submit("again")
        _ = queue.drain()
        let second = queue.submit("again")

        XCTAssertNotEqual(first?.id, second?.id)
    }

    func testWhitespaceOnlyPromptsAreRejected() {
        let queue = PromptQueue()

        XCTAssertNil(queue.submit("   \n  "))
        XCTAssertNil(queue.submit(""))
        XCTAssertEqual(queue.pendingCount, 0)
    }

    func testSubmittedTextIsTrimmed() {
        let queue = PromptQueue()

        XCTAssertEqual(queue.submit("  열어줘\n")?.text, "열어줘")
    }

    /// Overflow means nobody is collecting; the newest instruction is the one
    /// still worth having.
    func testOverflowDropsTheOldest() {
        let queue = PromptQueue(capacity: 2)
        queue.submit("a")
        queue.submit("b")
        queue.submit("c")

        XCTAssertEqual(queue.drain().map(\.text), ["b", "c"])
    }

    func testOnChangeFiresForSubmitAndForNonEmptyDrainOnly() {
        let queue = PromptQueue()
        var changes = 0
        queue.onChange = { changes += 1 }

        _ = queue.drain()
        XCTAssertEqual(changes, 0, "an empty drain changed nothing")

        queue.submit("hello")
        XCTAssertEqual(changes, 1)
        _ = queue.drain()
        XCTAssertEqual(changes, 2)
    }

    func testRejectedPromptDoesNotFireOnChange() {
        let queue = PromptQueue()
        var changes = 0
        queue.onChange = { changes += 1 }

        queue.submit("  ")

        XCTAssertEqual(changes, 0)
    }

    /// The widget writes from the main thread while the MCP loop drains from
    /// its own; every prompt must come out exactly once.
    func testConcurrentSubmitAndDrainLoseNothing() {
        let queue = PromptQueue(capacity: 1000)
        var collected: [String] = []
        let collector = DispatchQueue(label: "collector")

        DispatchQueue.concurrentPerform(iterations: 100) { index in
            queue.submit("p\(index)")
            let taken = queue.drain().map(\.text)
            collector.sync { collected.append(contentsOf: taken) }
        }
        collected.append(contentsOf: queue.drain().map(\.text))

        XCTAssertEqual(Set(collected).count, 100)
    }
}
