import XCTest
@testable import TrolleyKit

/// The transcript exists to be readable in a 360pt panel, and the thing that makes it
/// unreadable is real: one `snapshot` result in the measured conversation is 4,023
/// characters. These assert the collapse, not the formatting.
final class TranscriptRenderingTests: XCTestCase {
    private func line(_ role: String, _ content: String) -> TranscriptRendering.Line? {
        TranscriptRendering.line(from: .init(role: role, content: content))
    }

    /// Built with `resultMessage`, not by hand. The first version of this test wrote the
    /// separator itself -- a space -- while the real format puts the payload on the next
    /// line, so the test passed against a shape that never occurs and the panel printed
    /// the whole tree.
    func testToolResultCollapsesToItsName() {
        let huge = ToolCallContract.resultMessage(
            tool: "snapshot",
            result: "{\"nodeCount\":210,\"tree\":[" + String(repeating: "x", count: 4000) + "]}"
        )
        let rendered = line("user", huge)
        XCTAssertEqual(rendered?.kind, .tool)
        XCTAssertEqual(rendered?.text, "← snapshot")
    }

    /// Every tool goes through the same envelope, so one shape check covers them all.
    func testEveryToolResultShapeCollapses() {
        for tool in ["find_elements", "click", "launch_app", "press_key"] {
            let message = ToolCallContract.resultMessage(tool: tool, result: #"{"ok":true}"#)
            XCTAssertEqual(line("user", message)?.text, "← \(tool)")
        }
    }

    func testToolCallShowsTheToolAndItsTarget() {
        let rendered = line("assistant", #"{"tool": "click", "arguments": {"elementId": "e477", "bundleId": "com.google.Chrome"}}"#)
        XCTAssertEqual(rendered?.kind, .tool)
        XCTAssertEqual(rendered?.text, "→ click bundleId=com.google.Chrome elementId=e477")
    }

    func testAnswerIsUnwrappedFromItsEnvelope() {
        let rendered = line("assistant", #"{"answer": "크롬에서 '장위동' 검색 결과 페이지가 표시되었습니다."}"#)
        XCTAssertEqual(rendered?.kind, .answer)
        XCTAssertEqual(rendered?.text, "크롬에서 '장위동' 검색 결과 페이지가 표시되었습니다.")
    }

    /// The point of the whole view. What was transmitted is the contract plus the
    /// question; what someone is looking for is the question.
    func testQuestionIsShownWithoutTheContractRidingInFrontOfIt() {
        let wired = LocalLLMSession.wire(prompt: "크롬 탭 하나 켜줘", context: nil, tools: nil)
        let contracted = "도구 목록:\n- click\n\n---\n\n크롬 탭 하나 켜줘"
        XCTAssertEqual(line("user", wired)?.text, "크롬 탭 하나 켜줘")
        XCTAssertEqual(line("user", contracted)?.text, "크롬 탭 하나 켜줘")
        XCTAssertEqual(line("user", contracted)?.kind, .question)
    }

    func testFormatCorrectionIsMarkedRatherThanShownWhole() {
        let rendered = line("user", "JSON 오브젝트 하나만 출력해라. {\"tool\": \"이름\"} 형식이다.")
        XCTAssertEqual(rendered?.kind, .scaffolding)
        XCTAssertEqual(rendered?.text, "형식 교정 요청")
    }

    func testEmptyTurnsAreDropped() {
        XCTAssertNil(line("assistant", "   \n "))
    }

    /// A plain sentence from the model is not JSON and must survive untouched.
    func testProseAnswerIsLeftAlone() {
        let rendered = line("assistant", "크롬을 열었습니다.")
        XCTAssertEqual(rendered?.kind, .answer)
        XCTAssertEqual(rendered?.text, "크롬을 열었습니다.")
    }

    func testWholeThreadKeepsItsOrder() {
        let lines = TranscriptRendering.lines(from: [
            .init(role: "user", content: "크롬 켜줘"),
            .init(role: "assistant", content: #"{"tool": "launch_app", "arguments": {"name": "Chrome"}}"#),
            .init(role: "user", content: "[도구 결과] launch_app {\"launched\":true}"),
            .init(role: "assistant", content: #"{"answer": "열었습니다."}"#)
        ])
        XCTAssertEqual(lines.map(\.kind), [.question, .tool, .tool, .answer])
    }
}
