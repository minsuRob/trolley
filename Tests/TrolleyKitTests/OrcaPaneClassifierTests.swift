import XCTest
@testable import TrolleyKit

final class OrcaPaneClassifierTests: XCTestCase {
    /// A real `orca terminal read --json` tail, captured from an idle Claude
    /// Code pane (empty `❯` prompt, status chrome below it).
    static let idleTail = [
        " ▐▛███▛█   Claude Code v2.1.250",
        "▝▜██████▀  Sonnet 5 · Claude Max",
        "  ▝▝ ▝▝    ~/Desktop/Workspace/MAKI/trolley",
        "⚠ 1 MCP server needs authentication · run /mcp",
        "❯ /clear",
        "────────────────────────────────────────────────────────────────────────────────",
        "❯",
        "────────────────────────────────────────────────────────────────────────────────",
        "                                                                           /rc",
        "  ⏵⏵ auto mode on (shift+tab to cycle) · ← 2 agents"
    ]

    func testIdlePaneWithEmptyPromptIsIdle() {
        let (kind, draft) = OrcaPaneClassifier.classify(tail: Self.idleTail, title: "✳ Claude Code")
        XCTAssertEqual(kind, .claudeIdle)
        XCTAssertTrue(draft.isEmpty)
    }

    func testUnsentTextAfterPromptIsDraft() {
        var tail = Self.idleTail
        tail[6] = "❯ 이거 먼저 확인해줘"
        let (kind, draft) = OrcaPaneClassifier.classify(tail: tail, title: "✳ Claude Code")
        XCTAssertEqual(kind, .claudeDraft)
        XCTAssertEqual(draft, "이거 먼저 확인해줘")
    }

    func testElapsedTimeCounterMeansBusy() {
        var tail = Self.idleTail
        tail[6] = "  Generating… (12s · ↓ 3.1k tokens · esc to interrupt)"
        let (kind, _) = OrcaPaneClassifier.classify(tail: tail, title: "✳ Claude Code")
        XCTAssertEqual(kind, .claudeBusy)
    }

    func testNonClaudePaneIsShellDev() {
        let tail = ["$ npm run dev", "Compiled successfully"]
        let (kind, _) = OrcaPaneClassifier.classify(tail: tail, title: "zsh")
        XCTAssertEqual(kind, .shellDev)
    }

    func testTitleAloneCanMarkAClaudePane() {
        // A marker string can scroll out of the tail window while the tab
        // title still says what the pane is.
        let tail = ["$ some old scrollback with nothing distinctive"]
        let (kind, _) = OrcaPaneClassifier.classify(tail: tail, title: "✳ Claude Code")
        XCTAssertNotEqual(kind, .shellDev)
    }

    func testBusyMarkerOutsideInputZoneDoesNotStickForever() {
        // A stale "esc to interrupt" from an earlier turn, far above the
        // input zone, must not make a now-idle pane read as busy.
        var tail = ["esc to interrupt"] + Array(repeating: "filler", count: 20)
        tail += Self.idleTail
        let (kind, _) = OrcaPaneClassifier.classify(tail: tail, title: "✳ Claude Code")
        XCTAssertEqual(kind, .claudeIdle)
    }
}
