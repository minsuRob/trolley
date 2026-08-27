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
            WikiDigestRenderer.line(for: page, detail: .full),
            "- [[모바일 컴포저 멘션]] · 진행중 · 기능 · 중간 · mobile · minsuRob · 2026-07-08 · 모바일 컴포저에 사람 언급 추가"
        )
    }

    /// The thinnest line the renderer can make, and the one the default filter uses.
    /// Exact equality on purpose: this string is measured -- 84 pages of it is ~2,800
    /// characters against a 9,000 budget -- and a field creeping back in would cost
    /// that margin without anything failing.
    func testTitlesOnlyLineIsTitleAndStatus() {
        let page = makeWikiPage(
            "모바일 컴포저 멘션", status: "진행중", category: "기능", priority: "중간",
            assignee: "minsuRob", summary: "모바일 컴포저에 사람 언급 추가",
            areas: ["mobile"], updated: "2026-07-08"
        )
        XCTAssertEqual(
            WikiDigestRenderer.line(for: page, detail: .titles),
            "- [[모바일 컴포저 멘션]] · 진행중"
        )
    }

    /// The status survives even when there is none, because a title list where a blank
    /// status is indistinguishable from a missing separator is one the model has to
    /// guess at.
    func testTitlesOnlyLineRendersAMissingStatusAsADash() {
        XCTAssertEqual(
            WikiDigestRenderer.line(for: makeWikiPage("가", status: ""), detail: .titles),
            "- [[가]] · -"
        )
    }

    /// `[[…]]` is the vault's own link syntax and the basename is its identity key, so
    /// a title written this way is one `wiki_read` can resolve and one a person can
    /// paste straight into Obsidian.
    func testTitleIsWrappedAsAWikiLink() {
        let line = WikiDigestRenderer.line(for: makeWikiPage("위키맵 개선"), detail: .metadata)
        XCTAssertTrue(line.contains("[[위키맵 개선]]"))
    }

    /// Same joiner the vault's own indexer uses, so a multi-area page reads the same
    /// in both places.
    func testListAreasAreJoinedWithTheVaultsSeparator() {
        let line = WikiDigestRenderer.line(
            for: makeWikiPage("가", areas: ["web", "mobile", "be"]), detail: .metadata
        )
        XCTAssertTrue(line.contains("web·mobile·be"))
    }

    func testMissingFieldsRenderAsDashes() {
        let line = WikiDigestRenderer.line(
            for: makeWikiPage("가", status: "", category: "", priority: "", assignee: "",
                              areas: [], updated: ""),
            detail: .metadata
        )
        XCTAssertEqual(line, "- [[가]] · - · - · - · - · - · -")
    }

    /// The biggest lever on cost, and the reason detail is an axis rather than a switch:
    /// on the real vault the same 84 pages are ~2,800 characters at `.titles` and ~9,600
    /// at `.full`, either side of the 9,000 budget.
    func testEachDetailLevelIsShorterThanTheOneAbove() {
        let page = makeWikiPage(
            "가", status: "진행중", category: "기능", priority: "중간", assignee: "minsuRob",
            summary: "제법 긴 한 줄 요약이 여기에 들어간다", areas: ["web"], updated: "2026-07-08"
        )
        let titles = WikiDigestRenderer.line(for: page, detail: .titles).count
        let metadata = WikiDigestRenderer.line(for: page, detail: .metadata).count
        let full = WikiDigestRenderer.line(for: page, detail: .full).count
        XCTAssertLessThan(titles, metadata)
        XCTAssertLessThan(metadata, full)
    }

    // MARK: - The header

    /// The header names the columns, so it has to name the ones that were actually
    /// rendered. A header promising 요약 over a list with none is worse than no header:
    /// the model reads the absence as "this page has no summary".
    func testHeaderNamesOnlyTheColumnsItRendered() {
        let page = makeWikiPage("가", status: "진행중", assignee: "minsuRob", summary: "요약이다")
        for detail in WikiFilter.Detail.allCases {
            var filter = WikiFilter(detail: detail)
            filter.statuses = []
            let header = render([page], filter: filter).text
                .split(separator: "\n")[1]
            XCTAssertEqual(header.contains("요약"), detail == .full, "\(detail)")
            XCTAssertEqual(header.contains("담당"), detail != .titles, "\(detail)")
        }
    }

    /// The anti-hallucination guarantee, asserted rather than commented. Handed nothing
    /// but titles, the model will read a 담당 and a 기한 straight out of a title's own
    /// words -- this sentence is the only thing standing between it and that.
    func testTitlesOnlyHeaderSaysTheListCannotAnswerMore() {
        let text = render(
            [makeWikiPage("가", status: "진행중")], filter: WikiFilter(detail: .titles)
        ).text
        XCTAssertTrue(text.contains("알 수 없습니다"), text)
        XCTAssertTrue(text.contains("추측해서 말하지 마세요"), text)
    }

    /// The digest states the limit and stops there. It must not tell the model to *do*
    /// anything about it: `trolley ask` wires no tools, so only `ToolCallContract` knows
    /// whether there is a way to look a page up.
    ///
    /// Measured, not hypothesised -- an earlier wording said "해당 문서를 먼저 열어
    /// 확인하세요" and the 26B model answered it by calling `launch_app` and `snapshot`,
    /// reading 열다 as opening a document on screen.
    func testTitlesOnlyHeaderDoesNotTellTheModelToOpenAnything() {
        let text = render(
            [makeWikiPage("가", status: "진행중")], filter: WikiFilter(detail: .titles)
        ).text
        for verb in ["열어", "여세요", "실행", "wiki_read", "wiki_search"] {
            XCTAssertFalse(text.contains(verb), "다이제스트가 동작을 지시하고 있다: \(verb)")
        }
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

    /// The header grows with the detail level -- the `.titles` caveat is the longest of
    /// the three -- so the budget has to hold at every level, not just the widest.
    func testNoDetailLevelExceedsTheBudget() {
        let pages = (1...200).map { makeWikiPage("페이지 번호 \($0)", summary: "요약", created: "2026-07-01") }
        for detail in WikiFilter.Detail.allCases {
            for budget in [500, 1_000, 4_000, 9_000] {
                let digest = render(pages, filter: WikiFilter(detail: detail), budget: budget)
                XCTAssertLessThanOrEqual(
                    digest.characters, budget,
                    "\(detail) 이 예산 \(budget)자를 넘었다: \(digest.characters)자"
                )
            }
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
            "생략 건수가 본문에 없다: \(digest.text.suffix(160))"
        )
    }

    /// Two limits can cut the same list, and they are two different dials. Blaming the
    /// budget for a 최대 건수 cut sends the person to turn the number that was not the
    /// problem -- and at `.titles`, where lines are short, 최대 건수 is usually the one
    /// that bit.
    func testTruncationNamesWhichLimitDidTheCutting() {
        var filter = WikiFilter(maxCount: 20)
        filter.statuses = []
        let pages = (1...200).map { makeWikiPage("페이지 \($0)", summary: "제법 긴 한 줄 요약") }

        // Only 최대 건수 bites: 20 lines fit inside a generous budget.
        let byCount = render(pages, filter: filter, budget: 9_000)
        XCTAssertTrue(byCount.text.contains("최대 건수 20건 상한으로 180건"), byCount.text.suffix(160).description)
        XCTAssertFalse(byCount.text.contains("예산"), byCount.text.suffix(160).description)

        // Both bite: 최대 건수 cuts to 20, then the budget cuts those 20 down further.
        let byBoth = render(pages, filter: filter, budget: 700)
        XCTAssertTrue(byBoth.text.contains("최대 건수 20건 상한으로 180건"), byBoth.text.suffix(160).description)
        XCTAssertTrue(byBoth.text.contains("예산 700자 상한으로"), byBoth.text.suffix(160).description)
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
