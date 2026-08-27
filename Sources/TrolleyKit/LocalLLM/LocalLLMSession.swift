import Foundation

/// The one exchange the widget is showing: what was asked, what has arrived so
/// far, and where it is in the server's queue.
///
/// Only the latest exchange is kept. The panel is 360pt wide and the server's
/// own web UI is where a transcript belongs; what this has to answer is "did my
/// question go anywhere, and what came back".
///
/// Main-thread only, like the widget it feeds. `LocalLLMClient` delivers every
/// callback on the main queue, so nothing here needs a lock.
public final class LocalLLMSession {
    public enum Phase: Equatable {
        case idle
        /// How many generations are ahead of this one. The local model runs one
        /// at a time by design, so waiting is normal rather than a fault.
        case queued(position: Int)
        case generating
        /// A tool the model asked for is running. Named because the panel would
        /// otherwise sit on "생성 중" through a `wait_for_element`, and a widget that
        /// looks stuck while trolley is clicking things is the one state worth
        /// spelling out.
        case acting(step: Int, tool: String)
        case done
        case failed(String)
        case cancelled
    }

    /// How many tools the model may run for one question.
    ///
    /// Eight because each step is a full round trip through the server's queue on a
    /// single-worker local model -- at roughly ten seconds a step, this is already a
    /// minute and a half of a spinning panel. A loop that has not finished by then is
    /// far more often stuck than close.
    public static let stepLimit = 8

    public private(set) var prompt = ""
    public private(set) var answer = ""
    /// The model's reasoning channel, kept apart from the answer by the server.
    public private(set) var thinking = ""
    /// The block currently being denoised. Replaced wholesale each time, and
    /// dropped the moment real tokens start arriving.
    public private(set) var draft = ""
    public private(set) var phase: Phase = .idle
    public private(set) var backend: String?

    public var onChange: (() -> Void)?

    private let makeTurn: () -> LocalLLMTurn?
    private let makeContext: () -> String?
    /// Which stored thread this session talks into. Two sessions with the same slot are
    /// two views of one conversation; two slots are two conversations.
    private let slot: LocalLLMSettings.ConversationSlot
    private var handle: LocalLLMStoppable?

    /// Nil leaves this a plain chat session, which is what `trolley ask` wants.
    private let toolRunner: LocalLLMToolRunning?
    /// Tools run so far for the current question, against `stepLimit`.
    private var step = 0
    /// Whether the malformed-output correction has already been spent this turn. One
    /// retry, not a loop: a model that cannot hold the format twice running will not
    /// hold it the third time either, and every attempt costs a full generation.
    private var didCorrect = false

    /// - Parameters:
    ///   - makeTurn: how one generation is run. Re-read per send, so changing the
    ///     address in the setup window takes effect on the next question rather than
    ///     the next launch -- and a closure rather than a client, so the loop's own
    ///     behaviour can be played out against a scripted model with no server.
    ///   - makeContext: reference material to put in front of the next question, or nil.
    ///     Nil for the widget's prompt box, which asks about this Mac and needs nothing
    ///     in front of it. The wiki window passes the document it has open.
    ///
    ///     Read per send rather than captured, and deliberately not remembered: the
    ///     server persists a conversation and replays *every* message of it as the
    ///     prompt, so anything put in front of one question is re-sent, in full, on every
    ///     later turn of that conversation. Whoever passes a body here is responsible for
    ///     starting a new conversation when the body changes -- see `WikiWindowController`.
    ///   - slot: which stored conversation to talk into. `.main` is the widget's thread;
    ///     the wiki window uses its own so that reading the vault cannot leak into a
    ///     question about Chrome, which is the whole point of it having a window.
    ///   - toolRunner: what turns a tool call into something happening on this Mac.
    ///     Injected, and nil by default, for two reasons: the loop's behaviour is
    ///     testable with a fake, and the CLI path keeps the plain chat it had.
    public init(
        makeTurn: @escaping () -> LocalLLMTurn? = LocalLLMSession.liveTurn,
        makeContext: @escaping () -> String? = { nil },
        slot: LocalLLMSettings.ConversationSlot = .main,
        toolRunner: LocalLLMToolRunning? = nil
    ) {
        self.makeTurn = makeTurn
        self.makeContext = makeContext
        self.slot = slot
        self.toolRunner = toolRunner
    }

    public var isBusy: Bool {
        switch phase {
        case .queued, .generating, .acting: return true
        case .idle, .done, .failed, .cancelled: return false
        }
    }

    /// Whitespace-only text is dropped -- a stray ⏎ is a no-op.
    @discardableResult
    public func send(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // A second question supersedes the first: the server runs one local
        // generation at a time, so leaving the old one running would put the new
        // one behind it for an answer nobody is going to read.
        handle?.cancel()

        guard let turn = makeTurn() else {
            prompt = trimmed
            answer = ""
            phase = .failed("로컬 LLM 주소가 설정되지 않았습니다")
            onChange?()
            return false
        }

        // `prompt` is what the panel prints under 묻기:, so it stays the words that
        // were typed. A document body can be 8,000 characters; putting it here would
        // bury the question in the box.
        prompt = trimmed
        answer = ""
        thinking = ""
        draft = ""
        backend = nil
        step = 0
        didCorrect = false
        phase = .queued(position: 0)
        onChange?()

        handle = turn(
            Self.wire(prompt: trimmed, context: makeContext(), tools: toolRunner),
            LocalLLMSettings.conversationID(slot),
            { [slot] newID in LocalLLMSettings.setConversationID(newID, for: slot) },
            { [weak self] event in self?.apply(event) }
        )
        return true
    }

    /// What actually goes on the wire.
    ///
    /// Pure, and shared with `trolley ask`, which builds its client directly rather
    /// than through this session -- one function is what keeps the two paths honestly
    /// identical instead of merely similar.
    ///
    /// The reference material goes first and the question last. The server takes a
    /// single `content` string with no system-prompt field, so position is the only way
    /// to say which part is the material.
    ///
    /// The tool contract goes ahead of even that: it is the rule for the whole exchange,
    /// while the context is something the question draws on. The contract rides on every
    /// question rather than once per conversation, because the loop's own `[도구 결과]`
    /// turns sit between one question and the next -- by the time someone asks a second
    /// thing, the contract can be a dozen messages back.
    public static func wire(
        prompt: String, context: String? = nil, tools: LocalLLMToolRunning? = nil
    ) -> String {
        var parts: [String] = []
        if let tools {
            parts.append(ToolCallContract.preamble(
                tools: tools.toolCatalog, runningApps: tools.runningAppSummaries
            ))
        }
        if let context, !context.isEmpty { parts.append(context) }
        parts.append(prompt)
        return parts.joined(separator: "\n\n---\n\n")
    }

    public func cancel() {
        guard isBusy else { return }
        handle?.cancel()
        handle = nil
        phase = .cancelled
        onChange?()
    }

    /// Drops the thread and starts a clean one.
    ///
    /// The button exists because the alternative is invisible. The server replays every
    /// message of a conversation as the prompt, so a finished task stays in front of the
    /// model until something clears it -- measured, a "크롬 켜줘" that answered with the
    /// previous task's closing line, word for word. There is no way to see that from the
    /// panel and no way to undo it by rephrasing; the only fix is a new thread.
    ///
    /// Only the id is dropped. The conversation stays on the server, where its own web UI
    /// can still show it -- this is a fresh start, not a delete.
    public func startNewConversation() {
        handle?.cancel()
        handle = nil
        LocalLLMSettings.setConversationID(nil, for: slot)
        clear()
    }

    /// Reads the current thread back for the transcript view, condensed by
    /// `TranscriptRendering`. Empty when nothing has been asked yet.
    public func loadTranscript(completion: @escaping (Result<[TranscriptRendering.Line], Error>) -> Void) {
        guard let conversationID = LocalLLMSettings.conversationID(slot),
              let config = LocalLLMSettings.makeConfig()
        else {
            completion(.success([]))
            return
        }
        LocalLLMClient(config: config).messages(conversationID: conversationID) { result in
            switch result {
            case .success(let messages):
                completion(.success(TranscriptRendering.lines(from: messages)))
            case .failure(let failure):
                completion(.failure(failure))
            }
        }
    }

    public func clear() {
        handle?.cancel()
        handle = nil
        prompt = ""
        answer = ""
        thinking = ""
        draft = ""
        backend = nil
        step = 0
        didCorrect = false
        phase = .idle
        onChange?()
    }

    private func apply(_ event: LocalLLMClient.Event) {
        switch event {
        case .queued(let position):
            phase = .queued(position: position)
        case .started(let backend):
            self.backend = backend
            phase = .generating
        case .token(let kind, let text):
            phase = .generating
            // Once a token is confirmed the preview is behind, not ahead.
            draft = ""
            if kind == "thinking" {
                thinking += text
            } else {
                answer += text
            }
        case .draft(let text):
            phase = .generating
            if answer.isEmpty { draft = Self.condenseDraft(text) }
        case .finished:
            draft = ""
            handle = nil
            // The one place the loop hooks in. Everything above is the plain streaming
            // session; `advance` decides whether this finished answer was actually a
            // finished answer, and leaves `phase` alone when the exchange goes on.
            if toolRunner == nil || !advance() {
                phase = .done
            }
        case .failed(let message):
            draft = ""
            phase = .failed(message)
            handle = nil
        case .cancelled:
            draft = ""
            phase = .cancelled
            handle = nil
        }
        onChange?()
    }

    // MARK: - The tool loop

    /// What the panel prints, as opposed to what the model actually emitted.
    ///
    /// The two are not the same thing while a tool loop is running. `answer` holds the
    /// contract -- JSON -- and showing it put `{"tool": "click", "arguments": {...}}` in
    /// the reply box where a person looks for a reply. Plain chat has no such envelope,
    /// so with no tool runner attached this is just the answer.
    public var visibleAnswer: String {
        guard toolRunner != nil else { return answer }
        // Settled turns have already been unwrapped by `advance`; re-parsing prose that
        // happens to start with a brace would blank a legitimate reply.
        switch phase {
        case .done, .failed, .cancelled: return answer
        case .idle, .queued, .generating, .acting:
            return ToolCallContract.streamingProse(spokenTurn()) ?? ""
        }
    }

    /// The turn's output, wherever the server happened to put it.
    ///
    /// The model routinely emits its whole move on the reasoning channel and leaves the
    /// answer channel empty. Not occasionally -- four times in one measured 58-message
    /// conversation, each one a perfectly well-formed move sitting in `thinking`:
    ///
    ///     25 ASST   0자  ''
    ///           thinking 36자: {"answer": "Google Chrome을 실행했습니다."}
    ///
    /// Read from `answer` alone that is an empty response, so the loop spent its one
    /// correction re-asking for a format the model had already produced. It worked --
    /// every one of those four recovered on the retry -- which is exactly why it went
    /// unnoticed: the cost was a wasted round trip, and on a single-worker local model
    /// that is seconds. The failure only surfaced when a task leaked twice, spent the
    /// correction on the first, and had nothing left when the closing answer leaked too.
    /// The search had already succeeded; only the report of it failed.
    ///
    /// So this is not a parsing fix and not a prompt fix. The contract was never broken;
    /// the text arrived on the other channel. Narrow on purpose -- `thinking` is
    /// consulted only when there is no answer at all, so a model that reasons out loud
    /// and then answers is still read from its answer.
    private func spokenTurn() -> String {
        let spoken = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard spoken.isEmpty else { return answer }
        return thinking
    }

    /// Reads the finished answer as a move in the contract and plays it.
    ///
    /// - Returns: true when the exchange continues -- a tool is running, or a correction
    ///   has been sent -- and the caller should leave the phase alone. False when this
    ///   was the end.
    private func advance() -> Bool {
        guard let toolRunner else { return false }

        switch ToolCallContract.parse(spokenTurn(), tools: toolRunner.toolCatalog) {
        case .answer(let text):
            // What the panel shows is the prose the model wrote, never the JSON it
            // wrote it inside. This is the only place `answer` is rewritten.
            answer = text
            return false

        case .malformed(let why):
            guard !didCorrect else {
                phase = .failed("모델이 형식을 지키지 못했습니다 — \(why)")
                return true
            }
            didCorrect = true
            continueExchange(with: ToolCallContract.correction)
            return true

        case .call(let name, let arguments):
            guard step < Self.stepLimit else {
                answer = ToolCallContract.stepLimitMessage(Self.stepLimit)
                return false
            }
            step += 1
            phase = .acting(step: step, tool: name)
            // The answer box is cleared per step on purpose: what it held was the tool
            // call JSON, and leaving that on screen would read as trolley's reply.
            answer = ""
            toolRunner.run(name: name, arguments: arguments) { [weak self] result in
                guard let self, case .acting = self.phase else { return }
                self.continueExchange(
                    with: ToolCallContract.resultMessage(tool: name, result: result)
                )
            }
            return true
        }
    }

    /// Posts the next turn into the same conversation.
    ///
    /// A plain `client.ask` rather than a re-entry through `send`: `send` resets the
    /// step counter and re-sends the whole contract, which is exactly what must not
    /// happen in the middle of a loop.
    private func continueExchange(with content: String) {
        guard let turn = makeTurn() else {
            phase = .failed("로컬 LLM 주소가 설정되지 않았습니다")
            onChange?()
            return
        }
        answer = ""
        thinking = ""
        draft = ""
        phase = .queued(position: 0)
        onChange?()

        handle = turn(
            content,
            LocalLLMSettings.conversationID(slot),
            { [slot] newID in LocalLLMSettings.setConversationID(newID, for: slot) },
            { [weak self] event in self?.apply(event) }
        )
    }

    /// Strips the placeholders out of a denoising preview.
    ///
    /// A diffusion canvas is mostly `[Mask]` until late in the pass, and at this
    /// panel's width that is several hundred identical tokens -- a wall that
    /// hides the handful of real words it is there to show. Dropping them leaves
    /// the words appearing in place, which is what the preview is for; early
    /// canvases condense to nothing, and the status line carries it from there.
    public static func condenseDraft(_ text: String) -> String {
        var condensed = text
        for placeholder in ["[Mask]", "<eos>", "<pad>", "<bos>"] {
            condensed = condensed.replacingOccurrences(of: placeholder, with: " ")
        }
        // The removals leave long runs of spaces where the masks were.
        let words = condensed.split(whereSeparator: { $0 == " " || $0 == "\t" })
        return words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What the panel prints under the answer. Pure, so the odd cases (queued
    /// behind nobody, an error with a long body) are testable without a server.
    public static func statusLine(for phase: Phase, backend: String?) -> String {
        switch phase {
        case .idle:
            return ""
        case .queued(let position):
            return position <= 0 ? "보내는 중…" : "대기 중 — 앞에 \(position)건"
        case .generating:
            return backend.map { "생성 중 — \($0)" } ?? "생성 중…"
        case .acting(let step, let tool):
            return "도구 실행 중 — \(tool) (\(step)/\(LocalLLMSession.stepLimit))"
        case .done:
            return backend.map { "완료 — \($0)" } ?? "완료"
        case .cancelled:
            return "중지됨"
        case .failed(let message):
            // One line: the panel truncates, and a stack of wrapped text would
            // push the prompt box off the bottom of the screen.
            let flat = message.replacingOccurrences(of: "\n", with: " ")
            return "실패 — " + (flat.count > 120 ? String(flat.prefix(120)) + "…" : flat)
        }
    }
}
