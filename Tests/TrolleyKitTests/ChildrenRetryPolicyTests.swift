import XCTest
@testable import TrolleyKit

/// The retry loop in `SystemAXElement.children()` exists only for
/// Chromium/Electron; at ~40ms per node it dominates any native-app tree walk,
/// so callers need to be able to opt out.
final class ChildrenRetryPolicyTests: XCTestCase {
    func testFastPolicyQueriesOnceWithNoDelay() {
        XCTAssertEqual(AXChildrenRetryPolicy.fast.attempts, 1)
        XCTAssertEqual(AXChildrenRetryPolicy.fast.delayMicroseconds, 0)
    }

    func testThoroughPolicyRetries() {
        XCTAssertGreaterThan(AXChildrenRetryPolicy.thorough.attempts, 1)
        XCTAssertGreaterThan(AXChildrenRetryPolicy.thorough.delayMicroseconds, 0)
    }

    /// Zero attempts would skip the query entirely and report every node as a leaf.
    func testAttemptsAreClampedToAtLeastOne() {
        XCTAssertEqual(AXChildrenRetryPolicy(attempts: 0, delayMicroseconds: 0).attempts, 1)
        XCTAssertEqual(AXChildrenRetryPolicy(attempts: -5, delayMicroseconds: 0).attempts, 1)
    }

    /// Existing CLI callers construct elements without naming a policy and must
    /// keep the Chromium-tolerant behavior they were written against.
    func testDefaultPolicyIsThorough() {
        let element = SystemAXElement.application(pid: 0)

        XCTAssertEqual(element.childrenRetryPolicy.attempts, AXChildrenRetryPolicy.thorough.attempts)
    }
}
