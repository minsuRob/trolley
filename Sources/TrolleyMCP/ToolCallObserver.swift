import Foundation

/// Notifications about tool-call lifecycle, for a UI (or log) riding alongside
/// the server -- the status widget is the consumer.
///
/// A closure struct rather than a protocol, matching the server's other seams
/// (readLine/writeLine/logLine). Both callbacks fire on the server's thread,
/// which in widget mode is a background thread: hop to the main queue before
/// touching AppKit.
public struct ToolCallObserver {
    public var toolCallStarted: (_ name: String) -> Void
    public var toolCallFinished: (_ name: String, _ isError: Bool, _ duration: TimeInterval) -> Void

    public init(
        toolCallStarted: @escaping (String) -> Void = { _ in },
        toolCallFinished: @escaping (String, Bool, TimeInterval) -> Void = { _, _, _ in }
    ) {
        self.toolCallStarted = toolCallStarted
        self.toolCallFinished = toolCallFinished
    }
}
