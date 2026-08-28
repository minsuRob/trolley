import Foundation

/// The three ways this module knows how to reach a real Claude.
public enum ClaudeInvokeMethod: String, CaseIterable {
    case terminal
    case orca
    case desktop
}

public struct ClaudeInvokeResult {
    public let method: ClaudeInvokeMethod
    public let success: Bool
    /// One line, already worded for a status label -- not an error code.
    public let message: String

    public init(method: ClaudeInvokeMethod, success: Bool, message: String) {
        self.method = method
        self.success = success
        self.message = message
    }
}

/// One delivery channel. Implementations run entirely off the main thread --
/// they launch apps, shell out, and synthesize keyboard/mouse input, all of
/// which can block -- and call back into `confirm` (also off the main thread)
/// for anything that needs a person's go-ahead before an effect nobody can
/// undo. Only `OrcaDispatchDeliverer` uses it today: the other two methods
/// only ever act on a window this module just opened itself.
public protocol ClaudeInvokeDeliverer {
    var method: ClaudeInvokeMethod { get }

    /// - Parameter confirm: called synchronously with a one-line description
    ///   of what is about to happen; returns whether to proceed. The caller is
    ///   expected to hop to the main thread itself (NSAlert requires it) --
    ///   this protocol stays free of AppKit so TrolleyKit does not have to
    ///   know what a confirmation dialog looks like.
    func deliver(prompt: String, confirm: @escaping (String) -> Bool) -> ClaudeInvokeResult
}
