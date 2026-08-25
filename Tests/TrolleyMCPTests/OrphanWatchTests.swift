import Foundation
import XCTest
@testable import TrolleyMCP

final class OrphanWatchTests: XCTestCase {
    /// The normal case: the client is alive, so we keep serving.
    func testLivingParentIsNotOrphaned() {
        let watch = OrphanWatch(initialParentPID: 500)

        XCTAssertFalse(watch.isOrphaned(currentParentPID: 500))
    }

    /// The client died and left us adopted by launchd -- the case this exists for.
    func testReparentedToLaunchdIsOrphaned() {
        let watch = OrphanWatch(initialParentPID: 500)

        XCTAssertTrue(watch.isOrphaned(currentParentPID: 1))
    }

    /// Started by launchd itself: parent was 1 all along, so nothing was lost.
    func testStartedUnderLaunchdIsNeverOrphaned() {
        let watch = OrphanWatch(initialParentPID: 1)

        XCTAssertFalse(watch.isOrphaned(currentParentPID: 1), "a launchd-started server must not kill itself")
    }
}
