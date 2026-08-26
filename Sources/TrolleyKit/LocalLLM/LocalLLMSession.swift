import Foundation

/// The one exchange the widget is showing: what was asked, what has arrived so
/// far, and where it is in the server's queue.
///
/// Only the latest exchange is kept. The panel is 360pt wide and the server's
/// own web UI is where a transcript belongs; what this has to answer is "did my
/// question go anywhere, and what came back".
///
/// Main-thread only, like the widget it feeds. `LocalLLMClient` delivers every
/// callback on the main queue, so nothing here needs a lock -- unlike
/// `PromptQueue`, which the MCP thread drains.
public final class LocalLLMSession {
    public enum Phase: Equatable {
        case idle
        /// How many generations are ahead of this one. The local model runs one
        /// at a time by design, so waiting is normal rather than a fault.
        case queued(position: Int)
        case generating
        case done
        case failed(String)
        case cancelled
    }

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

    private let makeClient: () -> LocalLLMClient?
    private let makeWikiPreamble: (String?) -> WikiPreamble?
    private let commitWikiPreamble: (WikiPreamble, String) -> Void
    private var handle: LocalLLMClient.Handle?

    /// - Parameters:
    ///   - makeClient: re-read per send, so changing the address in the setup window
    ///     takes effect on the next question rather than the next launch.
    ///   - makeWikiPreamble: the llmwiki list to put in front of this question, or nil.
    ///     Re-read per send for the same reason, and injected so the wire format can be
    ///     tested without a wiki on disk or a server to answer.
    ///   - commitWikiPreamble: records that the model has been told, which is what
    ///     stops the same list from riding along with every later turn.
    public init(
        makeClient: @escaping () -> LocalLLMClient? = { LocalLLMSettings.makeConfig().map(LocalLLMClient.init(config:)) },
        makeWikiPreamble: @escaping (String?) -> WikiPreamble? = { WikiContext.shared.preamble(conversationID: $0) },
        commitWikiPreamble: @escaping (WikiPreamble, String) -> Void = { WikiContext.shared.commit($0, conversationID: $1) }
    ) {
        self.makeClient = makeClient
        self.makeWikiPreamble = makeWikiPreamble
        self.commitWikiPreamble = commitWikiPreamble
    }

    public var isBusy: Bool {
        switch phase {
        case .queued, .generating: return true
        case .idle, .done, .failed, .cancelled: return false
        }
    }

    /// Whitespace-only text is dropped, matching `PromptQueue` -- a stray ⏎ is a
    /// no-op wherever the box is pointed.
    @discardableResult
    public func send(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // A second question supersedes the first: the server runs one local
        // generation at a time, so leaving the old one running would put the new
        // one behind it for an answer nobody is going to read.
        handle?.cancel()

        guard let client = makeClient() else {
            prompt = trimmed
            answer = ""
            phase = .failed("로컬 LLM 주소가 설정되지 않았습니다")
            onChange?()
            return false
        }

        // `prompt` is what the panel prints under 묻기:, so it stays the words that
        // were typed. The wiki list can be 8,000 characters; putting it here would
        // bury the question in a 360pt-wide box.
        prompt = trimmed
        answer = ""
        thinking = ""
        draft = ""
        backend = nil
        phase = .queued(position: 0)
        onChange?()

        let conversationID = LocalLLMSettings.conversationID
        let preamble = makeWikiPreamble(conversationID)

        handle = client.ask(
            Self.wire(prompt: trimmed, preamble: preamble),
            conversationID: conversationID,
            onConversation: { [commitWikiPreamble] newID in
                LocalLLMSettings.conversationID = newID
                // A fresh conversation only learns its id here, which is why the
                // commit happens in two places rather than one.
                if let preamble { commitWikiPreamble(preamble, newID) }
            },
            onEvent: { [weak self] event in self?.apply(event) }
        )
        // Recorded before the answer arrives, on purpose: the server writes the user
        // message before it queues generation, so a cancelled or failed generation
        // still leaves the list in the persisted history. Having sent it is the fact,
        // whatever came back.
        if let conversationID, let preamble {
            commitWikiPreamble(preamble, conversationID)
        }
        return true
    }

    /// What actually goes on the wire.
    ///
    /// Pure, and shared with `trolley ask`, which builds its client directly rather
    /// than through this session -- one function is what keeps the two paths honestly
    /// identical instead of merely similar.
    ///
    /// The list goes first and the question last. The server takes a single `content`
    /// string with no system-prompt field, so position is the only way to say which
    /// part is the reference material.
    public static func wire(prompt: String, preamble: WikiPreamble?) -> String {
        guard let preamble else { return prompt }
        return preamble.text + "\n\n---\n\n" + prompt
    }

    public func cancel() {
        guard isBusy else { return }
        handle?.cancel()
        handle = nil
        phase = .cancelled
        onChange?()
    }

    public func clear() {
        handle?.cancel()
        handle = nil
        prompt = ""
        answer = ""
        thinking = ""
        draft = ""
        backend = nil
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
            phase = .done
            handle = nil
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
