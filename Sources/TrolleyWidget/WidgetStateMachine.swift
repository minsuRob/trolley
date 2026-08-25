import Foundation

/// What the widget is showing.
public enum WidgetState: Equatable {
    case idle
    case working(tool: String)
    /// The ✅/❌ overlay after a call finished.
    case badge(success: Bool)
}

public enum WidgetEvent: Equatable {
    case started(tool: String)
    case finished(isError: Bool)
    /// The badge's display period elapsed.
    case badgeTimedOut
}

/// Pure reducer for the widget's display state, so the transitions are
/// testable without AppKit. The controller owns the badge timer: a single
/// DispatchWorkItem, cancelled on every event before scheduling anew -- which
/// is what keeps a stale timer from hiding a newer badge.
public struct WidgetStateMachine {
    public private(set) var state: WidgetState = .idle

    public init() {}

    @discardableResult
    public mutating func handle(_ event: WidgetEvent) -> WidgetState {
        switch (state, event) {
        case (_, .started(let tool)):
            // A new call always takes over, badge included.
            state = .working(tool: tool)
        case (.working, .finished(let isError)):
            state = .badge(success: !isError)
        case (.badge, .badgeTimedOut):
            state = .idle
        case (.idle, .badgeTimedOut), (.working, .badgeTimedOut):
            // A stale timer firing after the state moved on: ignore.
            break
        case (.idle, .finished), (.badge, .finished):
            // Defensive: the server is strictly serial, so a finish without a
            // matching start should not happen -- but showing a badge for a
            // call we never showed as running would only confuse.
            break
        }
        return state
    }
}
