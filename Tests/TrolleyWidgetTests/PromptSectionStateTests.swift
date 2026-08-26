import XCTest
@testable import TrolleyWidget

/// The rule these all circle: in the app there is exactly one place a prompt can
/// go, and the panel must neither offer nor honour the other one.
final class PromptSectionStateTests: XCTestCase {
    private func model(
        destination: PromptDestination = .localLLM,
        agentReaderAvailable: Bool = false,
        llm: LocalLLMSnapshot = .empty,
        wiki: WikiBadge? = nil
    ) -> ActivityPanelModel {
        // `pendingPrompts` stays empty: naming its element type would mean
        // importing TrolleyMCP into this target, and none of these assertions
        // depend on the queue's contents -- only on whether it is shown.
        ActivityPanelModel(
            log: ActivityLog(),
            uptime: 0,
            axGranted: true,
            screenRecordingGranted: true,
            pendingPrompts: [],
            destination: destination,
            llm: llm,
            agentReaderAvailable: agentReaderAvailable,
            wiki: wiki
        )
    }

    private func answered(busy: Bool = false) -> LocalLLMSnapshot {
        LocalLLMSnapshot(prompt: "질문", body: "답", status: "완료", isBusy: busy)
    }

    // MARK: - In the app (no agent reader)

    func testSwitchIsHiddenWhenNothingCanReadTheQueue() {
        XCTAssertFalse(PromptSectionState(model: model()).showsDestinationControl)
    }

    /// The bug that hiding the switch would otherwise create: a `.agent` left in
    /// UserDefaults by an earlier `trolley mcp --widget` session.
    func testAStoredAgentChoiceIsIgnoredWithoutAReader() {
        let state = PromptSectionState(model: model(destination: .agent))
        XCTAssertEqual(state.destination, .localLLM)
        XCTAssertFalse(state.showsPending)
        XCTAssertEqual(state.placeholder, PromptSectionState.localPlaceholder)
    }

    /// The orange line was the worst screen in the app; collapsing the
    /// destination is what makes it unreachable rather than merely rare.
    func testTheOrphanWarningCannotAppearWithoutAReader() {
        let state = PromptSectionState(model: model(destination: .agent))
        XCTAssertFalse(state.hintIsWarning)
        XCTAssertFalse(state.hint.contains("가져갈 서버가 없습니다"))
    }

    func testAnswerBlockFollowsWhetherThereIsAnAnswer() {
        XCTAssertFalse(PromptSectionState(model: model()).showsAnswerBlock)
        XCTAssertTrue(PromptSectionState(model: model(llm: answered())).showsAnswerBlock)
    }

    func testStopButtonFollowsBusy() {
        XCTAssertFalse(PromptSectionState(model: model(llm: answered())).showsStopButton)
        XCTAssertTrue(PromptSectionState(model: model(llm: answered(busy: true))).showsStopButton)
    }

    /// A wiki notice is not a warning, but a capped one is.
    func testCappedWikiStillWarns() {
        let capped = WikiBadge(matched: 3, attaching: false, isRefresh: false, capped: true)
        XCTAssertTrue(PromptSectionState(model: model(wiki: capped)).hintIsWarning)
    }

    // MARK: - Under `trolley mcp --widget` (a reader exists)

    /// The regression net: where the choice is real, nothing about it changed.
    func testSwitchAndAgentModeSurviveWhereAReaderExists() {
        let state = PromptSectionState(
            model: model(destination: .agent, agentReaderAvailable: true)
        )
        XCTAssertTrue(state.showsDestinationControl)
        XCTAssertEqual(state.destination, .agent)
        XCTAssertTrue(state.showsPending)
        XCTAssertFalse(state.showsAnswerBlock)
        XCTAssertEqual(state.placeholder, PromptSectionState.agentPlaceholder)
        XCTAssertEqual(
            state.selectedSegment, PromptDestination.allCases.firstIndex(of: .agent) ?? -1
        )
    }

    func testLocalModeWithAReaderStillShowsTheSwitch() {
        let state = PromptSectionState(
            model: model(destination: .localLLM, agentReaderAvailable: true, llm: answered())
        )
        XCTAssertTrue(state.showsDestinationControl)
        XCTAssertEqual(state.destination, .localLLM)
        XCTAssertTrue(state.showsAnswerBlock)
        XCTAssertFalse(state.showsPending)
    }
}

final class PromptDestinationEffectiveTests: XCTestCase {
    func testTheFullTruthTable() {
        XCTAssertEqual(
            PromptDestination.effective(stored: .agent, agentReaderAvailable: true), .agent
        )
        XCTAssertEqual(
            PromptDestination.effective(stored: .localLLM, agentReaderAvailable: true), .localLLM
        )
        XCTAssertEqual(
            PromptDestination.effective(stored: .agent, agentReaderAvailable: false), .localLLM
        )
        XCTAssertEqual(
            PromptDestination.effective(stored: .localLLM, agentReaderAvailable: false), .localLLM
        )
    }

    /// Collapsing is a read, not a write: the user's choice has to survive being
    /// ignored, so that starting `trolley mcp --widget` restores it.
    func testCollapsingDoesNotOverwriteTheStoredChoice() {
        let original = PromptDestination.stored
        defer { PromptDestination.stored = original }

        PromptDestination.stored = .agent
        _ = PromptDestination.effective(stored: .agent, agentReaderAvailable: false)
        XCTAssertEqual(PromptDestination.stored, .agent)
    }
}
