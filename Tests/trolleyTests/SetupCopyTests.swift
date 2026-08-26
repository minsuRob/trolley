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


    // MARK: - The point of the change

    /// The rule this whole rewrite exists to hold: nothing a first-time user
    /// reads may contain developer vocabulary. `details(...)` is exempt -- that
    /// table is what you paste into a bug report.
    func testNoRowLeaksJargon() {
        // "MCP", "스코프", "take_prompt" left the list with the code that could have
        // produced them -- a banned word with no possible source is not a test.
        let banned = ["AX", "http", "/Applications/", "툴"]
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
            model: "diffusiongemma-26B", address: "https://example.ts.net:8443"
        )
        XCTAssertEqual(rows.map(\.label), ["버전", "프로그램 경로", "모델", "서버 주소"])
        XCTAssertEqual(rows.last?.value, "https://example.ts.net:8443")
    }

    func testDetailsSaysCheckingRatherThanGuessingWhenUnknown() {
        let rows = SetupCopy.details(
            version: "0.1.0", path: "/x", model: nil, address: "https://x"
        )
        XCTAssertEqual(rows.first(where: { $0.label == "모델" })?.value, "확인 중…")
    }

    func testDiagnosticsIsOneLinePerFact() {
        let text = SetupCopy.diagnostics([("버전", "0.1.0"), ("모델", "x")])
        XCTAssertEqual(text, "버전: 0.1.0\n모델: x")
    }

    // MARK: - 리소스

    /// Everything the server actually sends, which is the case the button exists for.
    private func fullResources(
        busy: Bool = false,
        waiting: Int = 0,
        maxQueueDepth: Int? = 8,
        maxContext: Int? = 96_000,
        hardContextLimit: Int? = 120_000,
        wikiTokens: Int? = 4_100,
        lastPeakGB: Double? = 24.6,
        totalJobs: Int? = 38,
        remoteActive: Int? = 0,
        remoteLimit: Int? = 4
    ) -> [(label: String, value: String)] {
        SetupCopy.resources(
            busy: busy, waiting: waiting, maxQueueDepth: maxQueueDepth,
            maxContext: maxContext, hardContextLimit: hardContextLimit,
            wikiTokens: wikiTokens, lastPeakGB: lastPeakGB, totalJobs: totalJobs,
            remoteActive: remoteActive, remoteLimit: remoteLimit
        )
    }

    private func value(_ rows: [(label: String, value: String)], _ label: String) -> String? {
        rows.first(where: { $0.label == label })?.value
    }

    func testResourcesCoversEveryHeadroomTheServerReports() {
        XCTAssertEqual(
            fullResources().map(\.label),
            ["지금", "대기 줄", "한 번에 담는 글", "안전 상한", "메모리", "처리한 질문", "원격 모델"]
        )
    }

    func testQueueRowSaysHowManyPlacesAreLeft() {
        XCTAssertEqual(value(fullResources(waiting: 3), "대기 줄"), "8자리 중 3자리 사용 — 5자리 남음")
        // A full queue is the moment the server starts answering 503, so it must
        // read as zero left rather than going negative.
        XCTAssertEqual(value(fullResources(waiting: 9), "대기 줄"), "8자리 중 9자리 사용 — 0자리 남음")
    }

    func testContextRowSubtractsTheWikiAndGroupsDigits() {
        let line = value(fullResources(), "한 번에 담는 글")
        XCTAssertEqual(line, "96,000토큰까지 · 위키가 약 4,100토큰 · 약 91,900토큰 남음")
        XCTAssertEqual(value(fullResources(), "안전 상한"), "120,000토큰")
    }

    func testContextRowWithoutAWikiSaysTheRoomIsAllThere() {
        let line = value(fullResources(wikiTokens: nil), "한 번에 담는 글")
        XCTAssertEqual(line, "96,000토큰까지 · 위키는 함께 가지 않아 전부 남습니다")
    }

    /// The rule the whole table is held to: a number nobody sent is never invented.
    func testAnUnknownCeilingIsSaidRatherThanGuessed() {
        let rows = fullResources(maxContext: nil, hardContextLimit: nil)
        XCTAssertEqual(value(rows, "한 번에 담는 글"), "확인 중…")
        XCTAssertNil(value(rows, "안전 상한"))
        for row in rows {
            XCTAssertFalse(row.value.contains("0토큰 남음"), "없는 값을 계산했습니다: \(row.value)")
        }
    }

    /// A server that has not answered anything yet reports no peak. Rendering that
    /// as 0.0GB would claim the model is using nothing.
    func testAFreshServerSaysItsMemoryIsUnknownRatherThanZero() {
        let memory = value(fullResources(lastPeakGB: nil), "메모리")
        XCTAssertEqual(memory, "아직 답한 적이 없어 알 수 없습니다")
        XCTAssertFalse(memory?.contains("0.0GB") ?? true)
        XCTAssertEqual(value(fullResources(), "메모리"), "마지막 답변이 최고 24.6GB 썼습니다")
    }

    /// An older server sends none of these. The rows it cannot fill are dropped,
    /// not filled with zeros -- but the two it always sends stay.
    func testAnOlderServerStillGetsTheRowsItCanAnswer() {
        let rows = SetupCopy.resources(
            busy: true, waiting: 2, maxQueueDepth: nil, maxContext: nil,
            hardContextLimit: nil, wikiTokens: nil, lastPeakGB: nil,
            totalJobs: nil, remoteActive: nil, remoteLimit: nil
        )
        XCTAssertEqual(rows.map(\.label), ["지금", "대기 줄", "한 번에 담는 글", "메모리"])
        XCTAssertEqual(value(rows, "지금"), "답하는 중입니다")
        XCTAssertEqual(value(rows, "대기 줄"), "2명 기다리는 중")
    }

    func testUnreachableSaysWhyInsteadOfShowingZeros() {
        let text = SetupCopy.resourcesUnavailable("서버에 닿지 못했습니다 — 시간 초과")
        XCTAssertTrue(text.contains("읽지 못했습니다"))
        XCTAssertTrue(text.contains("시간 초과"))
        XCTAssertFalse(text.contains("0"))
    }

    func testTheButtonIsNamedForWhatItShows() {
        XCTAssertEqual(SetupCopy.detailsResourceButton, "리소스 확인")
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
