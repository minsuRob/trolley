import Foundation
import TrolleyKit

/// Hands out stable ids for AX elements and holds the references alive across
/// tool calls.
///
/// This is the main thing a persistent server buys over the CLI: the CLI
/// re-resolves every element by text match from the app root on each
/// invocation, so a model can't reliably say "click the one I just found".
public final class ElementRegistry {
    private struct Entry {
        let element: AXElementProviding
        let pid: pid_t?
        let sequence: Int
    }

    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private var counter = 0
    private let capacity: Int

    public init(capacity: Int = 1000) {
        self.capacity = capacity
    }

    public var count: Int { entries.count }

    /// Ids are never reused, so a stale id reports as stale rather than silently
    /// resolving to some unrelated element.
    @discardableResult
    public func register(_ element: AXElementProviding, pid: pid_t? = nil) -> String {
        counter += 1
        let id = "e\(counter)"
        entries[id] = Entry(element: element, pid: pid ?? element.pid, sequence: counter)
        order.append(id)
        evictIfNeeded()
        return id
    }

    public func resolve(_ id: String) throws -> AXElementProviding {
        guard let entry = entries[id] else {
            throw ToolError.invalidElementID(id)
        }
        guard entry.element.isAlive() else {
            throw ToolError.elementStale(id)
        }
        return entry.element
    }

    public func pid(for id: String) -> pid_t? {
        entries[id]?.pid
    }

    private func evictIfNeeded() {
        while order.count > capacity, let oldest = order.first {
            order.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }
}
