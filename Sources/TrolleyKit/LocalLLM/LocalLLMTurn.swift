import Foundation

/// A running generation, seen only as the ability to stop it.
///
/// `LocalLLMClient.Handle` is the real one. The protocol exists so the session can be
/// driven by a scripted stand-in, which is what makes the tool loop's multi-step
/// behaviour testable without a server: nothing else about a handle is used.
public protocol LocalLLMStoppable: AnyObject {
    func cancel()
}

extension LocalLLMClient.Handle: LocalLLMStoppable {}

/// One generation: send a message into a conversation, get events back, get a way to
/// stop it.
///
/// A closure rather than a client because `LocalLLMSession` uses exactly this much of
/// `LocalLLMClient` and nothing else, and narrowing the seam to what is used is what
/// lets a test replay a whole exchange -- model turn, tool call, model turn -- in
/// microseconds.
public typealias LocalLLMTurn = (
    _ content: String,
    _ conversationID: String?,
    _ onConversation: @escaping (String) -> Void,
    _ onEvent: @escaping (LocalLLMClient.Event) -> Void
) -> LocalLLMStoppable

public extension LocalLLMSession {
    /// The real thing: a client built from whatever address is configured right now.
    ///
    /// Nil when no address is set, which the session reports as a failed phase rather
    /// than a silent no-op -- someone who has not pointed trolley at a server should be
    /// told that, not left watching a box that never answers.
    static func liveTurn() -> LocalLLMTurn? {
        guard let config = LocalLLMSettings.makeConfig() else { return nil }
        let client = LocalLLMClient(config: config)
        return { content, conversationID, onConversation, onEvent in
            client.ask(
                content,
                conversationID: conversationID,
                onConversation: onConversation,
                onEvent: onEvent
            )
        }
    }
}
