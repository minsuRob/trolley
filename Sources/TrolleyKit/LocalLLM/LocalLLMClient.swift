import Foundation

/// A client for the `DiffusionGemma-local` server -- the sister project that
/// holds a local model in process and answers over SSE.
///
/// Three calls make one exchange: create (or reuse) a conversation, post the
/// message and get a job id back, then read the job's event stream. It is split
/// that way on the server because a local generation may have to queue behind
/// another one, and the queue position arrives on the stream before any token
/// does.
///
/// Every callback is delivered on the main queue: the only caller that matters
/// is AppKit, and hopping here rather than at each use site is what keeps the
/// widget from touching views off-thread.
public final class LocalLLMClient {
    public struct Config {
        public let baseURL: URL
        /// Only for a server started with `--auth token`.
        public let token: String?

        public init(baseURL: URL, token: String? = nil) {
            self.baseURL = baseURL
            self.token = token
        }
    }

    /// What `/api/status` says. Enough to show whether asking now is going to
    /// mean waiting.
    public struct Status: Equatable {
        public let model: String?
        public let defaultBackend: String?
        public let localLoaded: Bool
        public let busy: Bool
        public let waiting: Int
    }

    public enum Event {
        /// Position 0 means "next"; the server counts places ahead in the line.
        case queued(position: Int)
        case started(backend: String?)
        /// `kind` is `answer` or `thinking` -- the server splits the model's
        /// reasoning channel out for us.
        case token(kind: String, text: String)
        /// A diffusion preview of the block still being denoised. Whole-canvas
        /// text that will be replaced, not appended to.
        case draft(text: String)
        case finished
        case failed(message: String)
        case cancelled
    }

    public enum Failure: LocalizedError {
        case unreachable(String)
        case http(status: Int, detail: String)
        case malformed(String)

        public var errorDescription: String? {
            switch self {
            case .unreachable(let why):
                return "서버에 닿지 못했습니다 — \(why)"
            case .http(let status, let detail):
                if status == 401 { return "인증이 필요합니다 (토큰을 확인하세요)" }
                if status == 503 { return detail.isEmpty ? "서버가 지금 받을 수 없습니다 (503)" : detail }
                return detail.isEmpty ? "서버가 \(status)로 답했습니다" : "\(status): \(detail)"
            case .malformed(let what):
                return "응답을 이해하지 못했습니다 — \(what)"
            }
        }
    }

    /// A running exchange. Holding one lets the caller stop a generation that
    /// is taking longer than it is worth.
    public final class Handle {
        fileprivate var task: Task<Void, Never>?
        fileprivate var jobID: String?
        fileprivate let client: LocalLLMClient
        fileprivate var isCancelled = false

        fileprivate init(client: LocalLLMClient) {
            self.client = client
        }

        /// Stops reading and asks the server to abandon the job. Both halves
        /// matter: dropping the stream alone leaves the model generating, which
        /// on a single-worker server holds up the next question too.
        public func cancel() {
            isCancelled = true
            task?.cancel()
            if let jobID {
                client.post(path: "/api/jobs/\(jobID)/cancel", body: Empty()) { (_: Result<Empty, Failure>) in }
            }
        }
    }

    private let config: Config
    private let session: URLSession

    public init(config: Config) {
        self.config = config
        let configuration = URLSessionConfiguration.ephemeral
        // The stream is idle between tokens and, while queued, between
        // keepalives. The server sends a comment line every 30s, so anything
        // comfortably above that is a real stall rather than a slow answer.
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 1800
        // We put the session cookie on by hand; letting URLSession keep a jar
        // as well would mean two sources of truth for one header.
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration)
    }

    // MARK: - Status

    public func status(completion: @escaping (Result<Status, Failure>) -> Void) {
        Task {
            do {
                let json = try await getJSON(path: "/api/status")
                let status = Status(
                    model: json["model"] as? String,
                    defaultBackend: json["default_backend"] as? String,
                    localLoaded: json["local_loaded"] as? Bool ?? false,
                    busy: json["busy"] as? Bool ?? false,
                    waiting: json["waiting"] as? Int ?? 0
                )
                await MainActor.run { completion(.success(status)) }
            } catch let failure as Failure {
                await MainActor.run { completion(.failure(failure)) }
            } catch {
                await MainActor.run { completion(.failure(.unreachable(error.localizedDescription))) }
            }
        }
    }

    // MARK: - Asking

    /// Sends `prompt` and streams the answer back.
    ///
    /// - Parameter conversationID: the thread to continue. A stored id the
    ///   server has since forgotten (its database was cleared, or it is a
    ///   different server) is not an error -- a fresh conversation is made and
    ///   reported through `onConversation` so the caller can store the new one.
    @discardableResult
    public func ask(
        _ prompt: String,
        conversationID: String?,
        onConversation: @escaping (String) -> Void = { _ in },
        onEvent: @escaping (Event) -> Void
    ) -> Handle {
        let handle = Handle(client: self)
        // Reached through closures rather than a captured `weak` variable: the
        // capture is what Swift 6 rejects, and these are also the only two
        // things the task needs from the handle.
        let noteJobID: (String) -> Void = { [weak handle] id in handle?.jobID = id }
        let wasCancelled: () -> Bool = { [weak handle] in handle?.isCancelled ?? true }

        handle.task = Task {
            do {
                let jobID = try await startChat(
                    prompt, conversationID: conversationID, onConversation: onConversation
                )
                await MainActor.run { noteJobID(jobID) }
                try await readStream(jobID: jobID, onEvent: onEvent)
            } catch is CancellationError {
                await MainActor.run { onEvent(.cancelled) }
            } catch let failure as Failure {
                guard !wasCancelled() else { return }
                await MainActor.run { onEvent(.failed(message: failure.localizedDescription)) }
            } catch {
                guard !wasCancelled() else { return }
                await MainActor.run { onEvent(.failed(message: error.localizedDescription)) }
            }
        }
        return handle
    }

    /// Posts the message, making a conversation when there is none to continue.
    ///
    /// A stored id the server has since forgotten (its database was cleared, or
    /// it is a different server) is recovered rather than raised: it 404s, a
    /// fresh conversation is made, and the message is posted again. Retrying is
    /// safe because the server checks the conversation before it writes
    /// anything, so the failed attempt left no half-sent message behind.
    ///
    /// The 404 is what tells us, rather than a probe first: asking
    /// `/api/conversations/{id}/messages` answers 200 with an empty list for an
    /// id that does not exist, so the probe would pass for a conversation that
    /// is gone -- measured, after deleting one out from under the client.
    private func startChat(
        _ content: String,
        conversationID: String?,
        onConversation: @escaping (String) -> Void
    ) async throws -> String {
        if let conversationID, !conversationID.isEmpty {
            do {
                return try await postChat(conversation: conversationID, content: content)
            } catch Failure.http(404, _) {
                // fall through and start over
            }
        }
        let fresh = try await createConversation()
        await MainActor.run { onConversation(fresh) }
        return try await postChat(conversation: fresh, content: content)
    }

    private func createConversation() async throws -> String {
        let created = try await postJSON(
            path: "/api/conversations",
            body: ["title": "trolley 위젯"]
        )
        guard let id = created["id"] as? String else {
            throw Failure.malformed("conversation id 가 없습니다")
        }
        return id
    }

    private func postChat(conversation: String, content: String) async throws -> String {
        let json = try await postJSON(
            path: "/api/chat",
            body: ["conversation_id": conversation, "content": content]
        )
        guard let jobID = json["job_id"] as? String else {
            throw Failure.malformed("job_id 가 없습니다")
        }
        return jobID
    }

    private func readStream(jobID: String, onEvent: @escaping (Event) -> Void) async throws {
        var request = try makeRequest(path: "/api/stream/\(jobID)", method: "GET")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let (bytes, response) = try await session.bytes(for: request)
        try check(response, body: "")

        var parser = SSELineParser()
        var line: [UInt8] = []
        var terminated = false

        // Split the bytes by hand rather than using `AsyncBytes.lines`, which
        // swallows empty lines -- and in SSE the empty line *is* the frame
        // terminator. With `.lines` every `event:`/`data:` pair arrived and not
        // one frame was ever dispatched: a stream that looked alive and produced
        // nothing.
        for try await byte in bytes {
            guard byte == UInt8(ascii: "\n") else {
                line.append(byte)
                continue
            }
            let text = String(decoding: line, as: UTF8.self)
            line.removeAll(keepingCapacity: true)
            try Task.checkCancellation()
            guard let frame = parser.feed(text) else { continue }
            if await dispatch(frame, to: onEvent) {
                terminated = true
                break
            }
        }
        guard !terminated else { return }
        // The stream ended without a terminal event: the server went away
        // mid-answer. Saying so beats leaving the caller spinning.
        await MainActor.run { onEvent(.failed(message: "스트림이 끊겼습니다")) }
    }

    /// - Returns: true when this frame ends the exchange.
    private func dispatch(_ frame: SSEFrame, to onEvent: @escaping (Event) -> Void) async -> Bool {
        let payload = (try? JSONSerialization.jsonObject(with: Data(frame.data.utf8)))
            as? [String: Any] ?? [:]

        switch frame.event {
        case "queued":
            let position = payload["position"] as? Int ?? 0
            await MainActor.run { onEvent(.queued(position: position)) }
        case "start":
            let backend = payload["backend"] as? String
            await MainActor.run { onEvent(.started(backend: backend)) }
        case "token":
            let kind = payload["kind"] as? String ?? "answer"
            let text = payload["text"] as? String ?? ""
            await MainActor.run { onEvent(.token(kind: kind, text: text)) }
        case "draft":
            let text = payload["text"] as? String ?? ""
            await MainActor.run { onEvent(.draft(text: text)) }
        case "done":
            await MainActor.run { onEvent(.finished) }
            return true
        case "cancelled":
            await MainActor.run { onEvent(.cancelled) }
            return true
        case "error":
            let message = payload["message"] as? String ?? "알 수 없는 오류"
            await MainActor.run { onEvent(.failed(message: message)) }
            return true
        default:
            break   // progress, and anything the server adds later
        }
        return false
    }

    // MARK: - HTTP

    private struct Empty: Codable {}

    private func makeRequest(path: String, method: String) throws -> URLRequest {
        guard let url = URL(string: config.baseURL.absoluteString + path) else {
            throw Failure.unreachable("주소가 올바르지 않습니다: \(config.baseURL.absoluteString)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let token = config.token {
            request.setValue("session=\(token)", forHTTPHeaderField: "Cookie")
        }
        return request
    }

    private func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw Failure.unreachable(error.localizedDescription)
        }
    }

    private func getJSON(path: String) async throws -> [String: Any] {
        let request = try makeRequest(path: path, method: "GET")
        let (data, response) = try await self.data(for: request)
        try check(response, body: String(decoding: data, as: UTF8.self))
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw Failure.malformed("JSON 이 아닙니다")
        }
        return json
    }

    private func postJSON(path: String, body: [String: Any]) async throws -> [String: Any] {
        var request = try makeRequest(path: path, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await self.data(for: request)
        try check(response, body: String(decoding: data, as: UTF8.self))
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw Failure.malformed("JSON 이 아닙니다")
        }
        return json
    }

    /// Fire-and-forget, for the cancel endpoint: nobody is waiting on the answer
    /// and a failure there changes nothing the caller can act on.
    private func post<T: Encodable>(
        path: String,
        body: T,
        completion: @escaping (Result<Empty, Failure>) -> Void
    ) {
        Task {
            guard var request = try? makeRequest(path: path, method: "POST") else { return }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONEncoder().encode(body)
            _ = try? await session.data(for: request)
            completion(.success(Empty()))
        }
    }

    /// FastAPI puts the human-readable reason in `detail`; the status code alone
    /// cannot tell "queue is full" from "no backend available", and both are 503.
    private func check(_ response: URLResponse, body: String) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard !(200..<300).contains(http.statusCode) else { return }
        var detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if let json = (try? JSONSerialization.jsonObject(with: Data(detail.utf8))) as? [String: Any],
           let value = json["detail"] as? String {
            detail = value
        }
        throw Failure.http(status: http.statusCode, detail: detail)
    }
}
