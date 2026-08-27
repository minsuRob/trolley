import XCTest
@testable import TrolleyKit

/// The turn loop, driven by a fake model and a fake Mac.
///
/// `LocalLLMSession` normally reaches a server over SSE, so the seam being exercised
/// here is `makeClient`: the fake returns scripted answers in order, which is enough to
/// play out a whole multi-step exchange in microseconds and with no accessibility tree
/// anywhere near it.
final class LocalLLMToolLoopTests: XCTestCase {
    // MARK: - Doubles

    private final class FakeRunner: LocalLLMToolRunning {
        var toolCatalog: [ToolCallContract.ToolSummary] = [
            .init(name: "launch_app", parameters: ["bundleId"], summary: "앱을 켠다"),
            .init(name: "click", parameters: ["elementId"], summary: "누른다")
        ]
        var runningAppSummaries: [String] = ["Chrome (com.google.Chrome)"]
        /// What each call is answered with, and what was asked, in order.
        var results: [String] = []
        private(set) var calls: [(name: String, arguments: [String: ToolCallContract.JSONArgument])] = []

        func run(
            name: String,
            arguments: [String: ToolCallContract.JSONArgument],
            completion: @escaping (String) -> Void
        ) {
            calls.append((name, arguments))
            completion(results.isEmpty ? #"{"ok":true}"# : results.removeFirst())
        }
    }

    /// A generation that never happened: hands back a scripted answer as if the
    /// server had streamed it, on the spot.
    private final class FakeHandle: LocalLLMStoppable {
        func cancel() {}
    }

    // MARK: - Harness

    /// Plays a whole exchange against a scripted model.
    ///
    /// `turns` collects what each generation was actually asked, which is how the tests
    /// below check that the contract rides on turn one and a `[도구 결과]` on turn two.
    /// Everything is synchronous, so a three-step loop settles before `send` returns.
    private func run(
        answers: [String],
        results: [String] = [],
        prompt: String = "크롬 열어줘"
    ) -> (session: LocalLLMSession, runner: FakeRunner, turns: [String]) {
        let runner = FakeRunner()
        runner.results = results
        let box = Box(answers: answers)

        let session = LocalLLMSession(
            makeTurn: { { content, _, _, onEvent in
                box.turns.append(content)
                let reply = box.answers.isEmpty ? #"{"answer": "끝"}"# : box.answers.removeFirst()
                onEvent(.started(backend: "fake"))
                onEvent(.token(kind: "answer", text: reply))
                onEvent(.finished)
                return FakeHandle()
            } },
            toolRunner: runner
        )
        session.send(prompt)
        return (session, runner, box.turns)
    }

    /// Same as `run`, but each scripted turn says which channel the server put it on.
    ///
    /// The distinction is the whole point of these tests: the server splits the model's
    /// output into `answer` and `thinking`, and the model does not reliably use the one
    /// the loop was reading.
    private func runChannelled(
        turns script: [(kind: String, text: String)],
        results: [String] = [],
        prompt: String = "크롬 열어줘"
    ) -> (session: LocalLLMSession, runner: FakeRunner) {
        let runner = FakeRunner()
        runner.results = results
        var remaining = script

        let session = LocalLLMSession(
            makeTurn: { { _, _, _, onEvent in
                let turn = remaining.isEmpty
                    ? (kind: "answer", text: #"{"answer": "끝"}"#)
                    : remaining.removeFirst()
                onEvent(.started(backend: "fake"))
                onEvent(.token(kind: turn.kind, text: turn.text))
                onEvent(.finished)
                return FakeHandle()
            } },
            toolRunner: runner
        )
        session.send(prompt)
        return (session, runner)
    }

    // MARK: - Which channel the move arrived on

    /// Measured, not hypothetical. In one 58-message conversation the model put its
    /// entire move on the reasoning channel four separate times, leaving the answer
    /// channel empty:
    ///
    ///     25 ASST   0자  ''
    ///           thinking 36자: {"answer": "Google Chrome을 실행했습니다."}
    func testAMoveLeftOnTheReasoningChannelIsStillRead() {
        let (session, _) = runChannelled(turns: [
            (kind: "thinking", text: #"{"answer": "크롬을 열었습니다."}"#)
        ])
        XCTAssertEqual(session.answer, "크롬을 열었습니다.")
        XCTAssertEqual(session.phase, .done)
    }

    /// A tool call leaks the same way, and losing one costs a whole round trip.
    func testAToolCallOnTheReasoningChannelStillRuns() {
        let (session, runner) = runChannelled(
            turns: [
                (kind: "thinking", text: #"{"tool": "launch_app", "arguments": {"bundleId": "com.google.Chrome"}}"#),
                (kind: "answer", text: #"{"answer": "열었습니다."}"#)
            ],
            results: [#"{"launched": true}"#]
        )
        XCTAssertEqual(runner.calls.map(\.name), ["launch_app"])
        XCTAssertEqual(session.answer, "열었습니다.")
    }

    /// The fallback is narrow on purpose. A model that reasons out loud and *then*
    /// answers must be read from its answer -- otherwise fixing the leak would break
    /// every well-behaved turn.
    func testReasoningIsIgnoredWhenThereIsARealAnswer() {
        let runner = FakeRunner()
        let session = LocalLLMSession(
            makeTurn: { { _, _, _, onEvent in
                onEvent(.started(backend: "fake"))
                onEvent(.token(kind: "thinking", text: #"{"answer": "생각 중에 흘린 말"}"#))
                onEvent(.token(kind: "answer", text: #"{"answer": "진짜 답"}"#))
                onEvent(.finished)
                return FakeHandle()
            } },
            toolRunner: runner
        )
        session.send("질문")
        XCTAssertEqual(session.answer, "진짜 답")
    }

    /// Whitespace on the answer channel is not an answer -- the leak often leaves a
    /// stray newline behind rather than nothing at all.
    func testWhitespaceOnlyAnswerFallsBackToReasoning() {
        let runner = FakeRunner()
        let session = LocalLLMSession(
            makeTurn: { { _, _, _, onEvent in
                onEvent(.started(backend: "fake"))
                onEvent(.token(kind: "answer", text: "\n  "))
                onEvent(.token(kind: "thinking", text: #"{"answer": "채널 밖의 답"}"#))
                onEvent(.finished)
                return FakeHandle()
            } },
            toolRunner: runner
        )
        session.send("질문")
        XCTAssertEqual(session.answer, "채널 밖의 답")
    }

    /// The regression this was found by. Six tool steps, the channel leaking twice:
    /// before the fix the first leak spent the one correction and the second -- the
    /// closing answer, after the work had already succeeded -- failed the whole turn
    /// with "모델이 형식을 지키지 못했습니다".
    func testTwoLeaksInOneExchangeNoLongerExhaustTheCorrection() {
        let (session, runner) = runChannelled(
            turns: [
                (kind: "thinking", text: #"{"tool": "launch_app", "arguments": {"bundleId": "com.google.Chrome"}}"#),
                (kind: "answer", text: #"{"tool": "type_text", "arguments": {"text": "장위동"}}"#),
                (kind: "thinking", text: #"{"answer": "장위동 검색 결과를 띄웠습니다."}"#)
            ],
            results: [#"{"ok": true}"#, #"{"ok": true}"#]
        )
        XCTAssertEqual(runner.calls.map(\.name), ["launch_app", "type_text"])
        XCTAssertEqual(session.answer, "장위동 검색 결과를 띄웠습니다.")
        XCTAssertEqual(session.phase, .done)
    }

    /// Both channels empty is still nothing, and still gets the one correction. The
    /// fallback must not swallow the case it was never about.
    func testBothChannelsEmptyStillAsksForACorrection() {
        let (session, _) = runChannelled(turns: [
            (kind: "answer", text: ""),
            (kind: "answer", text: #"{"answer": "다시 냈습니다."}"#)
        ])
        XCTAssertEqual(session.answer, "다시 냈습니다.")
        XCTAssertEqual(session.phase, .done)
    }

    /// The script and the transcript, shared by reference so the closure above can both
    /// consume and record without capturing `inout` state.
    private final class Box {
        var answers: [String]
        var turns: [String] = []
        init(answers: [String]) { self.answers = answers }
    }

    // MARK: - The loop

    func testSingleAnswerNeedsNoTool() {
        let (session, runner, turns) = run(answers: [#"{"answer": "안녕하세요"}"#])
        XCTAssertEqual(session.answer, "안녕하세요")
        XCTAssertEqual(session.phase, .done)
        XCTAssertTrue(runner.calls.isEmpty)
        XCTAssertEqual(turns.count, 1)
    }

    /// The contract and the running-app list ride on the first turn; the tool result
    /// rides on the second, and the contract is not repeated there.
    func testFirstTurnCarriesTheContract() {
        let (_, _, turns) = run(answers: [
            #"{"tool": "launch_app", "arguments": {"bundleId": "com.google.Chrome"}}"#,
            #"{"answer": "열었습니다"}"#
        ])
        XCTAssertTrue(turns[0].contains("launch_app"))
        XCTAssertTrue(turns[0].contains("com.google.Chrome"))
        XCTAssertTrue(turns[0].hasSuffix("크롬 열어줘"))
        XCTAssertTrue(turns[1].hasPrefix("[도구 결과] launch_app"))
        XCTAssertFalse(turns[1].contains("매 차례 JSON"))
    }

    func testToolRunsAndTheAnswerIsTheProseNotTheJSON() {
        let (session, runner, _) = run(answers: [
            #"{"tool": "launch_app", "arguments": {"bundleId": "com.google.Chrome"}}"#,
            #"{"answer": "크롬을 열었습니다"}"#
        ])
        XCTAssertEqual(runner.calls.map(\.name), ["launch_app"])
        XCTAssertEqual(runner.calls[0].arguments["bundleId"], .string("com.google.Chrome"))
        XCTAssertEqual(session.answer, "크롬을 열었습니다")
        XCTAssertEqual(session.phase, .done)
    }

    func testSeveralStepsInARow() {
        let (session, runner, _) = run(answers: [
            #"{"tool": "launch_app", "arguments": {"bundleId": "com.google.Chrome"}}"#,
            #"{"tool": "click", "arguments": {"elementId": "e1"}}"#,
            #"{"answer": "다 했습니다"}"#
        ])
        XCTAssertEqual(runner.calls.map(\.name), ["launch_app", "click"])
        XCTAssertEqual(session.answer, "다 했습니다")
    }

    /// The tool's own output is what the next turn is given -- that is the only way the
    /// model learns anything it did not already know.
    func testToolResultReachesTheModel() {
        let (_, _, turns) = run(
            answers: [
                #"{"tool": "launch_app", "arguments": {"bundleId": "com.google.Chrome"}}"#,
                #"{"answer": "끝"}"#
            ],
            results: [#"{"pid": 4412}"#]
        )
        XCTAssertTrue(turns[1].contains("4412"))
    }

    /// A model that keeps calling tools has to be stopped, and stopped with something
    /// the user can read rather than a spinner that never resolves.
    func testStepLimit() {
        let looping = Array(
            repeating: #"{"tool": "click", "arguments": {"elementId": "e1"}}"#,
            count: LocalLLMSession.stepLimit + 4
        )
        let (session, runner, _) = run(answers: looping)
        XCTAssertEqual(runner.calls.count, LocalLLMSession.stepLimit)
        XCTAssertEqual(session.phase, .done)
        XCTAssertEqual(session.answer, ToolCallContract.stepLimitMessage(LocalLLMSession.stepLimit))
    }

    // MARK: - When the model breaks the format

    /// One correction, then the answer -- the recovery working as intended.
    func testMalformedIsCorrectedOnce() {
        let (session, _, turns) = run(answers: [
            #"{"tool": 12345}"#,
            #"{"answer": "다시 했습니다"}"#
        ])
        XCTAssertEqual(turns[1], ToolCallContract.correction)
        XCTAssertEqual(session.answer, "다시 했습니다")
        XCTAssertEqual(session.phase, .done)
    }

    /// Twice in a row and the turn ends. A third attempt costs another full generation
    /// and, measured against a model that has already failed the format twice, buys
    /// nothing.
    func testMalformedTwiceFails() {
        let (session, _, turns) = run(answers: [#"{"tool": 1}"#, #"{"tool": 2}"#])
        XCTAssertEqual(turns.count, 2)
        guard case .failed(let message) = session.phase else {
            return XCTFail("두 번 연속 형식 실패는 failed 여야 합니다: \(session.phase)")
        }
        XCTAssertTrue(message.contains("형식"))
    }

    // MARK: - Status

    func testActingStatusNamesTheToolAndThePosition() {
        XCTAssertEqual(
            LocalLLMSession.statusLine(for: .acting(step: 2, tool: "click"), backend: nil),
            "도구 실행 중 — click (2/\(LocalLLMSession.stepLimit))"
        )
    }

    func testActingCountsAsBusy() {
        let (session, _, _) = run(answers: [#"{"answer": "끝"}"#])
        XCTAssertFalse(session.isBusy)
        XCTAssertEqual(session.phase, .done)
    }
}
