import Foundation

/// The seam between the model's turn loop and the tools that actually touch the Mac.
///
/// A protocol here rather than a direct call because of the target graph: the loop lives
/// in `LocalLLMSession`, which is in `TrolleyKit`, and `TrolleyTools` is in `TrolleyMCP`
/// one level above. Inverting it this way also means the loop's tests can run a fake
/// runner and assert the multi-step behaviour without an accessibility tree.
public protocol LocalLLMToolRunning: AnyObject {
    /// What the model is told it can call. Order is the order it is read in.
    var toolCatalog: [ToolCallContract.ToolSummary] { get }

    /// Bundle ids of apps on screen right now, handed to the model so it does not have
    /// to guess them. Empty is fine.
    var runningAppSummaries: [String] { get }

    /// Runs one tool and calls back on the main queue with the result as text.
    ///
    /// Errors come back through `completion` as text rather than as a thrown error:
    /// a tool that failed is something the model should read and work around -- that is
    /// the whole point of a loop -- not something that should end the turn.
    func run(
        name: String,
        arguments: [String: ToolCallContract.JSONArgument],
        completion: @escaping (String) -> Void
    )
}
