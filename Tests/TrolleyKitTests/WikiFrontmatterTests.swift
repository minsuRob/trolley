import XCTest
@testable import TrolleyKit

final class WikiFrontmatterTests: XCTestCase {
    private func scan(_ text: String) -> [String: WikiFrontmatter.Value] {
        WikiFrontmatter.scan(text)
    }

    // MARK: - What counts as frontmatter at all

    /// The single check that keeps `INDEX.md` (21KB) and `CLAUDE.md` (20KB) out of
    /// the index without naming them anywhere.
    func testFileNotStartingWithDelimiterHasNoFrontmatter() {
        XCTAssertTrue(scan("# INDEX — 공유 인덱스\n\n| 상태 | 분류 |\n").isEmpty)
    }

    func testLeadingBlankLineIsNotFrontmatter() {
        XCTAssertTrue(scan("\n---\n유형: 일감\n---\n").isEmpty)
    }

    /// A page whose block never closes still parses what it has rather than failing.
    /// The 60-line cap in `scan` is what stops it from running through the body.
    func testUnterminatedBlockStillYieldsFields() {
        let parsed = scan("---\n유형: 일감\n상태: 진행중\n")
        XCTAssertEqual(WikiFrontmatter.scalar(parsed["상태"]), "진행중")
    }

    /// A `---` in the body is a horizontal rule, and the block is already closed by
    /// then. Nothing after the first closing delimiter may be read as a field.
    func testDelimiterInBodyDoesNotReopenTheBlock() {
        let parsed = scan("---\n유형: 일감\n---\n\n# 제목\n\n---\n상태: 완료\n")
        XCTAssertEqual(WikiFrontmatter.scalar(parsed["유형"]), "일감")
        XCTAssertNil(parsed["상태"])
    }

    /// Written on another machine, read on this one.
    func testCarriageReturnsDoNotBreakTheDelimiters() {
        let parsed = scan("---\r\n유형: 일감\r\n상태: 진행중\r\n---\r\n# 본문\r\n")
        XCTAssertEqual(WikiFrontmatter.scalar(parsed["유형"]), "일감")
        XCTAssertEqual(WikiFrontmatter.scalar(parsed["상태"]), "진행중")
    }

    // MARK: - Scalars

    func testUnknownKeysAreIgnored() {
        let parsed = scan("---\n유형: 일감\ntags: web\naliases: x\n---\n")
        XCTAssertEqual(parsed.count, 1)
    }

    func testDoubleQuotedSummaryIsUnwrapped() {
        let parsed = scan(#"---"# + "\n" + #"요약: "서버 AI 기능 LLM 다변화 step1""# + "\n---\n")
        XCTAssertEqual(WikiFrontmatter.scalar(parsed["요약"]), "서버 AI 기능 LLM 다변화 step1")
    }

    func testSingleQuotedSummaryIsUnwrapped() {
        let parsed = scan("---\n요약: '작은따옴표'\n---\n")
        XCTAssertEqual(WikiFrontmatter.scalar(parsed["요약"]), "작은따옴표")
    }

    /// Real summaries contain colons. The value is everything after the *first*
    /// colon, so re-splitting on `:` would truncate them.
    func testSummaryContainingColonSurvives() {
        let parsed = scan(#"---"# + "\n" + #"요약: "CHAT/TODO: 수정 시 bump""# + "\n---\n")
        XCTAssertEqual(WikiFrontmatter.scalar(parsed["요약"]), "CHAT/TODO: 수정 시 bump")
    }

    /// Twelve pages in the vault carry `영역: ""`. Left unstripped it becomes an area
    /// literally named `""`, which would show up in the filter menu.
    func testEmptyQuotedValueBecomesEmpty() {
        let parsed = scan("---\n영역: \"\"\n담당: \"\"\n---\n")
        XCTAssertEqual(WikiFrontmatter.scalar(parsed["영역"]), "")
        XCTAssertEqual(WikiFrontmatter.list(parsed["영역"]), [])
    }

    // MARK: - Lists

    func testIndentedListIsCollected() {
        let parsed = scan("---\n영역:\n  - web\n  - mobile\n  - be\n우선순위: 중간\n---\n")
        XCTAssertEqual(WikiFrontmatter.list(parsed["영역"]), ["web", "mobile", "be"])
        // The field after the list must still be read: the look-ahead has to stop at
        // the first non-item line rather than swallow the rest of the block.
        XCTAssertEqual(WikiFrontmatter.scalar(parsed["우선순위"]), "중간")
    }

    func testQuotedListItemsAreUnwrapped() {
        let parsed = scan("---\n출처:\n  - \"[[2026-07-03]]\"\n---\n")
        XCTAssertEqual(WikiFrontmatter.list(parsed["출처"]), ["[[2026-07-03]]"])
    }

    /// The inline empty list, as written in every task page with no sources.
    func testInlineEmptyListIsEmpty() {
        let parsed = scan("---\n출처: []\n유형: 일감\n---\n")
        XCTAssertEqual(WikiFrontmatter.list(parsed["출처"]), [])
        XCTAssertEqual(WikiFrontmatter.scalar(parsed["유형"]), "일감")
    }

    /// A list read through the single-value accessor, which is how `영역` reaches a
    /// renderer that wants one string.
    func testScalarAccessorTakesFirstItemOfAList() {
        let parsed = scan("---\n영역:\n  - web\n  - mobile\n---\n")
        XCTAssertEqual(WikiFrontmatter.scalar(parsed["영역"]), "web")
    }

    /// A scalar read through the list accessor, the mirror of the case above.
    func testListAccessorWrapsAScalar() {
        let parsed = scan("---\n영역: web\n---\n")
        XCTAssertEqual(WikiFrontmatter.list(parsed["영역"]), ["web"])
    }

    // MARK: - The cheapness guarantee

    /// `context/sources/Feedback 허브 클러스터 인덱스 (2026-07).md` is 36KB. Indexing it
    /// must cost the frontmatter, not the file.
    func testScanStopsAtTheLineCapAndNeverReachesALongBody() {
        let body = String(repeating: "상태: 완료\n", count: 5_000)
        let parsed = WikiFrontmatter.scan("---\n유형: 일감\n---\n" + body, maxLines: 60)
        XCTAssertEqual(WikiFrontmatter.scalar(parsed["유형"]), "일감")
        XCTAssertNil(parsed["상태"])
    }

    // MARK: - A whole real page

    /// Byte-for-byte the frontmatter of
    /// `context/tasks/마크 타임라인 활동 bump (web · mobile).md`.
    func testARealPageParsesCompletely() {
        let parsed = scan("""
            ---
            유형: 일감
            상태: 완료
            분류: 기능
            영역:
              - web
              - mobile
              - be
            우선순위: 중간
            담당: minsuRob
            생성일: 2026-07-07
            갱신일: 2026-07-08
            요약: "CHAT/TODO/NOTE 수정·댓글 시 Message.updatedAt 기준 타임라인 bump (웹+모바일)"
            출처: []
            ---

            # 마크 타임라인 활동 bump
            """)
        XCTAssertEqual(WikiFrontmatter.scalar(parsed["유형"]), "일감")
        XCTAssertEqual(WikiFrontmatter.scalar(parsed["상태"]), "완료")
        XCTAssertEqual(WikiFrontmatter.scalar(parsed["분류"]), "기능")
        XCTAssertEqual(WikiFrontmatter.list(parsed["영역"]), ["web", "mobile", "be"])
        XCTAssertEqual(WikiFrontmatter.scalar(parsed["우선순위"]), "중간")
        XCTAssertEqual(WikiFrontmatter.scalar(parsed["담당"]), "minsuRob")
        XCTAssertEqual(WikiFrontmatter.scalar(parsed["생성일"]), "2026-07-07")
        XCTAssertEqual(WikiFrontmatter.scalar(parsed["갱신일"]), "2026-07-08")
        XCTAssertEqual(
            WikiFrontmatter.scalar(parsed["요약"]),
            "CHAT/TODO/NOTE 수정·댓글 시 Message.updatedAt 기준 타임라인 bump (웹+모바일)"
        )
        XCTAssertEqual(WikiFrontmatter.list(parsed["출처"]), [])
    }
}
