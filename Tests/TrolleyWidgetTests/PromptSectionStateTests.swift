import XCTest
@testable import TrolleyWidget

/// What is left of a much larger file. Most of these tests defended one rule -- that the
/// panel must neither offer nor honour a second prompt destination -- and that rule is
/// now structural: there is one destination, so there is nothing to get wrong. Deleting
/// the type deleted the tests with it.
///
/// These are the rules that outlived it.
final class PromptSectionStateTests: XCTestCase {
    private func model(
        llm: LocalLLMSnapshot = .empty,
        wiki: WikiBadge? = nil
    ) -> ActivityPanelModel {
        ActivityPanelModel(
            log: ActivityLog(),
            uptime: 0,
            axGranted: true,
            screenRecordingGranted: true,
            llm: llm,
            wiki: wiki
        )
    }

    private func answered(busy: Bool = false) -> LocalLLMSnapshot {
        LocalLLMSnapshot(prompt: "질문", body: "답", status: "완료", isBusy: busy)
    }

    func testAnswerBlockFollowsWhetherThereIsAnAnswer() {
        XCTAssertFalse(PromptSectionState(model: model()).showsAnswerBlock)
        XCTAssertTrue(PromptSectionState(model: model(llm: answered())).showsAnswerBlock)
    }

    func testStopButtonFollowsBusy() {
        XCTAssertFalse(PromptSectionState(model: model(llm: answered())).showsStopButton)
        XCTAssertTrue(PromptSectionState(model: model(llm: answered(busy: true))).showsStopButton)
    }

    /// The one thing that still turns the hint orange. A wiki whose digest no longer
    /// fits is a fact about the *next* conversation, so saying it plainly beats letting
    /// someone wonder why the list they edited did not take.
    func testCappedWikiStillWarns() {
        let capped = WikiBadge(matched: 40, attaching: true, isRefresh: false, capped: true)
        let state = PromptSectionState(model: model(wiki: capped))
        XCTAssertTrue(state.hintIsWarning)
        XCTAssertTrue(state.hint.contains("새 대화부터 반영"), state.hint)
    }

    func testNoWikiLeavesThePlainHint() {
        let state = PromptSectionState(model: model())
        XCTAssertEqual(state.hint, PanelFormat.plainHint)
        XCTAssertFalse(state.hintIsWarning)
    }

    /// Already-sent has to read as normal rather than as a fault -- it is the steady
    /// state of every conversation after the first turn.
    func testAlreadySentWikiIsNotAWarning() {
        let sent = WikiBadge(matched: 12, attaching: false, isRefresh: false, capped: false)
        let state = PromptSectionState(model: model(wiki: sent))
        XCTAssertFalse(state.hintIsWarning)
        XCTAssertTrue(state.hint.contains("이미 전달됨"), state.hint)
    }

    /// Says nothing about which model or where it runs; that belongs in 자세히.
    func testPlaceholderNamesNoModel() {
        let placeholder = PromptSectionState(model: model()).placeholder
        for word in ["LLM", "gemma", "로컬", "에이전트"] {
            XCTAssertFalse(placeholder.contains(word), placeholder)
        }
    }
}
