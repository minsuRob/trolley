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
            makeWikiPreamble: { _ in nil },
            commitWikiPreamble: { _, _ in },
            toolRunner: runner
        )
        session.send(prompt)
        return (session, runner, box.turns)
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
