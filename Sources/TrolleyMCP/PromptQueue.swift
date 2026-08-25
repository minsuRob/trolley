import Foundation

/// Prompts the user typed into the widget, waiting for the agent to collect
/// them with the `take_prompt` tool.
///
/// A stdio MCP server cannot speak first -- the client asks, the server answers.
/// So the widget's prompt box does not send anything anywhere: it parks the text
/// here, and the next `take_prompt` call carries it out. That makes this the one
/// piece of state both threads touch (AppKit's main thread writes, the MCP loop
/// drains), which is why it is a class with a lock rather than a struct like
/// `ActivityLog`.
public final class PromptQueue: @unchecked Sendable {
    public struct Prompt: Equatable {
        /// Monotonic per session, so a client can tell a redelivery from a new
        /// prompt with the same text.
        public let id: Int
        public let text: String
        public let submittedAt: Date

        public init(id: Int, text: String, submittedAt: Date) {
            self.id = id
            self.text = text
            self.submittedAt = submittedAt
        }
    }

    private let lock = NSLock()
    private var queue: [Prompt] = []
    private var nextID = 1
    private var changeHandler: (() -> Void)?
    private let capacity: Int

    public init(capacity: Int = 20) {
        self.capacity = max(1, capacity)
    }

    /// Fired after every accepted submit and every non-empty drain, on the
    /// caller's thread -- the widget hops to main itself. Set by the widget so
    /// the panel's "waiting" list stops lying once the agent has collected.
    public var onChange: (() -> Void)? {
        get { lock.withLock { changeHandler } }
        set { lock.withLock { changeHandler = newValue } }
    }

    /// Nil for text that is empty once trimmed -- an accidental ⏎ should not
    /// hand the agent a blank instruction.
    @discardableResult
    public func submit(_ text: String, at date: Date = Date()) -> Prompt? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let (prompt, handler): (Prompt, (() -> Void)?) = lock.withLock {
            let prompt = Prompt(id: nextID, text: trimmed, submittedAt: date)
            nextID += 1
            queue.append(prompt)
            // Oldest first out: a queue this long means nobody is collecting,
            // and the newest instruction is the one still worth delivering.
            if queue.count > capacity {
                queue.removeFirst(queue.count - capacity)
            }
            return (prompt, changeHandler)
        }
        handler?()
        return prompt
    }

    /// Oldest first, and clears -- delivery is exactly once, so a client that
    /// drops the result has lost it. The alternative (acknowledged delivery)
    /// would need an id round-trip the tool surface does not have.
    public func drain() -> [Prompt] {
        let (taken, handler): ([Prompt], (() -> Void)?) = lock.withLock {
            let taken = queue
            queue.removeAll()
            return (taken, taken.isEmpty ? nil : changeHandler)
        }
        handler?()
        return taken
    }

    public var pendingPrompts: [Prompt] {
        lock.withLock { queue }
    }

    public var pendingCount: Int {
        lock.withLock { queue.count }
    }
}
