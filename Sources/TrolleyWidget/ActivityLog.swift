import Foundation

/// The session's recent tool calls, for the click-to-open activity panel.
/// Pure data; main-thread-confined by the controller that owns it.
public struct ActivityLog {
    public struct Entry: Equatable {
        public let name: String
        public let finishedAt: Date
        public let isError: Bool
        public let duration: TimeInterval

        public init(name: String, finishedAt: Date, isError: Bool, duration: TimeInterval) {
            self.name = name
            self.finishedAt = finishedAt
            self.isError = isError
            self.duration = duration
        }
    }

    /// Newest first, capped.
    public private(set) var entries: [Entry] = []
    /// Counters keep counting past the cap -- the header line must not go
    /// backwards just because old entries were evicted.
    public private(set) var totalCalls = 0
    public private(set) var errorCount = 0
    public let capacity: Int

    public init(capacity: Int = 50) {
        self.capacity = capacity
    }

    public mutating func record(_ entry: Entry) {
        entries.insert(entry, at: 0)
        if entries.count > capacity {
            entries.removeLast(entries.count - capacity)
        }
        totalCalls += 1
        if entry.isError {
            errorCount += 1
        }
    }
}
