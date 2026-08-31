import AppKit
import TrolleyKit
import XCTest
@testable import trolley

/// The wiki window's pure parts. What cannot be asserted here -- that the walk stays off
/// the main thread -- is what the freeze at `WikiWindowController.reloadList` proved the
/// hard way: `show()` called it inline, and the enumerator sat in `open()` while macOS
/// held a consent prompt for `~/Desktop` that only the blocked thread could have drawn.
final class WikiWindowTests: XCTestCase {
    /// Markdown has nothing to say about a YAML block, so a rendered page opened with a
    /// horizontal rule and a run-on paragraph of 유형/상태/분류 -- directly above the line
    /// that already says them properly.
    func testFrontmatterIsDroppedFromWhatIsRendered() {
        let page = """
        ---
        유형: 일감
        상태: 진행중
        ---

        # 제목

        본문 첫 줄.
        """
        let shown = WikiWindowController.withoutFrontmatter(page)
        XCTAssertTrue(shown.hasPrefix("# 제목"), shown)
        XCTAssertFalse(shown.contains("유형:"), shown)
        XCTAssertTrue(shown.contains("본문 첫 줄."), shown)
    }

    /// A page that opens with a horizontal rule is not a page with broken frontmatter.
    /// Dropping to the next `---` there would eat its first section.
    func testAPageWithNoFrontmatterIsLeftWhole() {
        XCTAssertEqual(WikiWindowController.withoutFrontmatter("# 제목\n본문"), "# 제목\n본문")
        let unclosed = "---\n유형: 일감\n\n# 제목"
        XCTAssertEqual(WikiWindowController.withoutFrontmatter(unclosed), unclosed)
    }

    /// The body is what a person is reading, not a document store: 6,000 characters is
    /// below `wiki_read`'s own 8,000 because the contract and the question ride with it.
    func testTheContextLimitLeavesRoomForTheContractAndTheQuestion() {
        XCTAssertLessThan(WikiWindowController.contextLimit, 8_000)
    }

    // MARK: - What the toolbar filters to

    private func base() -> WikiFilter {
        var filter = WikiFilter()
        filter.assignees = ["minsuRob"]   // what the options window had stored
        filter.maxCount = 150
        return filter
    }

    /// The rule this change exists for. The stored filter has been narrowed to one handle
    /// for as long as it has existed, so the window opened on ten of the vault's two
    /// hundred pages with the reason two windows away. 담당 is the toolbar's now, and
    /// inheriting the stored one would make 담당 전체 mean "전체, except that person".
    func testTheStoredAssigneeIsNotInherited() {
        let filter = WikiWindowController.filter(
            base: base(), search: "", folder: nil, status: nil, assignee: nil
        )
        XCTAssertTrue(filter.assignees.isEmpty, "\(filter.assignees)")
    }

    func testThePickedAssigneeWins() {
        let picked = WikiWindowController.filter(
            base: base(), search: "", folder: nil, status: nil, assignee: "songjein"
        )
        XCTAssertEqual(picked.assignees, ["songjein"])
        // "" is 미지정, which `WikiFilter` already reads as "pages with no 담당" -- the
        // convention this borrows rather than inventing a second one.
        let unassigned = WikiWindowController.filter(
            base: base(), search: "", folder: nil, status: nil, assignee: ""
        )
        XCTAssertEqual(unassigned.assignees, [""])
    }

    /// A person scrolling a table is not spending context, so the digest's count cap has
    /// no business bounding the list.
    func testTheStoredCountCapDoesNotBoundTheList() {
        let filter = WikiWindowController.filter(
            base: base(), search: " 검색어 ", folder: "logs", status: "완료", assignee: nil
        )
        XCTAssertGreaterThan(filter.maxCount, 150)
        XCTAssertEqual(filter.titleContains, "검색어")
        XCTAssertEqual(filter.folders, ["logs"])
        XCTAssertEqual(filter.statuses, ["완료"])
    }

    // MARK: - Which folders a walk needs

    /// The bug this change exists for: 폴더 전체 with the default 담당=나 filter used to
    /// walk `members`/`logs` too, spending part of `WikiIndex`'s one fixed 0.15s deadline
    /// on folders the filter was always going to throw away.
    func testAnUnnarrowedFilterOnlyWalksTheIndexedFolders() {
        var filter = WikiFilter()
        filter.folders = []
        XCTAssertEqual(WikiWindowController.walkTargets(for: filter), WikiIndex.indexableFolders)
    }

    func testANarrowedFilterWalksOnlyWhatItKeeps() {
        var filter = WikiFilter()
        filter.folders = ["logs"]
        XCTAssertEqual(WikiWindowController.walkTargets(for: filter), ["logs"])
    }

    /// Picking `members`/`logs` from the folder popup still has to walk them -- narrowing
    /// must not accidentally drop the optional folders when they are actually wanted.
    func testAnOptionalFolderIsStillWalkedWhenTheFilterAsksForIt() {
        var filter = WikiFilter()
        filter.folders = ["context/tasks", "members"]
        XCTAssertEqual(
            Set(WikiWindowController.walkTargets(for: filter)), ["context/tasks", "members"]
        )
    }

    // MARK: - Where the divider lands

    /// The number this change exists to delete: the list used to be 360 points wide,
    /// forever, and 담당 was whatever fell off the end of that.
    func testAnUntouchedDividerOpensWideEnoughForTheHandleColumn() {
        let width = WikiWindowController.listWidth(stored: nil, available: 900)
        XCTAssertEqual(width, WikiWindowController.defaultListWidth)
        XCTAssertGreaterThan(width, 360)
    }

    func testADraggedDividerIsGivenBack() {
        XCTAssertEqual(WikiWindowController.listWidth(stored: 520, available: 900), 520)
    }

    /// A width dragged wide on a big screen, reopened on a small one. Handing it back
    /// whole would leave the page a sliver.
    func testAStoredWidthIsClampedToWhatTheWindowCanHold() {
        XCTAssertEqual(
            WikiWindowController.listWidth(stored: 800, available: 900),
            900 - WikiWindowController.minimumPageWidth
        )
        XCTAssertEqual(
            WikiWindowController.listWidth(stored: 40, available: 900),
            WikiWindowController.minimumListWidth
        )
    }

    /// Both minimums cannot hold. Clamping to the list's would push the page to zero,
    /// so what is left gets shared instead.
    func testTooNarrowForBothMinimumsSplitsTheDifference() {
        let available: CGFloat = 400
        XCTAssertLessThan(
            available,
            WikiWindowController.minimumListWidth + WikiWindowController.minimumPageWidth
        )
        XCTAssertEqual(WikiWindowController.listWidth(stored: 380, available: available), 200)
        XCTAssertEqual(WikiWindowController.listWidth(stored: nil, available: 0), 0)
    }

    /// A folder that has left the vault, or a 상태 this build no longer offers. Selecting
    /// nothing leaves a popup that reads as 전체 while filtering by something else.
    func testAStoredValueThatNoLongerExistsFallsBackToAll() {
        let available = [WikiWindowController.anyFolder] + WikiWindowController.folders
        XCTAssertEqual(
            WikiWindowController.toolbarSelection(
                stored: "context/tasks", available: available, any: WikiWindowController.anyFolder
            ),
            "context/tasks"
        )
        XCTAssertEqual(
            WikiWindowController.toolbarSelection(
                stored: "없어진폴더", available: available, any: WikiWindowController.anyFolder
            ),
            WikiWindowController.anyFolder
        )
        XCTAssertEqual(
            WikiWindowController.toolbarSelection(
                stored: nil, available: available, any: WikiWindowController.anyFolder
            ),
            WikiWindowController.anyFolder
        )
    }
}

/// The three knobs the wiki window remembers between launches.
final class WikiWindowSettingsTests: XCTestCase {
    /// Three states in one key, and the two that look alike are the ones that matter:
    /// never chosen is 전체, and `""` is 미지정 -- a real selection.
    func testTheAssigneeKeyTellsUnsetApartFromUnassigned() {
        withWindowKeys {
            XCTAssertNil(WikiSettings.windowAssignee)

            WikiSettings.windowAssignee = ""
            XCTAssertEqual(WikiSettings.windowAssignee, "")

            WikiSettings.windowAssignee = "minsuRob"
            XCTAssertEqual(WikiSettings.windowAssignee, "minsuRob")

            WikiSettings.windowAssignee = nil
            XCTAssertNil(WikiSettings.windowAssignee)
        }
    }

    func testFolderAndStatusRoundTrip() {
        withWindowKeys {
            WikiSettings.windowFolder = "logs"
            WikiSettings.windowStatus = "완료"
            XCTAssertEqual(WikiSettings.windowFolder, "logs")
            XCTAssertEqual(WikiSettings.windowStatus, "완료")
            WikiSettings.windowFolder = nil
            XCTAssertNil(WikiSettings.windowFolder)
            XCTAssertEqual(WikiSettings.windowStatus, "완료", "한 쪽을 지우면 다른 쪽까지 지워진다")
        }
    }

    /// These are the window's knobs, not the CLI's filter. Turning one must not rewrite
    /// what `trolley wiki` runs.
    func testTheyDoNotTouchTheStoredFilter() {
        withWindowKeys {
            let before = WikiSettings.filter
            WikiSettings.windowAssignee = "songjein"
            WikiSettings.windowFolder = "members"
            XCTAssertEqual(WikiSettings.filter, before)
        }
    }

    /// Never dragged has to stay distinguishable from dragged to nothing -- and a stored
    /// zero is what a split view reports while the window is still being built.
    func testTheListWidthKeyIgnoresZeroAndKeepsARealDrag() {
        withWindowKeys {
            XCTAssertNil(WikiSettings.windowListWidth)

            WikiSettings.windowListWidth = 480
            XCTAssertEqual(WikiSettings.windowListWidth, 480)

            WikiSettings.windowListWidth = 0
            XCTAssertNil(WikiSettings.windowListWidth)

            WikiSettings.windowListWidth = 480
            WikiSettings.windowListWidth = nil
            XCTAssertNil(WikiSettings.windowListWidth)
        }
    }

    private func withWindowKeys(_ body: () -> Void) {
        let defaults = UserDefaults.standard
        let keys = [
            WikiSettings.windowAssigneeKey, WikiSettings.windowFolderKey,
            WikiSettings.windowStatusKey, WikiSettings.windowListWidthKey
        ]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        keys.forEach { defaults.removeObject(forKey: $0) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        body()
    }
}
