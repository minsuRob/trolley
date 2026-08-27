import AppKit
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
}
