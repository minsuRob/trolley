import ArgumentParser
import Foundation
import TrolleyKit

/// Asks the local LLM the same way the widget's prompt box does.
///
/// The point is not a second chat client -- it is that the widget's path can be
/// exercised without a GUI. Same settings, same conversation, same server, so a
/// failure seen here is the failure the panel would have shown.
struct AskCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ask",
        abstract: "Ask the local LLM (DiffusionGemma-local) and stream the answer."
    )

    @Argument(help: "The question. Omit it with --check to only probe the server.")
    var prompt: String?

    @Option(help: "Server address for this call only; the stored setting is left alone.")
    var url: String?

    @Flag(help: "Report the server's status and exit.")
    var check = false

    @Flag(help: "Start a new conversation instead of continuing the stored one.")
    var new = false

    @Flag(help: "Print the model's reasoning channel as well as its answer.")
    var showThinking = false

    @Flag(help: "Store --url as the default address and exit.")
    var save = false

    @Flag(help: "Do not attach the llmwiki list to this question.")
    var noWiki = false

    @Flag(help: "Attach the list even if this conversation has already been given it.")
    var forceWiki = false

    @Flag(help: "Print the exact content posted to /api/chat on stderr before sending.")
    var showWire = false

    func run() throws {
        if save {
            guard let url else {
                throw ValidationError("--save 는 --url 과 함께 씁니다.")
            }
            guard LocalLLMSettings.normalize(url) != nil else {
                throw ValidationError("주소를 이해하지 못했습니다: \(url)")
            }
            LocalLLMSettings.baseURLString = url
            print("기본 주소: \(LocalLLMSettings.baseURLString)")
            return
        }

        let base = url ?? LocalLLMSettings.baseURLString
        guard let resolved = LocalLLMSettings.normalize(base) else {
            throw ValidationError("주소를 이해하지 못했습니다: \(base)")
        }
        let client = LocalLLMClient(
            config: LocalLLMClient.Config(baseURL: resolved, token: LocalLLMSettings.token)
        )
        FileHandle.standardError.write(Data("→ \(resolved.absoluteString)\n".utf8))

        if check {
            try runCheck(client)
            return
        }
        guard let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError("물어볼 말을 적어주세요. (예: trolley ask \"안녕\")")
        }
        if new {
            LocalLLMSettings.conversationID = nil
            // A new conversation has been told nothing, so the record of what the old
            // one was told must not make this one look already-informed.
            WikiSettings.clearSent()
        }
        try runAsk(client, prompt: prompt)
    }

    // MARK: - Modes

    private func runCheck(_ client: LocalLLMClient) throws {
        var outcome: Result<LocalLLMClient.Status, LocalLLMClient.Failure>?
        client.status { outcome = $0 }
        pump(while: { outcome == nil })

        switch outcome {
        case .success(let status):
            print("model          : \(status.model ?? "(로컬 모델 없음)")")
            print("default backend: \(status.defaultBackend ?? "-")")
            print("local loaded   : \(status.localLoaded ? "yes" : "no")")
            print("queue          : \(status.busy ? "busy" : "idle"), waiting \(status.waiting)")
        case .failure(let failure):
            throw CleanExit.message(failure.localizedDescription)
        case .none:
            throw CleanExit.message("응답이 없습니다.")
        }
    }

    private func runAsk(_ client: LocalLLMClient, prompt: String) throws {
        var done = false
        var failure: String?
        var lastQueuePosition: Int?

        let conversationID = LocalLLMSettings.conversationID
        let preamble = wikiPreamble(for: conversationID)
        // The same pure function the widget's session uses. Building the wire format
        // twice is how the two paths would drift into being merely similar.
        let content = LocalLLMSession.wire(prompt: prompt, preamble: preamble)
        if showWire {
            note("---- wire (\(content.count) chars) ----")
            FileHandle.standardError.write(Data((content + "\n").utf8))
            note("---- end wire ----")
        } else if let preamble {
            note("wiki — \(preamble.digest.matched)/\(preamble.digest.total)건 · \(preamble.digest.characters)자" +
                 (preamble.isRefresh ? " (재주입)" : ""))
        }

        let handle = client.ask(
            content,
            conversationID: conversationID,
            onConversation: { newID in
                LocalLLMSettings.conversationID = newID
                if let preamble { WikiContext.shared.commit(preamble, conversationID: newID) }
            }
        ) { event in
            switch event {
            case .queued(let position):
                // Only when it changes: the server re-broadcasts positions every
                // time the line moves, and a repeated "waiting 1" reads as a hang.
                if lastQueuePosition != position {
                    lastQueuePosition = position
                    note(position <= 0 ? "queued" : "queued — \(position) ahead")
                }
            case .started(let backend):
                note("generating\(backend.map { " — \($0)" } ?? "")")
            case .token(let kind, let text):
                guard kind != "thinking" || showThinking else { return }
                FileHandle.standardOutput.write(Data(text.utf8))
            case .draft:
                break   // a preview of text that is about to arrive for real
            case .finished:
                FileHandle.standardOutput.write(Data("\n".utf8))
                done = true
            case .cancelled:
                failure = "중지됨"
                done = true
            case .failed(let message):
                failure = message
                done = true
            }
        }

        if let conversationID, let preamble {
            WikiContext.shared.commit(preamble, conversationID: conversationID)
        }

        // ^C should stop the generation on the server too, not just here: it runs
        // one at a time, so an abandoned job holds up the next question.
        installInterrupt { handle.cancel() }

        pump(while: { !done })
        if let failure {
            throw CleanExit.message(failure)
        }
    }

    /// `--force-wiki` bypasses the already-sent check by clearing the record rather
    /// than by a second code path, so what it exercises is the real decision.
    private func wikiPreamble(for conversationID: String?) -> WikiPreamble? {
        guard !noWiki else { return nil }
        if forceWiki { WikiSettings.clearSent() }
        return WikiContext.shared.preamble(conversationID: conversationID)
    }

    // MARK: - Plumbing

    /// The client answers on the main queue, so the main thread must keep
    /// servicing it -- blocking on a semaphore here would deadlock against the
    /// very callback being waited for.
    private func pump(while condition: () -> Bool) {
        while condition() {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    private func note(_ text: String) {
        FileHandle.standardError.write(Data("[\(text)]\n".utf8))
    }

    /// A dispatch source rather than `signal()`: the handler runs on a queue
    /// instead of in signal context, so it may do real work.
    private func installInterrupt(_ handler: @escaping () -> Void) {
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        source.setEventHandler(handler: handler)
        source.resume()
        interruptSource = source
    }
}

/// Held past `installInterrupt` -- a cancelled `DispatchSourceSignal` stops
/// firing, and a local would be released as soon as the function returned.
private var interruptSource: DispatchSourceSignal?
