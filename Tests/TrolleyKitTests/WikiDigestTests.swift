import XCTest
@testable import TrolleyKit

final class WikiDigestTests: XCTestCase {
    private func render(
        _ pages: [WikiPage], filter: WikiFilter = WikiFilter(), budget: Int = 9_000
    ) -> WikiDigest {
        WikiDigestRenderer.render(
            pages: pages, filter: filter, rootName: "markhub-llm-wiki", budgetCharacters: budget
        )
    }

    // MARK: - The line

    func testLineCarriesEveryFieldInOrder() {
        let page = makeWikiPage(
            "모바일 컴포저 멘션", status: "진행중", category: "기능", priority: "중간",
            assignee: "minsuRob", summary: "모바일 컴포저에 사람 언급 추가",
            areas: ["mobile"], updated: "2026-07-08"
        )
        XCTAssertEqual(
            WikiDigestRenderer.line(for: page, includeSummary: true),
            "- [[모바일 컴포저 멘션]] · 진행중 · 기능 · 중간 · mobile · minsuRob · 2026-07-08 · 모바일 컴포저에 사람 언급 추가"
        )
    }

    /// `[[…]]` is the vault's own link syntax and the basename is its identity key, so
    /// a title written this way is one `wiki_read` can resolve and one a person can
    /// paste straight into Obsidian.
    func testTitleIsWrappedAsAWikiLink() {
        let line = WikiDigestRenderer.line(for: makeWikiPage("위키맵 개선"), includeSummary: false)
        XCTAssertTrue(line.contains("[[위키맵 개선]]"))
    }

    /// Same joiner the vault's own indexer uses, so a multi-area page reads the same
    /// in both places.
    func testListAreasAreJoinedWithTheVaultsSeparator() {
        let line = WikiDigestRenderer.line(
            for: makeWikiPage("가", areas: ["web", "mobile", "be"]), includeSummary: false
        )
        XCTAssertTrue(line.contains("web·mobile·be"))
    }

    func testMissingFieldsRenderAsDashes() {
        let line = WikiDigestRenderer.line(
            for: makeWikiPage("가", status: "", category: "", priority: "", assignee: "",
                              areas: [], updated: ""),
            includeSummary: false
        )
        XCTAssertEqual(line, "- [[가]] · - · - · - · - · - · -")
    }

    /// The biggest lever on cost: dropping summaries fits every page in the vault
    /// inside the same budget that otherwise holds about two thirds of them.
    func testExcludingSummariesShortensTheLine() {
        let page = makeWikiPage("가", summary: "제법 긴 한 줄 요약이 여기에 들어간다")
        XCTAssertLessThan(
            WikiDigestRenderer.line(for: page, includeSummary: false).count,
            WikiDigestRenderer.line(for: page, includeSummary: true).count
        )
    }

    // MARK: - Budget

    func testNeverExceedsTheBudget() {
        let pages = (1...200).map { makeWikiPage("페이지 번호 \($0)", created: "2026-07-01") }
        for budget in [300, 500, 1_000, 4_000, 9_000] {
            let digest = render(pages, budget: budget)
            XCTAssertLessThanOrEqual(
                digest.characters, budget, "예산 \(budget)자를 넘었다: \(digest.characters)자"
            )
        }
    }

    /// Half a line is a page the model can neither name nor look up.
    func testTruncationHappensBetweenRecordsNeverInsideOne() {
        let pages = (1...200).map { makeWikiPage("페이지 \($0)") }
        let digest = render(pages, budget: 1_200)
        for line in digest.text.split(whereSeparator: \.isNewline) where line.hasPrefix("- ") {
            XCTAssertTrue(line.contains("]]"), "잘린 줄: \(line)")
        }
    }

    /// The single most important guarantee here. A quietly shortened list reads to the
    /// model as a complete one, and it will answer "that is all of them" about work it
    /// was never shown.
    func testTruncationIsAnnouncedWithTheExactCount() {
        let pages = (1...200).map { makeWikiPage("페이지 \($0)") }
        let digest = render(pages, budget: 1_200)
        XCTAssertTrue(digest.wasTruncated)
        XCTAssertTrue(
            digest.text.contains("\(digest.total - digest.matched)건 생략됨"),
            "생략 건수가 본문에 없다: \(digest.text.suffix(120))"
        )
    }

    func testNothingIsAnnouncedWhenNothingWasCut() {
        let digest = render((1...5).map { makeWikiPage("페이지 \($0)") })
        XCTAssertFalse(digest.wasTruncated)
        XCTAssertFalse(digest.text.contains("생략됨"))
    }

    /// The header count must describe the list that was actually sent, not the one
    /// that matched.
    func testHeaderCountReflectsWhatWasRenderedOverWhatMatched() {
        let pages = (1...200).map { makeWikiPage("페이지 \($0)") }
        let digest = render(pages, budget: 1_200)
        XCTAssertTrue(
            digest.text.contains("(\(digest.matched)/\(digest.total)건)"),
            "머리말: \(digest.text.prefix(80))"
        )
        XCTAssertLessThan(digest.matched, digest.total)
    }

    /// An empty result still says so rather than sending a bare question with a
    /// dangling header, so the model is told the wiki had nothing rather than left to
    /// infer it.
    func testEmptyResultStillRendersTheHeader() {
        var filter = WikiFilter()
        filter.statuses = ["보류"]
        let digest = render([makeWikiPage("가", status: "진행중")], filter: filter)
        XCTAssertTrue(digest.isEmpty)
        XCTAssertTrue(digest.text.contains("markhub-llm-wiki"))
        XCTAssertTrue(digest.text.contains("(0/0건)"))
    }

    // MARK: - Hash

    func testHashTracksContent() {
        let a = render([makeWikiPage("가")])
        let b = render([makeWikiPage("가")])
        let c = render([makeWikiPage("나")])
        XCTAssertEqual(a.hash, b.hash, "같은 내용은 같은 해시여야 재주입이 일어나지 않는다")
        XCTAssertNotEqual(a.hash, c.hash)
    }

    /// The count in the header is part of the text, so a filter change that alters
    /// only how many matched still moves the hash and still triggers a re-send.
    func testHashMovesWhenOnlyTheCountChanges() {
        let one = render([makeWikiPage("가")])
        let two = render([makeWikiPage("가"), makeWikiPage("나")])
        XCTAssertNotEqual(one.hash, two.hash)
    }

    // MARK: - describe

    func testDescribeNamesEveryActiveAxis() {
        var filter = WikiFilter()
        filter.statuses = ["진행중"]
        filter.categories = ["버그", "기능"]
        filter.areas = ["web"]
        let described = WikiDigestRenderer.describe(filter)
        XCTAssertTrue(described.contains("상태=진행중"))
        XCTAssertTrue(described.contains("분류=기능·버그"))
        XCTAssertTrue(described.contains("영역=web"))
    }

    func testDescribeSaysUnfilteredWhenNothingIsSet() {
        XCTAssertEqual(WikiDigestRenderer.describe(WikiFilter()), "전체")
    }

    /// The empty string is 미지정 to a person, not an empty label.
    func testDescribeSpellsOutUnassigned() {
        var filter = WikiFilter()
        filter.assignees = [""]
        XCTAssertTrue(WikiDigestRenderer.describe(filter).contains("담당=미지정"))
    }
}

final class WikiTokenEstimateTests: XCTestCase {
    /// Three screens quote this figure; they now quote one function. These are the
    /// values those screens were showing before it was extracted.
    func testMatchesTheEstimateTheScreensUsedToComputeInline() {
        XCTAssertEqual(WikiDigestRenderer.approximateTokens(characters: 9_000), 4_090)
        XCTAssertEqual(WikiDigestRenderer.approximateTokens(characters: 7_664), 3_483)
        XCTAssertEqual(WikiDigestRenderer.approximateTokens(characters: 0), 0)
    }
}
