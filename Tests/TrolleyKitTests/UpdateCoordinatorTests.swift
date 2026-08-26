import Foundation
import XCTest
@testable import TrolleyKit

/// The four axes of `UpdatePolicy` exist so the shipping default is expressible.
/// If they ever collapse into one flag these are the tests that notice.
final class UpdatePolicyTests: XCTestCase {
    func testDefaultFetchesWithoutAskingButWaitsToInstall() {
        let policy = UpdatePolicy.default

        XCTAssertTrue(policy.checksAutomatically)
        XCTAssertTrue(policy.downloadsAutomatically)
        XCTAssertFalse(policy.installsAutomatically, "설치는 사람이 누를 때만이다")
        XCTAssertEqual(policy.interval, 6 * 60 * 60)
    }
}

final class UpdateStatusTests: XCTestCase {
    /// Only a finished download can be acted on. Offering a button for the other
    /// states would promise something pressing it cannot deliver.
    func testOnlyADownloadedUpdateOffersAnAction() {
        XCTAssertNotNil(UpdateStatus.downloaded(SemanticVersion("0.3.0")!).actionTitle)
        XCTAssertNil(UpdateStatus.available(SemanticVersion("0.3.0")!).actionTitle)
        XCTAssertNil(UpdateStatus.checking.actionTitle)
        XCTAssertNil(UpdateStatus.upToDate.actionTitle)
        XCTAssertNil(UpdateStatus.failed("x").actionTitle)
    }

    /// The pet's badge covers its face, so it may only appear for something the
    /// user can actually finish.
    func testOnlyADownloadedUpdateTakesTheWidgetsFace() {
        XCTAssertTrue(UpdateStatus.downloaded(SemanticVersion("0.3.0")!).deservesAttention)
        XCTAssertFalse(UpdateStatus.available(SemanticVersion("0.3.0")!).deservesAttention)
        XCTAssertFalse(UpdateStatus.checking.deservesAttention)
    }

    func testEveryStateSaysSomethingAPersonCanRead() {
        let states: [UpdateStatus] = [
            .upToDate, .checking,
            .available(SemanticVersion("0.3.0")!),
            .downloading(SemanticVersion("0.3.0")!),
            .downloaded(SemanticVersion("0.3.0")!),
            .failed("서버가 응답하지 않습니다")
        ]
        for state in states {
            XCTAssertFalse(state.summary.isEmpty, "\(state) 에 설명이 없습니다")
        }
    }
}

final class UpdateCoordinatorTests: XCTestCase {
    private let feed = URL(string: "https://example.test/latest")!

    private func payload(tag: String) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "tag_name": tag,
            "assets": [["name": "trolley-app.zip", "browser_download_url": "https://example.test/bin"]]
        ])
    }

    private func destination() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("trolley-coordinator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("trolley")
    }

    /// Collects every status the coordinator publishes, synchronously.
    private func makeCoordinator(
        installer: UpdateInstaller,
        current: String = "0.1.0",
        policy: UpdatePolicy = .default
    ) throws -> (UpdateCoordinator, () -> [UpdateStatus]) {
        var seen: [UpdateStatus] = []
        let coordinator = UpdateCoordinator(
            policy: policy,
            installer: installer,
            feed: feed,
            assetName: "trolley-app.zip",
            current: SemanticVersion(current)!,
            layout: .bareBinary(try destination()),
            // Inline rather than hopping to the main queue: the test has no run
            // loop to pump, and the ordering under test is the coordinator's.
            toMain: { work in work() }
        )
        coordinator.onChange = { seen.append($0) }
        return (coordinator, { seen })
    }

    private func drain(_ coordinator: UpdateCoordinator) {
        coordinator.checkNow()
        // checkNow hops onto its own serial queue; a barrier is how we wait for it
        // without a sleep.
        let done = expectation(description: "checked")
        DispatchQueue(label: "wait").async {
            Thread.sleep(forTimeInterval: 0.05)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    /// The whole point of the default policy: fetch without being asked, then
    /// stop and wait for a person.
    func testDefaultPolicyDownloadsButDoesNotInstall() throws {
        var replaced = false
        let installer = UpdateInstaller(
            fetch: { _ in self.payload(tag: "v0.2.0") },
            download: { _, _ in },
            verifySignature: { _ in },
            replace: { _, _ in replaced = true },
            removeTemporary: { _ in }
        )
        let (coordinator, seen) = try makeCoordinator(installer: installer)

        drain(coordinator)

        XCTAssertFalse(replaced, "기본 정책은 자동 설치하지 않는다")
        XCTAssertEqual(seen().last, .downloaded(SemanticVersion("0.2.0")!))
    }

    /// Requirement 6 of the brief, and the reason `.noRelease` is not `.failed`:
    /// before the first release, an empty feed is the software working.
    func testNoReleaseIsCalmNotAnError() throws {
        let installer = UpdateInstaller(
            fetch: { _ in throw UpdateError.noRelease },
            download: { _, _ in },
            verifySignature: { _ in },
            replace: { _, _ in },
            removeTemporary: { _ in }
        )
        let (coordinator, seen) = try makeCoordinator(installer: installer)

        drain(coordinator)

        XCTAssertEqual(seen().last, .upToDate)
        for status in seen() {
            if case .failed = status { XCTFail("릴리스 없음이 오류로 새어 나갔다") }
        }
    }

    /// A real failure still has to reach the user.
    func testGenuineFailureIsReported() throws {
        let installer = UpdateInstaller(
            fetch: { _ in throw UpdateError.feedUnreadable("HTTP 500") },
            download: { _, _ in },
            verifySignature: { _ in },
            replace: { _, _ in },
            removeTemporary: { _ in }
        )
        let (coordinator, seen) = try makeCoordinator(installer: installer)

        drain(coordinator)

        guard case .failed = seen().last else {
            return XCTFail("실패가 보고되지 않았다: \(String(describing: seen().last))")
        }
    }

    func testAlreadyCurrentNeverDownloads() throws {
        var downloaded = false
        let installer = UpdateInstaller(
            fetch: { _ in self.payload(tag: "v0.1.0") },
            download: { _, _ in downloaded = true },
            verifySignature: { _ in },
            replace: { _, _ in },
            removeTemporary: { _ in }
        )
        let (coordinator, seen) = try makeCoordinator(installer: installer)

        drain(coordinator)

        XCTAssertFalse(downloaded)
        XCTAssertEqual(seen().last, .upToDate)
    }

    /// The button's half of the split: nothing staged means nothing to install,
    /// and it must say so rather than pretending it worked.
    func testInstallingWithNothingStagedReportsNothing() throws {
        let installer = UpdateInstaller(
            fetch: { _ in throw UpdateError.noRelease },
            download: { _, _ in },
            verifySignature: { _ in },
            replace: { _, _ in XCTFail("교체할 것이 없는데 교체했다") },
            removeTemporary: { _ in }
        )
        let (coordinator, _) = try makeCoordinator(installer: installer)

        XCTAssertNil(try coordinator.installStaged())
    }

    /// Staged bytes must be swapped in only on the explicit call.
    func testInstallStagedSwapsExactlyOnce() throws {
        var replacements = 0
        let installer = UpdateInstaller(
            fetch: { _ in self.payload(tag: "v0.2.0") },
            download: { _, _ in },
            verifySignature: { _ in },
            replace: { _, _ in replacements += 1 },
            removeTemporary: { _ in }
        )
        let (coordinator, _) = try makeCoordinator(installer: installer)
        drain(coordinator)

        XCTAssertEqual(try coordinator.installStaged(), SemanticVersion("0.2.0")!)
        XCTAssertEqual(replacements, 1)
        XCTAssertNil(try coordinator.installStaged(), "두 번째 호출은 할 일이 없다")
        XCTAssertEqual(replacements, 1)
    }

    /// Quitting throws the download away rather than leaving a whole app bundle
    /// beside the installation.
    func testDiscardingRemovesTheStagedCopy() throws {
        var removed: [URL] = []
        let installer = UpdateInstaller(
            fetch: { _ in self.payload(tag: "v0.2.0") },
            download: { _, _ in },
            verifySignature: { _ in },
            replace: { _, _ in XCTFail("버리라고 했는데 설치했다") },
            removeTemporary: { removed.append($0) }
        )
        let (coordinator, _) = try makeCoordinator(installer: installer)
        drain(coordinator)
        removed.removeAll()

        coordinator.discardStaged()

        XCTAssertEqual(removed.count, 1)
    }
}

final class TrolleyRelaunchTests: XCTestCase {
    /// `open -a` on a bundle whose process is still alive just activates the old
    /// copy. Waiting for our own pid to go is what makes the relaunch real.
    func testRelaunchWaitsForThisProcessToExitFirst() {
        let argv = TrolleyRelaunch.command(bundlePath: "/Applications/trolley.app", pid: 4242)
        let script = argv.last!

        XCTAssertTrue(script.contains("kill -0 4242"), "죽기를 기다리지 않는다: \(script)")
        let waitIndex = script.range(of: "kill -0 4242")!.lowerBound
        let openIndex = script.range(of: "/usr/bin/open")!.lowerBound
        XCTAssertTrue(waitIndex < openIndex, "여는 것이 기다리는 것보다 앞선다")
    }

    /// A development copy lives under a path with spaces often enough that an
    /// unquoted one would be found only by someone whose update silently failed.
    func testPathsWithSpacesAndQuotesSurvive() {
        XCTAssertEqual(TrolleyRelaunch.shellQuoted("/A B/trolley.app"), "'/A B/trolley.app'")
        XCTAssertEqual(
            TrolleyRelaunch.shellQuoted("/it's/trolley.app"),
            "'/it'\\''s/trolley.app'"
        )
    }

    func testTheLoopIsBoundedSoAStuckPidCannotSpinForever() {
        let script = TrolleyRelaunch.command(bundlePath: "/x.app", pid: 1).last!

        XCTAssertTrue(script.contains("seq 1 100"), "무한 루프다: \(script)")
    }
}
