import Foundation

/// Everything the prompt section renders, derived in one place.
///
/// Much smaller than it was. The box used to have two destinations -- the local model,
/// or a queue an MCP client drained with `take_prompt` -- and most of this type existed
/// to keep a question from being routed into a queue with no reader. With that path gone
/// (`docs/MCP-보류.md`) there is one destination, so the choice, the switch, and the
/// orphan-queue warning went with it.
///
/// Still pulled out of `updatePromptSection` rather than inlined back: the rules below
/// are assertable without a window server, and that is why they were extracted at all.
struct PromptSectionState: Equatable {
    let placeholder: String
    let hint: String
    let hintIsWarning: Bool
    let showsAnswerBlock: Bool
    let showsStopButton: Bool

    init(model: ActivityPanelModel) {
        hint = PanelFormat.promptHint(wiki: model.wiki)
        hintIsWarning = model.wiki?.capped == true
        placeholder = Self.localPlaceholder
        showsAnswerBlock = model.llm.hasContent
        showsStopButton = model.llm.isBusy
    }

    /// Deliberately says nothing about which model or where it runs -- that is the
    /// kind of detail the setup window's "자세히" is for.
    static let localPlaceholder = "무엇이든 물어보세요…"
}
