import XCTest
@testable import TrolleyKit

final class ClaudeInvokePromptBuilderTests: XCTestCase {
    func testNoContextReturnsTheTypedTextAlone() {
        let prompt = ClaudeInvokePromptBuilder.compose(
            userText: "  이거 좀 봐줘  ", pageTitle: nil, pageBody: nil, attachContext: true
        )
        XCTAssertEqual(prompt, "이거 좀 봐줘")
    }

    func testAttachContextPrependsTheOpenPage() {
        let prompt = ClaudeInvokePromptBuilder.compose(
            userText: "요약해줘", pageTitle: "모바일 컴포저 멘션", pageBody: "본문 내용", attachContext: true
        )
        XCTAssertTrue(prompt.contains("[[모바일 컴포저 멘션]]"))
        XCTAssertTrue(prompt.contains("본문 내용"))
        XCTAssertTrue(prompt.hasSuffix("요약해줘"))
    }

    func testAttachContextOffIgnoresAnOpenPage() {
        let prompt = ClaudeInvokePromptBuilder.compose(
            userText: "요약해줘", pageTitle: "모바일 컴포저 멘션", pageBody: "본문 내용", attachContext: false
        )
        XCTAssertEqual(prompt, "요약해줘")
    }

    func testEmptyBodyIsTreatedAsNoContext() {
        let prompt = ClaudeInvokePromptBuilder.compose(
            userText: "요약해줘", pageTitle: "제목", pageBody: "", attachContext: true
        )
        XCTAssertEqual(prompt, "요약해줘")
    }
}
