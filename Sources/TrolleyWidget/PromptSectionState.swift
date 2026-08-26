import Foundation

/// Everything the prompt section renders, derived in one place.
///
/// The branching used to sit inline in `updatePromptSection`, which made it both
/// untestable and impossible to reason about next to the layout code it was
/// tangled with. Pulling it out keeps the view controller's share of this change
/// to a handful of lines and lets the rules below be asserted without a window
/// server.
struct PromptSectionState: Equatable {
    /// The destination switch only appears where there is a real choice to make.
    let showsDestinationControl: Bool
    let selectedSegment: Int
    /// Where ⏎ will actually send -- not necessarily what is stored.
    let destination: PromptDestination
    let placeholder: String
    let hint: String
    let hintIsWarning: Bool
    let showsPending: Bool
    let showsAnswerBlock: Bool
    let showsStopButton: Bool

    init(model: ActivityPanelModel) {
        // The app never serves `take_prompt`, so in the app there is exactly one
        // place a prompt can go. Offering the choice there was offering a wrong
        // answer and then explaining, in orange, why it was wrong.
        showsDestinationControl = model.agentReaderAvailable
        destination = PromptDestination.effective(
            stored: model.destination,
            agentReaderAvailable: model.agentReaderAvailable
        )
        selectedSegment = PromptDestination.allCases.firstIndex(of: destination) ?? 0

        let agentMode = destination == .agent
        // Unreachable once the destination is collapsed, but the rule stays here
        // rather than being deleted: `trolley mcp --widget` can still lose its
        // reader, and that is the one case worth shouting about.
        let orphanQueue = agentMode && !model.agentReaderAvailable
        hint = PanelFormat.promptHint(
            destination: destination, wiki: model.wiki, orphanQueue: orphanQueue
        )
        hintIsWarning = orphanQueue || model.wiki?.capped == true
        placeholder = agentMode ? Self.agentPlaceholder : Self.localPlaceholder

        showsPending = agentMode
        showsAnswerBlock = !agentMode && model.llm.hasContent
        showsStopButton = model.llm.isBusy
    }

    /// Deliberately says nothing about which model or where it runs -- that is the
    /// kind of detail the setup window's "자세히" is for.
    static let localPlaceholder = "무엇이든 물어보세요…"
    static let agentPlaceholder = "에이전트에게 전할 말…"
}

extension PromptDestination {
    /// Where a prompt really goes.
    ///
    /// Hiding the switch is not enough on its own: someone who once picked
    /// `.agent` in `trolley mcp --widget` has that choice sitting in
    /// `UserDefaults`, and in the app it would silently route every question into
    /// a queue with no reader. Collapsing here is what makes hiding safe.
    static func effective(
        stored: PromptDestination, agentReaderAvailable: Bool
    ) -> PromptDestination {
        agentReaderAvailable ? stored : .localLLM
    }
}
