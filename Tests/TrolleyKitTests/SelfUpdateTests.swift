import Foundation
import XCTest
@testable import TrolleyKit

final class SemanticVersionTests: XCTestCase {
    func testParsesPlainAndTaggedVersions() {
        XCTAssertEqual(SemanticVersion("0.1.0")?.description, "0.1.0")
        XCTAssertEqual(SemanticVersion("v1.2.3")?.description, "1.2.3")
        XCTAssertEqual(SemanticVersion(" 2.0 ")?.description, "2.0")
    }

    func testRejectsNonNumericVersions() {
        XCTAssertNil(SemanticVersion("1.2.beta"))
        XCTAssertNil(SemanticVersion("nightly"))
        XCTAssertNil(SemanticVersion(""))
        XCTAssertNil(SemanticVersion("-1.0"))
    }

    /// The reason this type exists: string comparison puts "0.10.0" before
    /// "0.2.0" and would stall every user on an old build.
    func testComparesNumericallyNotLexically() {
        XCTAssertTrue(SemanticVersion("0.2.0")! < SemanticVersion("0.10.0")!)
        XCTAssertTrue(SemanticVersion("0.1.0")! < SemanticVersion("0.2.0")!)
        XCTAssertFalse(SemanticVersion("1.0.0")! < SemanticVersion("0.9.9")!)
    }

    func testMissingComponentsReadAsZero() {
        XCTAssertEqual(SemanticVersion("1.2")!, SemanticVersion("1.2.0")!)
        XCTAssertTrue(SemanticVersion("1.2")! < SemanticVersion("1.2.1")!)
    }
}

final class GitHubReleaseTests: XCTestCase {
    private func payload(tag: String, assetNames: [String]) -> Data {
        let assets = assetNames.map {
            ["name": $0, "browser_download_url": "https://example.test/\($0)"]
        }
        return try! JSONSerialization.data(withJSONObject: ["tag_name": tag, "assets": assets])
    }

    func testExtractsVersionAndAssetURL() throws {
        let info = try GitHubRelease.parse(
            payload(tag: "v0.3.0", assetNames: ["trolley-0.3.0.pkg", "trolley-universal"]),
            assetName: "trolley-universal"
        )

        XCTAssertEqual(info.version, SemanticVersion("0.3.0")!)
        XCTAssertEqual(info.downloadURL.absoluteString, "https://example.test/trolley-universal")
    }

    /// A prefix match would pick up a sidecar like "trolley-universal.sig".
    func testRequiresAnExactAssetName() {
        XCTAssertThrowsError(
            try GitHubRelease.parse(
                payload(tag: "v0.3.0", assetNames: ["trolley-universal.sig"]),
                assetName: "trolley-universal"
            )
        )
    }

    func testRejectsMissingOrMalformedTag() {
        XCTAssertThrowsError(try GitHubRelease.parse(Data("{}".utf8), assetName: "trolley-universal"))
        XCTAssertThrowsError(
            try GitHubRelease.parse(
                payload(tag: "nightly", assetNames: ["trolley-universal"]),
                assetName: "trolley-universal"
            )
        )
        XCTAssertThrowsError(try GitHubRelease.parse(Data("not json".utf8), assetName: "trolley-universal"))
    }
}

final class UpdateDecisionTests: XCTestCase {
    private func release(_ version: String) -> ReleaseInfo {
        ReleaseInfo(version: SemanticVersion(version)!, downloadURL: URL(string: "https://example.test/x")!)
    }

    func testNewerReleaseIsOffered() {
        let decision = UpdateDecision.decide(current: SemanticVersion("0.1.0")!, latest: release("0.2.0"))

        XCTAssertEqual(decision, .available(release("0.2.0")))
    }

    func testSameVersionIsUpToDate() {
        XCTAssertEqual(
            UpdateDecision.decide(current: SemanticVersion("0.2.0")!, latest: release("0.2.0")),
            .upToDate
        )
    }

    /// A local build ahead of the newest release must not be rolled backwards.
    func testLocalBuildAheadOfReleaseIsUpToDate() {
        XCTAssertEqual(
            UpdateDecision.decide(current: SemanticVersion("0.9.0")!, latest: release("0.2.0")),
            .upToDate
        )
    }
}

final class UpdateInstallerTests: XCTestCase {
    private let feed = URL(string: "https://example.test/latest")!

    private func payload(tag: String) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "tag_name": tag,
            "assets": [["name": "trolley-universal", "browser_download_url": "https://example.test/bin"]]
        ])
    }

    /// Writable because `install` refuses to stage next to a binary it cannot replace.
    private func temporaryDestination() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("trolley-update-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("trolley")
    }

    func testRejectedSignatureNeverReplacesTheBinary() throws {
        var replaced = false
        var cleanedUp = false
        let installer = UpdateInstaller(
            fetch: { _ in self.payload(tag: "v0.2.0") },
            download: { _, _ in },
            verifySignature: { _ in throw UpdateError.signatureRejected("팀 불일치") },
            replace: { _, _ in replaced = true },
            removeTemporary: { _ in cleanedUp = true }
        )

        XCTAssertThrowsError(
            try installer.install(
                feed: feed,
                assetName: "trolley-universal",
                current: SemanticVersion("0.1.0")!,
                layout: .bareBinary(try temporaryDestination())
            )
        )
        XCTAssertFalse(replaced, "서명 검증에 실패하면 절대 교체하면 안 된다")
        XCTAssertTrue(cleanedUp, "받다 만 파일은 지워야 한다")
    }

    func testUpToDateDownloadsNothing() throws {
        var downloaded = false
        let installer = UpdateInstaller(
            fetch: { _ in self.payload(tag: "v0.1.0") },
            download: { _, _ in downloaded = true },
            verifySignature: { _ in },
            replace: { _, _ in },
            removeTemporary: { _ in }
        )

        let result = try installer.install(
            feed: feed,
            assetName: "trolley-universal",
            current: SemanticVersion("0.1.0")!,
            layout: .bareBinary(try temporaryDestination())
        )

        XCTAssertNil(result)
        XCTAssertFalse(downloaded)
    }

    func testHappyPathStagesBesideTheBinaryThenSwaps() throws {
        let destination = try temporaryDestination()
        var stagedAt: URL?
        var swappedTo: URL?
        let installer = UpdateInstaller(
            fetch: { _ in self.payload(tag: "v0.2.0") },
            download: { _, staging in stagedAt = staging },
            verifySignature: { _ in },
            replace: { staging, target in
                XCTAssertEqual(staging, stagedAt)
                swappedTo = target
            },
            removeTemporary: { _ in }
        )

        let installed = try installer.install(
            feed: feed,
            assetName: "trolley-universal",
            current: SemanticVersion("0.1.0")!,
            layout: .bareBinary(destination)
        )

        XCTAssertEqual(installed, SemanticVersion("0.2.0")!)
        XCTAssertEqual(swappedTo, destination)
        // rename(2) needs one filesystem, so staging must be a sibling.
        XCTAssertEqual(stagedAt?.deletingLastPathComponent(), destination.deletingLastPathComponent())
    }

    func testUnwritableDirectoryFailsBeforeDownloading() {
        var downloaded = false
        let installer = UpdateInstaller(
            fetch: { _ in self.payload(tag: "v0.2.0") },
            download: { _, _ in downloaded = true },
            verifySignature: { _ in },
            replace: { _, _ in },
            removeTemporary: { _ in }
        )

        XCTAssertThrowsError(
            try installer.install(
                feed: feed,
                assetName: "trolley-universal",
                current: SemanticVersion("0.1.0")!,
                layout: .bareBinary(URL(fileURLWithPath: "/usr/bin/trolley"))
            )
        )
        XCTAssertFalse(downloaded, "쓸 수 없는 곳이면 받기 전에 멈춰야 한다")
    }
}

final class InstallLayoutTests: XCTestCase {
    /// Dragged to /Applications: an update has to replace the whole bundle,
    /// because a binary signed outside it will not match its Info.plist hash.
    func testAppBundleIsDetectedFromItsExecutable() {
        let layout = InstallLayout.detect(
            executablePath: "/Applications/trolley.app/Contents/MacOS/trolley"
        )

        XCTAssertEqual(layout, .appBundle(URL(fileURLWithPath: "/Applications/trolley.app")))
        XCTAssertEqual(layout.target.lastPathComponent, "trolley.app")
    }

    func testPlainPathIsABareBinary() {
        let layout = InstallLayout.detect(executablePath: "/usr/local/bin/trolley")

        XCTAssertEqual(layout, .bareBinary(URL(fileURLWithPath: "/usr/local/bin/trolley")))
    }

    /// A development build lives three directories deep too -- .build/.../trolley --
    /// so depth alone must not be mistaken for a bundle.
    func testDeepNonBundlePathIsNotABundle() {
        let layout = InstallLayout.detect(executablePath: "/repo/.build/release/trolley")

        XCTAssertEqual(layout, .bareBinary(URL(fileURLWithPath: "/repo/.build/release/trolley")))
    }

    /// MacOS/ without the .app above it is somebody else's directory layout.
    func testMacOSDirectoryOutsideABundleIsNotABundle() {
        let layout = InstallLayout.detect(executablePath: "/opt/tools/Contents/MacOS/trolley")

        XCTAssertEqual(layout, .bareBinary(URL(fileURLWithPath: "/opt/tools/Contents/MacOS/trolley")))
    }
}
