import Foundation

/// Were we reparented to launchd because the client that spawned us died?
///
/// A stdio server's only shutdown signal is stdin EOF, and that signal never
/// arrives if the client dies while some other process still holds the write end
/// of the pipe -- the read blocks forever and the server outlives its reason to
/// exist. Reparenting to PID 1 is the one observable trace of that, so we watch
/// for it.
///
/// Pure on purpose: the caller supplies both PIDs, so the decision is testable
/// without forking anything.
public struct OrphanWatch {
    /// Our parent at startup, captured before anything can reparent us.
    public let initialParentPID: pid_t

    public init(initialParentPID: pid_t) {
        self.initialParentPID = initialParentPID
    }

    /// True only when we *became* an orphan. A server launchd started directly
    /// has PID 1 as its parent from the first moment and must never be mistaken
    /// for one.
    public func isOrphaned(currentParentPID: pid_t) -> Bool {
        initialParentPID != 1 && currentParentPID == 1
    }
}
