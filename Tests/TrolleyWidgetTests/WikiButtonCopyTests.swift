import XCTest
@testable import TrolleyWidget

/// The three things the panel's 위키 버튼 can say.
///
/// The distinction being pinned here is nil vs 0. They render differently on purpose:
/// no parentheses means "nobody has said which 담당 handle is yours", and `(0개)` means
/// "you are known and nothing is open on you". Collapsing them would make an empty
/// board look like an unconfigured app.
final class WikiButtonCopyTests: XCTestCase {
    func testNoHandleLearnedYetGetsNoNumber() {
        XCTAssertEqual(WikiButtonCopy.title(myCount: nil), "위키 열기")
    }

    /// Kept rather than dropped back to the bare title: a number that appears and
    /// vanishes as the last task closes reads as a glitch, not as good news.
    func testAnEmptyBoardStillShowsItsZero() {
        XCTAssertEqual(WikiButtonCopy.title(myCount: 0), "위키 열기(0개)")
    }

    func testACountIsShownInParentheses() {
        XCTAssertEqual(WikiButtonCopy.title(myCount: 3), "위키 열기(3개)")
    }

    /// The tooltip is where the definition lives -- the button itself has no room to say
    /// which pages it counted.
    func testTheTooltipNamesWhatWasCounted() {
        XCTAssertEqual(WikiButtonCopy.tooltip(myCount: 3), "내 일감 3건 — 담당=나 · 진행중·대기")
        XCTAssertEqual(WikiButtonCopy.tooltip(myCount: nil), "위키 창을 엽니다")
    }
}
