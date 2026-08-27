import XCTest
@testable import TrolleyKit

/// Builds pages without touching a disk. Only the fields a filter reads are
/// interesting; the rest are given values that would be obviously wrong if they
/// leaked into an assertion.
func makeWikiPage(
    _ basename: String,
    type: String = "일감", status: String = "진행중", category: String = "기능",
    priority: String = "중간", assignee: String = "minsuRob", summary: String = "요약문",
    areas: [String] = ["web"], created: String = "2026-07-01", updated: String = "2026-07-02",
    folder: String = "context/tasks", modified: Date = Date(timeIntervalSince1970: 1_000)
) -> WikiPage {
    WikiPage(
        path: "/wiki/\(folder)/\(basename).md",
        relativePath: "\(folder)/\(basename).md",
        folder: folder, basename: basename,
        type: type, status: status, category: category, priority: priority,
        assignee: assignee, summary: summary, areas: areas,
        created: created, updated: updated, modified: modified
    )
}

final class WikiFilterTests: XCTestCase {
    // MARK: - Empty means "no constraint"

    /// The rule the whole options window rests on. If an empty set meant "match
    /// nothing", clearing a filter to widen a search would silently empty it.
    func testEmptyFilterMatchesEverything() {
        let filter = WikiFilter()
        XCTAssertTrue(filter.matches(makeWikiPage("가", status: "완료", assignee: "")))
        XCTAssertTrue(filter.matches(makeWikiPage("나", type: "개념", areas: [])))
    }

    func testActiveAxisExcludesOtherValues() {
        var filter = WikiFilter()
        filter.statuses = ["진행중"]
        XCTAssertTrue(filter.matches(makeWikiPage("가", status: "진행중")))
        XCTAssertFalse(filter.matches(makeWikiPage("나", status: "완료")))
    }

    /// Concept pages carry no 상태 at all, so a status filter drops them. That is
    /// correct -- 유형 is the coarse gate above it -- but it has to be deliberate.
    func testActiveAxisExcludesPagesMissingThatField() {
        var filter = WikiFilter()
        filter.statuses = ["진행중"]
        XCTAssertFalse(filter.matches(makeWikiPage("개념", type: "개념", status: "")))
        filter.statuses = []
        filter.types = ["개념"]
        XCTAssertTrue(filter.matches(makeWikiPage("개념", type: "개념", status: "")))
    }

    // MARK: - 영역 is a list

    func testAreaMatchesOnAnyOverlap() {
        var filter = WikiFilter()
        filter.areas = ["mobile"]
        XCTAssertTrue(filter.matches(makeWikiPage("가", areas: ["web", "mobile", "be"])))
        XCTAssertFalse(filter.matches(makeWikiPage("나", areas: ["web", "be"])))
    }

    func testPageWithNoAreasCannotSatisfyAnAreaFilter() {
        var filter = WikiFilter()
        filter.areas = ["web"]
        XCTAssertFalse(filter.matches(makeWikiPage("가", areas: [])))
    }

    // MARK: - 담당

    /// 36 pages in the vault are unassigned, and "show me the unowned work" is a real
    /// question. The empty string is how it is asked.
    func testEmptyAssigneeSelectsUnassigned() {
        var filter = WikiFilter()
        filter.assignees = [""]
        XCTAssertTrue(filter.matches(makeWikiPage("가", assignee: "")))
        XCTAssertFalse(filter.matches(makeWikiPage("나", assignee: "minsuRob")))
    }

    // MARK: - Text search

    func testTitleContainsSearchesTitleAndSummary() {
        var filter = WikiFilter()
        filter.titleContains = "멘션"
        XCTAssertTrue(filter.matches(makeWikiPage("모바일 컴포저 멘션")))
        XCTAssertTrue(filter.matches(makeWikiPage("무관한 제목", summary: "멘션 인프라 정리")))
        XCTAssertFalse(filter.matches(makeWikiPage("무관한 제목", summary: "무관한 요약")))
    }

    func testTitleContainsIsCaseInsensitive() {
        var filter = WikiFilter()
        filter.titleContains = "livekit"
        XCTAssertTrue(filter.matches(makeWikiPage("LiveKit 장기 유지 가능성 검토")))
    }

    // MARK: - Ordering

    /// Same order the vault's own `INDEX.md` uses. Two tools listing one wiki
    /// differently is how a person loses track of which one they are reading.
    func testBoardOrderMatchesTheVaultIndexer() {
        let pages = [
            makeWikiPage("완료-a", status: "완료", assignee: "songjein"),
            makeWikiPage("진행-중간", status: "진행중", priority: "중간", assignee: "songjein"),
            makeWikiPage("진행-최우선", status: "진행중", priority: "최우선", assignee: "songjein"),
            makeWikiPage("대기", status: "대기", assignee: "songjein"),
            makeWikiPage("미지정", status: "진행중", assignee: ""),
            makeWikiPage("보류", status: "보류", assignee: "songjein"),
            makeWikiPage("앞선핸들", status: "진행중", assignee: "aaa")
        ]
        let ordered = WikiFilter.order(pages, by: .board, today: Date()).map(\.basename)
        XCTAssertEqual(
            ordered,
            ["앞선핸들", "진행-최우선", "진행-중간", "대기", "보류", "완료-a", "미지정"]
        )
    }

    func testPriorityRankTreatsAbsentAsMiddle() {
        // 중간 is the vault's default, so a page that omits the field belongs with it
        // rather than sorted below 하순위.
        XCTAssertEqual(WikiFilter.priorityRank(""), WikiFilter.priorityRank("중간"))
        XCTAssertLessThan(WikiFilter.priorityRank("최우선"), WikiFilter.priorityRank(""))
        XCTAssertLessThan(WikiFilter.priorityRank(""), WikiFilter.priorityRank("하순위"))
    }

    func testRecentOrderIsNewestFirst() {
        let old = makeWikiPage("옛것", modified: Date(timeIntervalSince1970: 100))
        let new = makeWikiPage("새것", modified: Date(timeIntervalSince1970: 900))
        XCTAssertEqual(
            WikiFilter.order([old, new], by: .recent, today: Date()).map(\.basename),
            ["새것", "옛것"]
        )
    }

    // MARK: - Truncation reporting

    func testApplyReportsHowManyItCut() {
        var filter = WikiFilter()
        filter.maxCount = 2
        let pages = (1...5).map { makeWikiPage("p\($0)", created: "2026-07-0\($0)") }
        let (kept, dropped) = filter.apply(to: pages)
        XCTAssertEqual(kept.count, 2)
        XCTAssertEqual(dropped, 3)
    }

    func testApplyReportsNothingDroppedWhenEverythingFits() {
        let (kept, dropped) = WikiFilter().apply(to: [makeWikiPage("하나")])
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(dropped, 0)
    }

    // MARK: - Fingerprint

    /// The trap this guards: `Set.hashValue` is seeded per process and `Set` has no
    /// encoding order, so the obvious implementations produce a different string on
    /// every launch -- and a fingerprint that always changes re-sends the whole wiki
    /// every time the app starts, which is the exact cost the design avoids.
    func testFingerprintIgnoresSetInsertionOrder() {
        var a = WikiFilter()
        a.areas = ["web", "mobile", "be"]
        a.assignees = ["songjein", "minsuRob"]
        var b = WikiFilter()
        b.areas = ["be", "web", "mobile"]
        b.assignees = ["minsuRob", "songjein"]
        XCTAssertEqual(a.fingerprint, b.fingerprint)
    }

    func testFingerprintChangesWithEveryAxis() {
        let base = WikiFilter.default
        var seen: Set<String> = [base.fingerprint]
        func expectNew(_ axis: String, _ mutate: (inout WikiFilter) -> Void) {
            var copy = base
            mutate(&copy)
            XCTAssertTrue(
                seen.insert(copy.fingerprint).inserted,
                "\(axis) 축을 바꿨는데 지문이 그대로다: \(copy.fingerprint)"
            )
        }
        expectNew("유형") { $0.types = ["개념"] }
        expectNew("상태") { $0.statuses = ["완료"] }
        expectNew("분류") { $0.categories = ["버그"] }
        expectNew("영역") { $0.areas = ["web"] }
        expectNew("우선순위") { $0.priorities = ["최우선"] }
        // 미지정 is the empty string, which is not the same thing as no filter.
        expectNew("담당(미지정)") { $0.assignees = [""] }
        expectNew("담당(핸들)") { $0.assignees = ["minsuRob"] }
        expectNew("폴더") { $0.folders = ["members"] }
        expectNew("검색어") { $0.titleContains = "멘션" }
        expectNew("정체일수") { $0.staleDays = 14 }
        expectNew("최대건수") { $0.maxCount = 7 }
        expectNew("상세(메타)") { $0.detail = .metadata }
        expectNew("상세(요약)") { $0.detail = .full }
        expectNew("정렬") { $0.sort = .recent }
    }

    func testFilterSurvivesACodableRoundTrip() throws {
        var original = WikiFilter.default
        original.areas = ["web", "mobile"]
        original.staleDays = 14
        original.sort = .stale
        original.detail = .metadata
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(WikiFilter.self, from: data)
        XCTAssertEqual(restored, original)
        XCTAssertEqual(restored.fingerprint, original.fingerprint)
    }

    // MARK: - Migration

    /// A canary on a value that changes behaviour for everyone who never customised it:
    /// `WikiSettings` removes a stored filter equal to the default, so those people have
    /// no saved key and simply get whatever this says.
    func testDefaultIsInProgressAndWaitingAsTitles() {
        XCTAssertEqual(WikiFilter.default.statuses, ["진행중", "대기"])
        XCTAssertEqual(WikiFilter.default.detail, .titles)
        // 진행중+대기 is 84 pages on the real vault, so a cap of 80 would cut it.
        XCTAssertGreaterThan(WikiFilter.default.maxCount, 84)
    }

    /// The whole reason `WikiFilter` has a hand-written decoder.
    ///
    /// These are the bytes an older build actually wrote, as a literal rather than as
    /// something re-encoded here -- re-encoding would pin today's shape and pass whatever
    /// the decoder did. The synthesized initializer requires every key, so without the
    /// custom one this JSON throws, `WikiSettings` swallows it with `try?`, and the
    /// person's entire saved filter silently reverts to default.
    private func decode(_ json: String) throws -> WikiFilter {
        try JSONDecoder().decode(WikiFilter.self, from: Data(json.utf8))
    }

    func testLegacyIncludeSummaryTrueBecomesFull() throws {
        let filter = try decode("""
            {"types":[],"statuses":["진행중"],"categories":[],"areas":[],"priorities":[],
             "assignees":[],"folders":["context/tasks"],"titleContains":"","maxCount":80,
             "includeSummary":true,"sort":"board"}
            """)
        XCTAssertEqual(filter.detail, .full)
        XCTAssertEqual(filter.statuses, ["진행중"])
        XCTAssertEqual(filter.maxCount, 80)
    }

    func testLegacyIncludeSummaryFalseBecomesMetadata() throws {
        let filter = try decode("""
            {"types":[],"statuses":[],"categories":[],"areas":[],"priorities":[],
             "assignees":[],"folders":[],"titleContains":"","maxCount":40,
             "includeSummary":false,"sort":"recent"}
            """)
        // Not `.titles`: the boolean could only ever say "not full", so that is all it
        // may be read as meaning.
        XCTAssertEqual(filter.detail, .metadata)
    }

    func testDetailWinsWhenBothKeysArePresent() throws {
        let filter = try decode("""
            {"maxCount":40,"includeSummary":true,"detail":"titles","sort":"board"}
            """)
        XCTAssertEqual(filter.detail, .titles)
    }

    /// Every axis falls back rather than throwing, so the *next* axis added here does
    /// not have to repeat this migration.
    func testAnEmptyObjectDecodesToUsableDefaults() throws {
        let filter = try decode("{}")
        XCTAssertEqual(filter.detail, .full)
        XCTAssertEqual(filter.sort, .board)
        XCTAssertTrue(filter.statuses.isEmpty)
        // Not the empty set. Empty means "no constraint", so defaulting a *missing*
        // folder key to it would quietly widen an old filter into members/ and logs/.
        XCTAssertEqual(filter.folders, Set(WikiIndex.indexableFolders))
    }

    /// An app rolled back by `trolley update` reads this same defaults domain with the
    /// old synthesized decoder, which throws on a missing key.
    func testEncodedFilterStillCarriesIncludeSummaryForOlderBuilds() throws {
        for (detail, expected) in [(WikiFilter.Detail.full, true),
                                   (.metadata, false), (.titles, false)] {
            let data = try JSONEncoder().encode(WikiFilter(detail: detail))
            let raw = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            XCTAssertEqual(raw["includeSummary"] as? Bool, expected, "\(detail)")
            XCTAssertEqual(raw["detail"] as? String, detail.rawValue)
        }
    }
}

final class WikiTimelineTests: XCTestCase {
    private let page = """
        ---
        유형: 일감
        ---

        # 제목

        ## 배경
        - 2020-01-01: 이건 타임라인이 아니라 배경의 날짜다

        ## 타임라인
        - 2026-07-07: 시작
        - 2026-07-20: 마지막 작업
        - 2026-07-14: 순서가 뒤집힌 항목

        ## 관련
        - 2030-01-01: 관련 절의 날짜
        """

    /// The section is append-only by convention, not by enforcement, so the max is
    /// the honest answer and the last line is not.
    func testTakesTheMaximumDateNotTheLastLine() {
        XCTAssertEqual(WikiTimeline.lastDate(in: page), "2026-07-20")
    }

    /// Dates under 배경 and 관련 are prose. Counting them would make a page look
    /// active because someone cited an old document in it.
    func testIgnoresDatesOutsideTheTimelineSection() {
        XCTAssertNotEqual(WikiTimeline.lastDate(in: page), "2030-01-01")
    }

    func testNilWhenThereIsNoTimeline() {
        XCTAssertNil(WikiTimeline.lastDate(in: "# 제목\n\n## 배경\n- 아무것도 없음\n"))
    }

    func testIgnoresBulletsThatAreNotDates() {
        let text = "## 타임라인\n- 날짜 아님: 어쩌고\n- 2026-07-07: 진짜\n"
        XCTAssertEqual(WikiTimeline.lastDate(in: text), "2026-07-07")
    }

    func testDaysSinceCountsWholeDays() {
        var components = DateComponents()
        components.year = 2026; components.month = 7; components.day = 21
        let today = Calendar.current.date(from: components)!
        XCTAssertEqual(WikiTimeline.daysSince("2026-07-07", today: today), 14)
    }

    /// A malformed date must read as "no information", never as "infinitely stale" --
    /// otherwise one typo puts a page at the top of the stale list forever.
    func testDaysSinceIsNilForAMalformedDate() {
        XCTAssertNil(WikiTimeline.daysSince("2026-7-7", today: Date()))
        XCTAssertNil(WikiTimeline.daysSince("어제", today: Date()))
    }
}
