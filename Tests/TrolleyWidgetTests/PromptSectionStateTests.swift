import XCTest
@testable import TrolleyWidget

/// What is left of a much larger file, twice over. Most of these tests defended one rule
/// -- that the panel must neither offer nor honour a second prompt destination -- and
/// that rule became structural when the second destination went away. The rest defended
/// the wiki hint, which went the same way: the vault is read in its own window now, so
/// this box has nothing to announce and the hint is one constant line.
///
/// These are the rules that outlived both.
final class PromptSectionStateTests: XCTestCase {
    private func model(llm: LocalLLMSnapshot = .empty) -> ActivityPanelModel {
        ActivityPanelModel(
            log: ActivityLog(),
            axGranted: true,
            screenRecordingGranted: true,
            llm: llm
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

    /// One line, always. The hint used to change with what the wiki was about to attach;
    /// nothing attaches now, and a box that still hinted at the vault would be pointing
    /// at a window this is not.
    func testHintIsThePlainLineAndNeverAWarning() {
        let state = PromptSectionState(model: model())
        XCTAssertEqual(state.hint, PanelFormat.plainHint)
        XCTAssertFalse(state.hintIsWarning)
        XCTAssertEqual(PromptSectionState(model: model(llm: answered())).hint, PanelFormat.plainHint)
    }

    /// Says nothing about which model or where it runs; that belongs in 자세히.
    func testPlaceholderNamesNoModel() {
        let placeholder = PromptSectionState(model: model()).placeholder
        for word in ["LLM", "gemma", "로컬", "에이전트"] {
            XCTAssertFalse(placeholder.contains(word), placeholder)
        }
    }
}
