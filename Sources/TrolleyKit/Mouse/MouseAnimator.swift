import CoreGraphics
import Foundation

/// Seam over CGEvent mouse posting so cursor movement is testable with a
/// recording fake -- the mouse counterpart of `KeyEventPosting`.
public protocol MouseEventPosting {
    func currentLocation() -> CGPoint
    /// Posts a `.mouseMoved` event.
    func move(to point: CGPoint)
    /// Posts a left down/up pair at the point.
    func click(at point: CGPoint)
}

/// Real CGEvent-backed implementation. Coordinates are global screen points,
/// top-left origin -- the same space AX frames report, which is why element
/// centers pass straight through with no conversion.
public struct CGMouseEventPoster: MouseEventPosting {
    public init() {}

    public func currentLocation() -> CGPoint {
        // A source-less CGEvent snapshots the current HID state, cursor included.
        CGEvent(source: nil)?.location ?? .zero
    }

    public func move(to point: CGPoint) {
        CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        )?.post(tap: .cghidEventTap)
    }

    public func click(at point: CGPoint) {
        let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
        let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        // A well-formed single click carries clickState 1; apps that read it
        // (and any future double-click support) depend on this.
        down?.setIntegerValueField(.mouseEventClickState, value: 1)
        up?.setIntegerValueField(.mouseEventClickState, value: 1)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

public struct MouseMoveReport {
    public let from: CGPoint
    public let to: CGPoint
    public let duration: TimeInterval
}

/// Moves the cursor like a hand would -- an eased glide from where it is to the
/// target -- instead of teleporting it. The person watching can follow what the
/// automation is doing, and apps that track hover state see a plausible stream
/// of move events on the way in.
public struct MouseAnimator {
    /// Steps per second of animation. 60 matches the display; the eye reads it
    /// as continuous motion.
    static let stepsPerSecond: Double = 60

    private let poster: MouseEventPosting
    private let sleeper: (TimeInterval) -> Void

    public init(
        poster: MouseEventPosting,
        sleeper: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) {
        self.poster = poster
        self.sleeper = sleeper
    }

    /// Short hops stay snappy, long ones stay believable: floor 0.15s, cap 0.6s,
    /// scaled by distance in between. Pure and static so it is testable without
    /// sleeping -- same shape as `TextEntryEngine.keyQueueSettle`.
    public static func duration(forDistance distance: CGFloat) -> TimeInterval {
        min(0.6, max(0.15, Double(distance) / 1500))
    }

    /// The interpolated cursor positions from `from` to `to`, eased with
    /// smoothstep (slow-fast-slow, like a hand). The last element is exactly
    /// `to` so the click lands on the requested point, not a float neighbour.
    public static func path(from: CGPoint, to: CGPoint) -> [CGPoint] {
        let distance = hypot(to.x - from.x, to.y - from.y)
        guard distance >= 1 else { return [to] }

        let steps = max(2, Int(duration(forDistance: distance) * stepsPerSecond))
        return (1...steps).map { step in
            let t = Double(step) / Double(steps)
            let eased = t * t * (3 - 2 * t)
            return CGPoint(
                x: from.x + (to.x - from.x) * eased,
                y: from.y + (to.y - from.y) * eased
            )
        }
    }

    @discardableResult
    public func animatedMove(to target: CGPoint) -> MouseMoveReport {
        let from = poster.currentLocation()
        let points = Self.path(from: from, to: target)

        // A sub-point move needs no animation -- and no sleep.
        guard points.count > 1 else {
            poster.move(to: target)
            return MouseMoveReport(from: from, to: target, duration: 0)
        }

        let duration = Self.duration(forDistance: hypot(target.x - from.x, target.y - from.y))
        let interval = duration / Double(points.count)
        for point in points {
            poster.move(to: point)
            sleeper(interval)
        }
        return MouseMoveReport(from: from, to: target, duration: duration)
    }

    @discardableResult
    public func animatedClick(to target: CGPoint) -> MouseMoveReport {
        let report = animatedMove(to: target)
        poster.click(at: target)
        return report
    }
}
