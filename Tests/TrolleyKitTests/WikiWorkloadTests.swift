import XCTest
@testable import TrolleyKit

/// What the panel's 위키 열기(N개) counts.
///
/// All of these run against pages built in memory by `makeWikiPage` -- no vault is
/// touched. That is the rule for this whole suite (`CLAUDE.md`): the real wiki is edited
/// by people every day, and a test that reads it fails on somebody else's commit.
/// `myCount()` is the only part that goes to disk and is deliberately not covered here.
final class WikiWorkloadTests: XCTestCase {
    func testCountsOnlyOpenWorkForThatHandle() {
        let pages = [
            makeWikiPage("진행", status: "진행중", assignee: "minsuRob"),
            makeWikiPage("대기중", status: "대기", assignee: "minsuRob")
        ]

        XCTAssertEqual(WikiWorkload.count(in: pages, handle: "minsuRob"), 2)
    }

    /// 완료 is obvious; 보류 is the one worth stating. It is the state for work that was
    /// deliberately set down, and counting it would make the number only ever grow.
    func testFinishedAndShelvedWorkIsNotCounted() {
        let pages = [
            makeWikiPage("끝난것", status: "완료", assignee: "minsuRob"),
            makeWikiPage("접어둔것", status: "보류", assignee: "minsuRob"),
            makeWikiPage("하는중", status: "진행중", assignee: "minsuRob")
        ]

        XCTAssertEqual(WikiWorkload.count(in: pages, handle: "minsuRob"), 1)
    }

    func testOtherPeoplesWorkIsNotCounted() {
        let pages = [
            makeWikiPage("내것", status: "진행중", assignee: "minsuRob"),
            makeWikiPage("남의것", status: "진행중", assignee: "someoneElse"),
            makeWikiPage("주인없음", status: "진행중", assignee: "")
        ]

        XCTAssertEqual(WikiWorkload.count(in: pages, handle: "minsuRob"), 1)
    }

    /// The trap this guards. `WikiFilter` reads an empty set on an axis as "no constraint
    /// here", so a filter built straight from an empty handle would match the entire open
    /// board -- and the button would report the whole team's work as one person's.
    func testAnUnknownHandleCountsNothingRatherThanEverything() {
        let pages = [
            makeWikiPage("가", status: "진행중", assignee: "minsuRob"),
            makeWikiPage("나", status: "진행중", assignee: "someoneElse")
        ]

        XCTAssertEqual(WikiWorkload.count(in: pages, handle: ""), 0)
    }

    /// `members/` and `logs/` are walkable but not indexed by default, and the options
    /// window's 내 일감 preset does not reach into them either. A personal scratch page
    /// with 담당 on it must not turn up in the count.
    func testPagesOutsideTheIndexedFoldersAreNotCounted() {
        let pages = [
            makeWikiPage("일감", status: "진행중", assignee: "minsuRob", folder: "context/tasks"),
            makeWikiPage("개념", status: "진행중", assignee: "minsuRob", folder: "context/concepts"),
            makeWikiPage("메모", status: "진행중", assignee: "minsuRob", folder: "members/minsuRob")
        ]

        XCTAssertEqual(WikiWorkload.count(in: pages, handle: "minsuRob"), 2)
    }

    /// Counting goes through `matches`, not `apply`. `apply` truncates at `maxCount`,
    /// which for the initializer's default would silently cap the answer at 40.
    func testTheCountIsNotCappedByTheFiltersMaxCount() {
        let pages = (0..<60).map {
            makeWikiPage("일감\($0)", status: "진행중", assignee: "minsuRob")
        }

        XCTAssertEqual(WikiWorkload.count(in: pages, handle: "minsuRob"), 60)
    }
}
