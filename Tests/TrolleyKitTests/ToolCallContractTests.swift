import XCTest
@testable import TrolleyKit

/// The wire format for a model that has no tool-calling API.
///
/// Every "sloppy output" case below is a shape the 26B local model actually produced
/// when probed against this contract, not a shape it might produce. That distinction is
/// the point of the file: the parser is forgiving in exactly the ways the model is
/// careless, and no further.
final class ToolCallContractTests: XCTestCase {
    private let tools: [ToolCallContract.ToolSummary] = [
        .init(name: "launch_app", parameters: ["bundleId"], summary: "앱을 켠다"),
        .init(name: "list_apps", parameters: ["nameContains"], summary: "앱 목록"),
        .init(name: "click", parameters: ["elementId", "bundleId", "text"], summary: "누른다")
    ]

    // MARK: - What the model is told

    func testPreambleListsEveryToolAndBothShapes() {
        let text = ToolCallContract.preamble(tools: tools)
        for tool in tools {
            XCTAssertTrue(text.contains(tool.name), "\(tool.name) 가 목록에 없습니다")
        }
        XCTAssertTrue(text.contains("\"tool\""))
        XCTAssertTrue(text.contains("\"answer\""))
    }

    /// The rule that stops the loop. Probed without it, the model kept going after the
    /// request had already been carried out -- it opened Chrome, then started typing a
    /// URL nobody asked for.
    func testPreambleTellsTheModelWhenToStop() {
        let text = ToolCallContract.preamble(tools: tools)
        XCTAssertTrue(text.contains("이미 이루어졌으면"))
        XCTAssertTrue(text.contains("도구가 필요 없는 질문"))
    }

    /// Asked to search for 러셀 in Chrome, the model typed into the address bar of the
    /// tab already open -- which still held `chrome://whats-new` -- and what got searched
    /// was `러셀chrome://whats-new`. The blank-tab rule is the half that stops it
    /// clobbering the tab someone is looking at.
    func testPreambleSaysToStartInABlankTab() {
        let text = ToolCallContract.preamble(tools: tools)
        XCTAssertTrue(text.contains("빈 탭에서 시작한다"))
        // Naming the keys matters as much as the rule: probed with the rule alone, the
        // catalog gives no hint that a new tab is press_key rather than a tool of its own.
        XCTAssertTrue(text.contains("press_key key=t"))
        XCTAssertTrue(text.contains("cmd"))
    }

    /// The other half of the same failure. `type_text` inserts at the caret and never
    /// clears, so a field with anything in it concatenates.
    func testPreambleSaysToClearAFieldBeforeTyping() {
        let text = ToolCallContract.preamble(tools: tools)
        XCTAssertTrue(text.contains("press_key key=a"))
        XCTAssertTrue(text.contains("이어붙는다"))
    }

    /// The escape hatch, asserted on its own because losing it is the worse regression:
    /// a default that cannot be overridden by the person asking beats the bug it fixed.
    func testBlankTabRuleYieldsToAnExplicitInstruction() {
        XCTAssertTrue(ToolCallContract.preamble(tools: tools).contains("이 탭에서"))
    }

    /// Handing over the real ids is what stopped the model guessing `com.google.chrome`
    /// for Chrome -- wrong case, matches no running app.
    func testPreambleCarriesRunningApps() {
        let text = ToolCallContract.preamble(
            tools: tools, runningApps: ["Chrome (com.google.Chrome)"]
        )
        XCTAssertTrue(text.contains("com.google.Chrome"))
    }

    func testPreambleOmitsTheAppLineWhenThereAreNone() {
        XCTAssertFalse(ToolCallContract.preamble(tools: tools).contains("실행 중인 앱"))
    }

    // MARK: - Reading it back

    func testCleanToolCall() {
        let outcome = ToolCallContract.parse(
            #"{"tool": "launch_app", "arguments": {"bundleId": "com.google.Chrome"}}"#,
            tools: tools
        )
        XCTAssertEqual(
            outcome, .call(name: "launch_app", arguments: ["bundleId": .string("com.google.Chrome")])
        )
    }

    func testCleanAnswer() {
        XCTAssertEqual(
            ToolCallContract.parse(#"{"answer": "크롬을 열었습니다."}"#, tools: tools),
            .answer("크롬을 열었습니다.")
        )
    }

    func testToolWithNoArguments() {
        XCTAssertEqual(
            ToolCallContract.parse(#"{"tool": "list_apps"}"#, tools: tools),
            .call(name: "list_apps", arguments: [:])
        )
    }

    // MARK: - The sloppy shapes, each one measured

    /// `{"arguments": {"com.google.chrome"}}` -- the key left off entirely. Not valid
    /// JSON at all, so nothing but a hand repair recovers it. Bound positionally
    /// against the catalog, which is why `ToolSummary` lists parameters in call order.
    func testArgumentsWrittenAsABareValue() {
        XCTAssertEqual(
            ToolCallContract.parse(
                #"{"tool": "launch_app", "arguments": {"com.google.Chrome"}}"#, tools: tools
            ),
            .call(name: "launch_app", arguments: ["bundleId": .string("com.google.Chrome")])
        )
    }

    func testCodeFenced() {
        let raw = "```json\n{\"tool\": \"list_apps\", \"arguments\": {}}\n```"
        XCTAssertEqual(
            ToolCallContract.parse(raw, tools: tools), .call(name: "list_apps", arguments: [:])
        )
    }

    func testProseBeforeTheObject() {
        let raw = "먼저 크롬을 열겠습니다.\n{\"tool\": \"launch_app\", \"arguments\": {\"bundleId\": \"com.google.Chrome\"}}"
        XCTAssertEqual(
            ToolCallContract.parse(raw, tools: tools),
            .call(name: "launch_app", arguments: ["bundleId": .string("com.google.Chrome")])
        )
    }

    func testTrailingComma() {
        XCTAssertEqual(
            ToolCallContract.parse(
                #"{"tool": "list_apps", "arguments": {"nameContains": "크롬",},}"#, tools: tools
            ),
            .call(name: "list_apps", arguments: ["nameContains": .string("크롬")])
        )
    }

    func testToolNameCasing() {
        XCTAssertEqual(
            ToolCallContract.parse(#"{"tool": "Launch_App", "arguments": {}}"#, tools: tools),
            .call(name: "launch_app", arguments: [:])
        )
    }

    /// A brace inside a string must not close the object early.
    func testBracesInsideStrings() {
        XCTAssertEqual(
            ToolCallContract.parse(#"{"answer": "이렇게 씁니다: {\"a\": 1}"}"#, tools: tools),
            .answer(#"이렇게 씁니다: {"a": 1}"#)
        )
    }

    func testArgumentKinds() {
        let outcome = ToolCallContract.parse(
            #"{"tool": "click", "arguments": {"text": "확인", "x": 12.5, "deep": true, "mods": ["cmd"]}}"#,
            tools: tools
        )
        guard case .call(_, let arguments) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(arguments["text"], .string("확인"))
        XCTAssertEqual(arguments["x"], .number(12.5))
        XCTAssertEqual(arguments["deep"], .bool(true))
        XCTAssertEqual(arguments["mods"], .strings(["cmd"]))
    }

    /// Prose with no JSON anywhere is a final answer, not a failure. Failing here would
    /// throw away a perfectly good reply over punctuation.
    func testPlainProseIsAnAnswer() {
        XCTAssertEqual(
            ToolCallContract.parse("안녕하세요, 무엇을 도와드릴까요?", tools: tools),
            .answer("안녕하세요, 무엇을 도와드릴까요?")
        )
    }

    func testEmptyIsMalformed() {
        XCTAssertEqual(ToolCallContract.parse("   ", tools: tools), .malformed("빈 응답"))
    }

    func testObjectWithNeitherKey() {
        guard case .malformed = ToolCallContract.parse(#"{"foo": "bar"}"#, tools: tools) else {
            return XCTFail("tool 도 answer 도 없는 오브젝트는 malformed 여야 합니다")
        }
    }

    /// An unknown tool has no parameter list to bind against, so the bare-value repair
    /// has nothing to work with and must not invent a key.
    func testBareValueForAnUnknownToolIsMalformed() {
        guard case .malformed = ToolCallContract.parse(
            #"{"tool": "teleport", "arguments": {"어딘가"}}"#, tools: tools
        ) else {
            return XCTFail("바인딩할 파라미터가 없으면 malformed 여야 합니다")
        }
    }

    // MARK: - Feeding the result back

    /// A Chrome snapshot runs to tens of thousands of characters. A few of those in one
    /// conversation push the thread past the server's 96K soft limit, and then it is
    /// not this loop that breaks but every later turn in the same conversation.
    func testResultIsTruncated() {
        let message = ToolCallContract.resultMessage(
            tool: "snapshot", result: String(repeating: "가", count: 10_000), limit: 100
        )
        XCTAssertTrue(message.hasPrefix("[도구 결과] snapshot"))
        XCTAssertTrue(message.hasSuffix("…(잘림)"))
        XCTAssertLessThan(message.count, 200)
    }

    func testShortResultIsUntouched() {
        let message = ToolCallContract.resultMessage(tool: "click", result: #"{"ok":true}"#)
        XCTAssertEqual(message, "[도구 결과] click\n{\"ok\":true}")
    }
}

/// The panel is the one surface that belongs to the person asking. What used to reach it
/// was the wire format -- a half-typed `{"tool": "click", "arguments": {...}}` sitting
/// where the reply goes.
final class StreamingProseTests: XCTestCase {
    private func prose(_ raw: String) -> String? { ToolCallContract.streamingProse(raw) }

    func testToolCallsSaySomethingElseEntirely() {
        XCTAssertNil(prose(#"{"tool": "click", "arguments": {"elementId": "e3"}}"#))
    }

    /// The failure in the screenshot: a call still being written is still a call.
    func testAHalfWrittenToolCallIsAlsoSilent() {
        XCTAssertNil(prose(#"{"tool": "click", "argum"#))
    }

    /// Too few characters to tell yet. Guessing here would flash a fragment of a tool
    /// call before it could be recognised.
    func testAnUnopenedEnvelopeIsSilent() {
        XCTAssertNil(prose("{"))
        XCTAssertNil(prose(#"{"t"#))
        XCTAssertNil(prose("   "))
    }

    /// The reason this is not just "hide anything with a brace": the answer has to
    /// arrive a token at a time, the way any chat does.
    func testAnAnswerStreamsAsItIsWritten() {
        XCTAssertEqual(prose(#"{"answer": "크롬을 여"#), "크롬을 여")
        XCTAssertEqual(prose(#"{"answer": "크롬을 열었습니다."}"#), "크롬을 열었습니다.")
    }

    func testEscapesInAPartialValueAreUnwrapped() {
        XCTAssertEqual(prose(#"{"answer": "첫 줄\n둘째 줄"#), "첫 줄\n둘째 줄")
        XCTAssertEqual(prose(#"{"answer": "그는 \"안녕\" 이라 했다"#), "그는 \"안녕\" 이라 했다")
    }

    /// A model that skips the envelope is answering; there is nothing to open.
    func testPlainProsePassesThrough() {
        XCTAssertEqual(prose("크롬을 열었습니다."), "크롬을 열었습니다.")
    }

    func testFencesAreStrippedFirst() {
        XCTAssertNil(prose("```json\n{\"tool\": \"click\"}\n```"))
    }
}
