import XCTest
import TrolleyKit
@testable import trolley

final class SetupCopyTests: XCTestCase {
    // MARK: - Branches

    func testLocationSaysWhatToDoAboutEachPlace() {
        XCTAssertEqual(SetupCopy.location(.applications).state, .done)
        XCTAssertNil(SetupCopy.location(.applications).button)

        // Running from the mounted image is the worst case -- every grant made
        // there dies on eject -- so it is red, not orange.
        XCTAssertEqual(SetupCopy.location(.diskImage).state, .blocked)
        XCTAssertEqual(SetupCopy.location(.diskImage).button, "옮기기")
        XCTAssertEqual(SetupCopy.location(.elsewhere).state, .actionNeeded)
    }

    func testGrantedPermissionsOfferNoButton() {
        XCTAssertNil(SetupCopy.accessibility(granted: true).button)
        XCTAssertNil(SetupCopy.screenRecording(granted: true).button)
        XCTAssertEqual(SetupCopy.accessibility(granted: false).button, "허용하기")
        XCTAssertEqual(SetupCopy.screenRecording(granted: false).button, "허용하기")
    }

    /// The macOS switch is named in brackets because the button opens a pane that
    /// uses that name -- without it you would be hunting for a row that says
    /// something else entirely.
    func testPermissionCopyNamesTheMacOSSwitchForFinding() {
        XCTAssertTrue(SetupCopy.accessibility(granted: false).detail.contains("손쉬운 사용"))
        XCTAssertTrue(SetupCopy.screenRecording(granted: false).detail.contains("화면 기록"))
    }

    /// `isEverythingReady()` requires screen recording. Calling it optional left
    /// anyone who believed the copy permanently short of "준비 완료".
    func testScreenRecordingIsNoLongerDescribedAsOptional() {
        let detail = SetupCopy.screenRecording(granted: false).detail
        XCTAssertFalse(detail.contains("없어도"))
        XCTAssertNotEqual(SetupCopy.screenRecording(granted: false).state, .optional)
    }

    func testLLMRowSaysOnlyWhetherAskingWillWork() {
        XCTAssertEqual(SetupCopy.llm(reachable: true).state, .done)
        XCTAssertEqual(SetupCopy.llm(reachable: false).state, .optional)
        XCTAssertEqual(SetupCopy.llm(reachable: nil).detail, "확인 중…")
        // Every branch keeps the button: the address is changeable whether or not
        // the current one answers -- especially when it does not.
        for reachable in [true, false, nil] {
            XCTAssertEqual(SetupCopy.llm(reachable: reachable).button, "주소 변경")
        }
    }

    func testMCPRowIsOptionalUntilItIsConnected() {
        XCTAssertEqual(SetupCopy.mcp(claudeFound: false, registered: nil).button, "명령 복사")
        XCTAssertEqual(SetupCopy.mcp(claudeFound: true, registered: false).state, .optional)
        XCTAssertEqual(SetupCopy.mcp(claudeFound: true, registered: true).state, .done)
        // Never orange or red: someone who does not use Claude Code must not be
        // looking at a warning about it.
        for registered in [nil, false, true] {
            let state = SetupCopy.mcp(claudeFound: true, registered: registered).state
            XCTAssertTrue(state == .optional || state == .done, "\(state)")
        }
    }

    // MARK: - The point of the change

    /// The rule this whole rewrite exists to hold: nothing a first-time user
    /// reads may contain developer vocabulary. `details(...)` is exempt -- that
    /// table is what you paste into a bug report.
    func testNoRowLeaksJargon() {
        let banned = ["MCP", "스코프", "AX", "http", "/Applications/", "take_prompt", "툴"]
        var rows: [SetupCopy.RowContent] = [
            SetupCopy.accessibility(granted: true), SetupCopy.accessibility(granted: false),
            SetupCopy.screenRecording(granted: true), SetupCopy.screenRecording(granted: false),
            SetupCopy.llm(reachable: true), SetupCopy.llm(reachable: false),
            SetupCopy.llm(reachable: nil)
        ]
        rows += [InstallLocation.applications, .diskImage, .elsewhere].map(SetupCopy.location)

        for row in rows {
            for word in banned {
                XCTAssertFalse(
                    row.detail.contains(word),
                    "'\(word)' 가 사용자에게 보이는 문구에 남아 있습니다: \(row.detail)"
                )
            }
        }
    }

    /// The one deliberate exception, stated as a test so nobody "fixes" it.
    func testClaudeCodeRowMayNameClaudeCode() {
        let detail = SetupCopy.mcp(claudeFound: true, registered: true).detail
        XCTAssertTrue(detail.contains("Claude Code"))
        XCTAssertFalse(detail.contains("스코프"))
    }

    func testReadyScreenPointsAtBothWaysIn() {
        let steps = SetupCopy.readySteps.joined()
        XCTAssertTrue(steps.contains("메뉴 막대"))
        XCTAssertTrue(steps.contains("폴더"))
        XCTAssertTrue(steps.contains("엔터"))
        // Says the window is disposable -- people otherwise leave it open,
        // believing closing it stops the app.
        XCTAssertTrue(SetupCopy.readyFooter.contains("닫아도"))
    }

    // MARK: - 자세히

    func testDetailsCarriesTheTechnicalFacts() {
        let rows = SetupCopy.details(
            version: "0.1.0", path: "/Applications/trolley.app/Contents/MacOS/trolley",
            model: "diffusiongemma-26B", address: "https://example.ts.net:8443", registered: true
        )
        XCTAssertEqual(rows.map(\.label), ["버전", "프로그램 경로", "모델", "서버 주소", "MCP 등록"])
        XCTAssertEqual(rows.last?.value, "등록됨 (user 스코프)")
    }

    func testDetailsSaysCheckingRatherThanGuessingWhenUnknown() {
        let rows = SetupCopy.details(
            version: "0.1.0", path: "/x", model: nil, address: "https://x", registered: nil
        )
        XCTAssertEqual(rows.first(where: { $0.label == "모델" })?.value, "확인 중…")
        XCTAssertEqual(rows.first(where: { $0.label == "MCP 등록" })?.value, "확인 중…")
    }

    func testDiagnosticsIsOneLinePerFact() {
        let text = SetupCopy.diagnostics([("버전", "0.1.0"), ("모델", "x")])
        XCTAssertEqual(text, "버전: 0.1.0\n모델: x")
    }
}

final class FirstReadyLatchTests: XCTestCase {
    func testFiresOnceOnTheFirstReady() {
        var latch = FirstReadyLatch(hasFired: false)
        XCTAssertFalse(latch.observe(isReady: false))
        XCTAssertFalse(latch.observe(isReady: false))
        XCTAssertTrue(latch.observe(isReady: true))
        XCTAssertFalse(latch.observe(isReady: true))
    }

    /// Toggling a permission off and back on must not re-introduce anything.
    func testDoesNotFireAgainAfterReadinessIsLostAndRegained() {
        var latch = FirstReadyLatch(hasFired: false)
        XCTAssertTrue(latch.observe(isReady: true))
        XCTAssertFalse(latch.observe(isReady: false))
        XCTAssertFalse(latch.observe(isReady: true))
    }

    func testAnAlreadyFiredLatchNeverFires() {
        var latch = FirstReadyLatch(hasFired: true)
        XCTAssertFalse(latch.observe(isReady: true))
        XCTAssertTrue(latch.hasFired)
    }
}
