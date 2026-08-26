import Foundation
import XCTest
@testable import TrolleyKit

final class InstallLocationTests: XCTestCase {
    /// The case this exists for: grants made against a mounted image vanish with it.
    func testRunningFromTheDiskImageIsDetected() {
        XCTAssertEqual(
            InstallLocation.detect(bundlePath: "/Volumes/trolley 0.1.0/trolley.app", home: "/Users/x"),
            .diskImage
        )
    }

    func testInstalledInApplications() {
        XCTAssertEqual(
            InstallLocation.detect(bundlePath: "/Applications/trolley.app", home: "/Users/x"),
            .applications
        )
        XCTAssertEqual(
            InstallLocation.detect(bundlePath: "/Users/x/Applications/trolley.app", home: "/Users/x"),
            .applications
        )
    }

    func testAnywhereElse() {
        XCTAssertEqual(
            InstallLocation.detect(bundlePath: "/Users/x/Downloads/trolley.app", home: "/Users/x"),
            .elsewhere
        )
    }
}

final class ClaudeCLITests: XCTestCase {
    /// ~/.local/bin is where the current installer writes it.
    func testPrefersTheCurrentInstallerPath() {
        let found = ClaudeCLI.locate(exists: { _ in true }, home: "/Users/x")

        XCTAssertEqual(found, "/Users/x/.local/bin/claude")
    }

    func testFallsThroughToHomebrew() {
        let found = ClaudeCLI.locate(
            exists: { $0 == "/opt/homebrew/bin/claude" },
            home: "/Users/x"
        )

        XCTAssertEqual(found, "/opt/homebrew/bin/claude")
    }

    func testReportsMissingRatherThanGuessing() {
        XCTAssertNil(ClaudeCLI.locate(exists: { _ in false }, home: "/Users/x"))
    }

    /// The list of paths is a guess; the login shell owns the real PATH.
    func testFallsBackToTheLoginShell() {
        let found = ClaudeCLI.locate(
            exists: { $0 == "/custom/prefix/bin/claude" },
            home: "/Users/x",
            shellLookup: { "/custom/prefix/bin/claude\n" }
        )

        XCTAssertEqual(found, "/custom/prefix/bin/claude")
    }

    /// `command -v` answers with prose for an alias, which cannot be executed.
    func testIgnoresAShellAliasAnswer() {
        XCTAssertNil(ClaudeCLI.locate(
            exists: { _ in false },
            home: "/Users/x",
            shellLookup: { "claude: aliased to /opt/thing/claude" }
        ))
    }
}
