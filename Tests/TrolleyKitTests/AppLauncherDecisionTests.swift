import XCTest
@testable import TrolleyKit

final class FakeLocator: RunningAppLocating {
    var running: RunningAppInfo?
    var url: URL?
    var activateCalled = false
    var openCalled = false
    /// Simulates the app finishing launch after N poll calls.
    var becomesRunningAfterCalls: Int?
    private var callCount = 0

    func runningApplication(bundleID: String) -> RunningAppInfo? {
        if let becomesRunningAfterCalls {
            callCount += 1
            if callCount >= becomesRunningAfterCalls {
                return RunningAppInfo(processIdentifier: 4242, isFinishedLaunching: true)
            }
            return nil
        }
        return running
    }

    func applicationURL(bundleID: String) -> URL? { url }

    func activate(bundleID: String) -> Bool {
        activateCalled = true
        return true
    }

    func open(applicationAt url: URL) -> Bool {
        openCalled = true
        return true
    }
}

final class AppLauncherDecisionTests: XCTestCase {
    func testActivatesAlreadyRunningAppWithoutLaunching() throws {
        let locator = FakeLocator()
        locator.running = RunningAppInfo(processIdentifier: 111, isFinishedLaunching: true)
        let launcher = AppLauncher(sleeper: { _ in })

        let pid = try launcher.launchOrActivate(bundleID: "notion.id", locator: locator)

        XCTAssertEqual(pid, 111)
        XCTAssertTrue(locator.activateCalled)
        XCTAssertFalse(locator.openCalled)
    }

    func testLaunchesAndPollsUntilRunning() throws {
        let locator = FakeLocator()
        locator.url = URL(fileURLWithPath: "/Applications/Notion.app")
        locator.becomesRunningAfterCalls = 3

        let launcher = AppLauncher(sleeper: { _ in })
        let pid = try launcher.launchOrActivate(bundleID: "notion.id", locator: locator)

        XCTAssertEqual(pid, 4242)
        XCTAssertTrue(locator.openCalled)
    }

    func testThrowsWhenApplicationNotFound() {
        let locator = FakeLocator()
        let launcher = AppLauncher(sleeper: { _ in })

        XCTAssertThrowsError(try launcher.launchOrActivate(bundleID: "does.not.exist", locator: locator)) { error in
            guard case AppLauncherError.applicationNotFound = error else {
                return XCTFail("expected applicationNotFound, got \(error)")
            }
        }
    }

    func testThrowsWhenLaunchTimesOut() {
        let locator = FakeLocator()
        locator.url = URL(fileURLWithPath: "/Applications/Notion.app")
        // never becomes running
        let launcher = AppLauncher(pollIntervalSeconds: 0, sleeper: { _ in })

        XCTAssertThrowsError(
            try launcher.launchOrActivate(bundleID: "notion.id", locator: locator, timeout: 0)
        ) { error in
            guard case AppLauncherError.launchTimedOut = error else {
                return XCTFail("expected launchTimedOut, got \(error)")
            }
        }
    }
}
