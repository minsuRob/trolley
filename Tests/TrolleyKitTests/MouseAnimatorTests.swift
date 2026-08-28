import CoreGraphics
import XCTest
@testable import TrolleyKit

final class RecordingMousePoster: MouseEventPosting {
    var location = CGPoint(x: 0, y: 0)
    var moves: [CGPoint] = []
    var clicks: [CGPoint] = []
    /// Simulates a real mouse move or another automation agent's own HID
    /// event landing between this click's down and up: when set, `location`
    /// snaps here right after the click instead of staying at the clicked point.
    var locationAfterClick: CGPoint?

    func currentLocation() -> CGPoint { location }

    func move(to point: CGPoint) {
        moves.append(point)
        location = point
    }

    func click(at point: CGPoint) {
        clicks.append(point)
        location = locationAfterClick ?? point
    }
}

final class MouseAnimatorTests: XCTestCase {
    // MARK: - Pure path math

    func testPathEndsExactlyAtTheTarget() {
        let path = MouseAnimator.path(from: CGPoint(x: 3, y: 7), to: CGPoint(x: 800, y: 600))

        XCTAssertEqual(path.last, CGPoint(x: 800, y: 600), "the click must land on the requested point")
    }

    func testDistanceToTargetShrinksMonotonically() {
        let target = CGPoint(x: 500, y: 400)
        let path = MouseAnimator.path(from: .zero, to: target)

        let distances = path.map { hypot(target.x - $0.x, target.y - $0.y) }
        for (earlier, later) in zip(distances, distances.dropFirst()) {
            XCTAssertGreaterThanOrEqual(earlier, later, "the cursor must never move away from the target")
        }
    }

    func testLongerMovesGetMoreSteps() {
        let short = MouseAnimator.path(from: .zero, to: CGPoint(x: 50, y: 0))
        let long = MouseAnimator.path(from: .zero, to: CGPoint(x: 1200, y: 0))

        XCTAssertGreaterThan(long.count, short.count)
    }

    /// Smoothstep: slow at both ends, fast in the middle -- what makes the
    /// motion read as a hand rather than a projectile.
    func testEasingIsSlowAtTheEndsAndFastInTheMiddle() {
        let path = MouseAnimator.path(from: .zero, to: CGPoint(x: 1000, y: 0))
        let gaps = zip(path, path.dropFirst()).map { $1.x - $0.x }

        let middle = gaps[gaps.count / 2]
        XCTAssertLessThan(gaps.first ?? .infinity, middle)
        XCTAssertLessThan(gaps.last ?? .infinity, middle)
    }

    func testDurationHasAFloorAndACap() {
        XCTAssertEqual(MouseAnimator.duration(forDistance: 1), 0.15)
        XCTAssertEqual(MouseAnimator.duration(forDistance: 100_000), 0.6)
        XCTAssertGreaterThan(
            MouseAnimator.duration(forDistance: 600),
            MouseAnimator.duration(forDistance: 300)
        )
    }

    func testSubPointMoveProducesJustTheTarget() {
        let path = MouseAnimator.path(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 10.4, y: 10.2))

        XCTAssertEqual(path, [CGPoint(x: 10.4, y: 10.2)])
    }

    // MARK: - Animator orchestration

    private func makeAnimator(_ poster: RecordingMousePoster) -> (MouseAnimator, () -> [TimeInterval]) {
        var slept: [TimeInterval] = []
        let animator = MouseAnimator(poster: poster, sleeper: { slept.append($0) })
        return (animator, { slept })
    }

    func testAnimatedClickMovesThenClicksAtTheTarget() {
        let poster = RecordingMousePoster()
        poster.location = CGPoint(x: 100, y: 100)
        let (animator, slept) = makeAnimator(poster)

        let report = animator.animatedClick(to: CGPoint(x: 500, y: 300))

        XCTAssertEqual(poster.moves.last, CGPoint(x: 500, y: 300))
        XCTAssertEqual(poster.clicks, [CGPoint(x: 500, y: 300)])
        XCTAssertGreaterThan(poster.moves.count, 2)
        XCTAssertEqual(slept().count, poster.moves.count, "one frame delay per posted move")
        XCTAssertEqual(report.from, CGPoint(x: 100, y: 100))
        XCTAssertGreaterThan(report.duration, 0)
    }

    func testAnimatedMoveDoesNotClick() {
        let poster = RecordingMousePoster()
        let (animator, _) = makeAnimator(poster)

        animator.animatedMove(to: CGPoint(x: 200, y: 200))

        XCTAssertTrue(poster.clicks.isEmpty)
        XCTAssertEqual(poster.moves.last, CGPoint(x: 200, y: 200))
    }

    func testZeroDistanceSkipsAnimationAndSleep() {
        let poster = RecordingMousePoster()
        poster.location = CGPoint(x: 50, y: 50)
        let (animator, slept) = makeAnimator(poster)

        let report = animator.animatedClick(to: CGPoint(x: 50, y: 50))

        XCTAssertEqual(poster.moves.count, 1)
        XCTAssertTrue(slept().isEmpty, "a no-op move must not stall the serial MCP loop")
        XCTAssertEqual(report.duration, 0)
        XCTAssertEqual(poster.clicks, [CGPoint(x: 50, y: 50)])
    }

    // MARK: - Interference detection

    func testAnimatedClickDoesNotFlagDriftWhenTheCursorStaysPut() {
        let poster = RecordingMousePoster()
        let (animator, _) = makeAnimator(poster)

        let report = animator.animatedClick(to: CGPoint(x: 500, y: 300))

        XCTAssertFalse(report.driftedDuringClick)
    }

    func testAnimatedClickFlagsDriftWhenTheCursorMovedDuringTheHold() {
        let poster = RecordingMousePoster()
        // Simulates a real mouse move or another agent's own HID event
        // landing between this click's down and up.
        poster.locationAfterClick = CGPoint(x: 640, y: 300)
        let (animator, _) = makeAnimator(poster)

        let report = animator.animatedClick(to: CGPoint(x: 500, y: 300))

        XCTAssertTrue(report.driftedDuringClick)
    }
}
