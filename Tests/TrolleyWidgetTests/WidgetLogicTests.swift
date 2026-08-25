import Foundation
import XCTest
@testable import TrolleyWidget

final class WidgetStateMachineTests: XCTestCase {
    func testHappyPathIdleWorkingBadgeIdle() {
        var machine = WidgetStateMachine()

        XCTAssertEqual(machine.handle(.started(tool: "snapshot")), .working(tool: "snapshot"))
        XCTAssertEqual(machine.handle(.finished(isError: false)), .badge(success: true))
        XCTAssertEqual(machine.handle(.badgeTimedOut), .idle)
    }

    func testErrorShowsAFailureBadge() {
        var machine = WidgetStateMachine()
        machine.handle(.started(tool: "click"))

        XCTAssertEqual(machine.handle(.finished(isError: true)), .badge(success: false))
    }

    /// A new call must take over immediately -- no badge remnant from the
    /// previous call.
    func testNewCallDuringBadgeGoesStraightToWorking(){
        var machine = WidgetStateMachine()
        machine.handle(.started(tool: "a"))
        machine.handle(.finished(isError: false))

        XCTAssertEqual(machine.handle(.started(tool: "b")), .working(tool: "b"))
    }

    /// The badge timer from call A must not blank the display while call B runs.
    func testStaleBadgeTimerIsIgnoredWhileWorking() {
        var machine = WidgetStateMachine()
        machine.handle(.started(tool: "a"))
        machine.handle(.finished(isError: false))
        machine.handle(.started(tool: "b"))

        XCTAssertEqual(machine.handle(.badgeTimedOut), .working(tool: "b"))
    }

    func testStaleBadgeTimerInIdleIsIgnored() {
        var machine = WidgetStateMachine()

        XCTAssertEqual(machine.handle(.badgeTimedOut), .idle)
    }

    func testFinishWithoutStartIsIgnored() {
        var machine = WidgetStateMachine()

        XCTAssertEqual(machine.handle(.finished(isError: false)), .idle)
    }
}

final class ActivityLogTests: XCTestCase {
    private func entry(_ name: String, isError: Bool = false) -> ActivityLog.Entry {
        ActivityLog.Entry(name: name, finishedAt: Date(timeIntervalSinceReferenceDate: 0), isError: isError, duration: 0.1)
    }

    func testEntriesAreNewestFirst() {
        var log = ActivityLog()
        log.record(entry("first"))
        log.record(entry("second"))

        XCTAssertEqual(log.entries.map(\.name), ["second", "first"])
    }

    func testCapEvictsOldestButCountersKeepCounting() {
        var log = ActivityLog(capacity: 3)
        for index in 0..<5 {
            log.record(entry("call\(index)", isError: index == 0))
        }

        XCTAssertEqual(log.entries.count, 3)
        XCTAssertEqual(log.entries.map(\.name), ["call4", "call3", "call2"])
        XCTAssertEqual(log.totalCalls, 5)
        XCTAssertEqual(log.errorCount, 1, "the evicted error must still be counted")
    }
}
