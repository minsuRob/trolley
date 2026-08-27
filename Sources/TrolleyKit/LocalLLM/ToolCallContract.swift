import Foundation

/// The wire format that lets a model with no tool-calling API drive trolley's tools.
///
/// `DiffusionGemma-local` takes one `content` string per turn: no system prompt, no
/// `tools` array, no `tool_calls` in the reply. So the contract has to be *said* in the
/// message and *read back* out of the answer text. That is the same trick
/// `LocalLLMSession.wire(prompt:preamble:)` already plays with the wiki list, one level
/// up: position and prose are the only protocol available.
///
/// Everything here is a pure function over strings. That is deliberate -- the parsing
/// rules below were derived from what the 26B model actually emitted when probed, and
/// the only way to keep them honest as the contract wording changes is for a test to be
/// able to run them with no server and no Mac.
public enum ToolCallContract {
    /// One line of the catalog the model reads.
    ///
    /// Not `ToolDefinition`: that carries full JSON Schema, and thirteen of those is
    /// several thousand characters of nested `{"type": "string"}` for a model that has
    /// to hold the whole thing in a 96K window alongside an accessibility tree. A
    /// signature line says the same thing in one line.
    public struct ToolSummary: Equatable {
        public let name: String
        /// Parameter names in call order, required ones first.
        public let parameters: [String]
        /// One clause, lowercase, no trailing period -- they are read as a list.
        public let summary: String

        public init(name: String, parameters: [String], summary: String) {
            self.name = name
            self.parameters = parameters
            self.summary = summary
        }

        public var signature: String {
            "\(name)(\(parameters.joined(separator: ", "))) — \(summary)"
        }
    }

    public enum Outcome: Equatable {
        case call(name: String, arguments: [String: JSONArgument])
        case answer(String)
        /// Nothing JSON-shaped came back, or it was shaped wrong beyond repair.
        case malformed(String)
    }

    /// A tool argument as the model can express it.
    ///
    /// Deliberately not `Any`: `Outcome` has to be `Equatable` for the tests to be
    /// readable, and the argument values the tools take are only ever these four.
    public enum JSONArgument: Equatable {
        case string(String)
        case number(Double)
        case bool(Bool)
        case strings([String])
    }

    // MARK: - What the model is told

    /// The instructions, the catalog, and -- when we have it -- the list of apps that
    /// are actually running.
    ///
    /// The last two rules are there because of one measured failure, not a hypothesis.
    /// Asked to search for 러셀 in Chrome, the model typed into the address bar of the
    /// tab that was already open -- which still held `chrome://whats-new` -- and the
    /// search that ran was `러셀chrome://whats-new`. Two separate defects produced that
    /// one string: it reused the tab the person was looking at, and `type_text` inserts
    /// at the caret without clearing, so anything already in the field survives.
    ///
    /// Both are stated as defaults with an explicit escape, because "이 탭에서 찾아줘"
    /// has to keep working. A rule that cannot be overridden by the person asking is a
    /// worse failure than the one it fixes.
    ///
    /// The app list is not padding. Probed without it, the model guessed
    /// `com.google.chrome` for Chrome, which is the wrong case and matches no running
    /// application; handing it the real ids removes the guess and saves a `list_apps`
    /// round trip, and on a single-worker local model every saved round trip is
    /// several seconds off the wall clock.
    public static func preamble(tools: [ToolSummary], runningApps: [String] = []) -> String {
        var text = """
        너는 이 맥을 직접 조작할 수 있다. 아래 도구가 실제로 실행된다.

        """
        text += tools.map { "- " + $0.signature }.joined(separator: "\n")
        // Before the screen-driving rules, not after them.
        //
        // Measured: asked about a wiki task with only titles in front of it, the 26B
        // model called `launch_app` and then `snapshot` -- it took a question about a
        // document as a reason to go find that document on screen. Everything above is
        // about driving the Mac, so anything appended at the end reads as a footnote to
        // that. Saying which questions are *not* screen questions has to come first, and
        // has to say so in as many words.
        if tools.contains(where: { $0.name == "wiki_read" }) {
            // Now says how to *find* a page, not only how to read one.
            //
            // The old wording ("목록에 제목만 있으면") assumed a list of titles was already in
            // front of the model, and under `WikiSettings.Mode.auto` none ever is: that
            // mode's whole premise is that the model picks the filter after hearing the
            // question. Which axis to reach for is therefore part of the contract now,
            // named by example, because a model told only that `wiki_search` exists has
            // no reason to prefer `assignee` over guessing a title.
            text += """


                위키(llmwiki) 질문은 화면을 조작해서 풀지 않는다. 앱을 켜거나 화면을 보지 않는다.
                먼저 wiki_search 로 문서를 찾는다. 질문에 맞는 조건만 골라 넣는다 —
                이름이 나오면 titleContains, 사람이면 assignee, "진행중"·"완료" 같은 말이면 status,
                web·mobile 같은 말이면 area. 무엇을 찾을지 모르겠으면 조건 없이 그냥 부른다.
                그렇게 나온 제목을 wiki_read 에 그대로 넣어 본문을 읽는다.
                한 번에 한 건씩, 정말 필요한 것만 읽는다. 읽지 않은 문서의 내용은 말하지 않는다.
                """
        }
        if !runningApps.isEmpty {
            text += "\n\n지금 실행 중인 앱: " + runningApps.joined(separator: ", ")
        }
        text += """


        매 차례 JSON 오브젝트 하나만 출력한다. 설명도 코드펜스도 붙이지 않는다.
        도구를 쓸 때: {"tool": "이름", "arguments": {"키": "값"}}
        끝났을 때:   {"answer": "사용자에게 할 말"}

        arguments 는 반드시 "키": "값" 쌍으로 쓴다. 값만 쓰면 안 된다.
        요청이 이미 이루어졌으면 더 하지 말고 그 자리에서 {"answer": ...} 를 낸다.
        도구가 필요 없는 질문이면 첫 차례에 바로 {"answer": ...} 를 낸다.

        검색이나 새 작업은 빈 탭에서 시작한다. 보고 있던 탭을 덮어쓰지 않는다.
        탭이 있는 앱은 press_key key=t modifiers=["cmd"], 없으면 key=n 으로 새로 연다.
        사용자가 "이 탭에서" 처럼 따로 지시하면 그때만 지금 화면을 그대로 쓴다.
        입력칸에 글자가 남아 있으면 press_key key=a modifiers=["cmd"] 로 전부 고른 뒤
        type_text 한다. 그냥 넣으면 이어붙는다.
        """
        return text
    }

    /// What goes back after a tool ran.
    ///
    /// Truncated hard: an `interestingOnly` snapshot of Chrome runs to tens of
    /// thousands of characters, and a few of those in one conversation would push the
    /// thread past the server's 96K soft limit -- at which point it is not the loop
    /// that fails but every later turn in the same conversation.
    public static func resultMessage(tool: String, result: String, limit: Int = 4_000) -> String {
        var body = result
        if body.count > limit {
            body = String(body.prefix(limit)) + "\n…(잘림)"
        }
        return "[도구 결과] \(tool)\n\(body)"
    }

    /// Sent once when the model's output could not be read as either shape.
    ///
    /// One line, and it repeats the contract rather than describing the mistake: a
    /// model that just broke the format is not helped by a critique of the break.
    public static let correction =
        #"JSON 오브젝트 하나만 출력해라. {"tool": "이름", "arguments": {"키": "값"}} 또는 {"answer": "..."} 형식이다."#

    public static func stepLimitMessage(_ limit: Int) -> String {
        "\(limit)단계 안에 끝내지 못했습니다."
    }

    // MARK: - What the person is allowed to see

    /// The prose to print while a turn is still streaming, or nil when there is nothing
    /// a person should be shown yet.
    ///
    /// The panel used to print the raw stream, and the raw stream is the contract: a
    /// half-typed `{"tool": "click", "arguments": {"elementId": "e3", ...}}` sat in the
    /// reply box where the answer goes. That is trolley's protocol leaking into the one
    /// surface that exists for the person -- they asked a question, not for a wire
    /// format.
    ///
    /// Suppressing every brace would fix that and cost the streaming: the final answer
    /// would appear all at once when the turn ended. So an answer-shaped payload is
    /// unwrapped *as it arrives* -- `{"answer": "크롬을 여` prints as `크롬을 여` -- and a
    /// tool-shaped one returns nil, because a tool call has nothing to say. The status
    /// line ("도구 실행 중 — snapshot") is what speaks during those.
    public static func streamingProse(_ raw: String) -> String? {
        let text = stripFences(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        // A model that answers in plain prose is answering; there is no envelope to open.
        guard text.hasPrefix("{") else { return text }

        guard let range = text.range(of: "\"answer\"") else {
            // `{"tool"` -- or too few characters to tell yet. Both are silence: guessing
            // early would flash a fragment of a tool call before it could be recognised.
            return nil
        }
        let rest = text[range.upperBound...]
        guard let open = rest.firstIndex(of: "\"") else { return nil }
        return unescape(String(rest[rest.index(after: open)...]))
    }

    /// Enough of JSON string unescaping for a value that is still being written -- there
    /// is no closing quote to parse against, so `JSONSerialization` cannot be used here.
    private static func unescape(_ partial: String) -> String {
        var out = ""
        var escaped = false
        for character in partial {
            if escaped {
                switch character {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "/": out.append("/")
                default: out.append(character)
                }
                escaped = false
                continue
            }
            if character == "\\" { escaped = true; continue }
            // The closing quote of the value: everything after it is envelope again.
            if character == "\"" { break }
            out.append(character)
        }
        return out
    }

    // MARK: - Reading the answer back

    /// Pulls a tool call or a final answer out of whatever the model produced.
    ///
    /// Forgiving on purpose. Probing the local model turned up code fences, a sentence
    /// before the JSON, and -- the one that actually matters -- an `arguments` object
    /// written as `{"com.google.chrome"}`, a bare value with the key left off. Each
    /// recovery below is there because the model did that, not because it might.
    public static func parse(_ raw: String, tools: [ToolSummary] = []) -> Outcome {
        let stripped = stripFences(raw)
        guard let object = firstJSONObject(in: stripped) else {
            // No braces at all. A model that answers in plain prose has, in substance,
            // given a final answer; treating that as a failure would throw away a
            // perfectly good reply over punctuation.
            let text = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? .malformed("빈 응답") : .answer(text)
        }

        if let answer = object["answer"] {
            if case .string(let text) = answer { return .answer(text) }
            return .malformed("answer 가 문자열이 아닙니다")
        }

        guard case .string(let name)? = object["tool"] else {
            return .malformed("tool 도 answer 도 없습니다")
        }
        let tool = tools.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        let resolved = tool?.name ?? name

        switch object["arguments"] {
        case .some(.object(let arguments)):
            return .call(name: resolved, arguments: arguments)
        case .some(.bareValues(let values)):
            // `{"arguments": {"com.google.chrome"}}`. Recoverable only when the tool
            // has parameters to bind them to positionally, which is why the catalog
            // lists parameters in call order.
            guard let tool, !tool.parameters.isEmpty else {
                return .malformed("arguments 에 키가 없습니다")
            }
            var bound: [String: JSONArgument] = [:]
            for (index, value) in values.enumerated() where index < tool.parameters.count {
                bound[tool.parameters[index]] = value
            }
            return bound.isEmpty ? .malformed("arguments 에 키가 없습니다") : .call(name: resolved, arguments: bound)
        case .none:
            // A no-argument tool such as list_apps.
            return .call(name: resolved, arguments: [:])
        default:
            return .malformed("arguments 가 오브젝트가 아닙니다")
        }
    }

    // MARK: - Tolerant JSON

    /// What a parsed value can be. `bareValues` is the repair case and has no JSON
    /// equivalent -- it is what `{"a"}` becomes.
    private enum Value {
        case string(String)
        case number(Double)
        case bool(Bool)
        case object([String: JSONArgument])
        case bareValues([JSONArgument])
        case other
    }

    private static func stripFences(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("```") else { return text }
        // Drop the opening fence and its language tag, then the closing one.
        if let firstNewline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: firstNewline)...])
        }
        if let closing = text.range(of: "```", options: .backwards) {
            text = String(text[..<closing.lowerBound])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Finds the first balanced `{...}` and parses it, ignoring any prose around it.
    ///
    /// Brace counting rather than `JSONSerialization` on the whole string: the model
    /// prefaces the object with a sentence often enough that requiring the entire reply
    /// to be valid JSON would fail on answers that are otherwise perfect.
    private static func firstJSONObject(in text: String) -> [String: Value]? {
        let characters = Array(text)
        guard let start = characters.firstIndex(of: "{") else { return nil }

        var depth = 0
        var inString = false
        var escaped = false
        for index in start..<characters.count {
            let character = characters[index]
            if escaped {
                escaped = false
                continue
            }
            if character == "\\" && inString {
                escaped = true
                continue
            }
            if character == "\"" {
                inString.toggle()
                continue
            }
            guard !inString else { continue }
            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return parseObject(String(characters[start...index]))
                }
            }
        }
        return nil
    }

    private static func parseObject(_ json: String) -> [String: Value]? {
        guard let parsed = deserialize(json) as? [String: Any] else {
            // Not valid JSON even after repair. The one shape worth rescuing is the
            // missing-key object, which cannot be expressed as JSON at all.
            return bareValueObject(json)
        }
        var object: [String: Value] = [:]
        for (key, value) in parsed {
            object[key] = convert(value)
        }
        return object
    }

    /// Trailing commas are the one syntax slip common enough to be worth repairing
    /// before giving up on a string.
    private static func deserialize(_ json: String) -> Any? {
        if let value = try? JSONSerialization.jsonObject(with: Data(json.utf8)) { return value }
        let repaired = json.replacingOccurrences(
            of: ",\\s*([}\\]])", with: "$1", options: .regularExpression
        )
        return try? JSONSerialization.jsonObject(with: Data(repaired.utf8))
    }

    /// Rescues `{"tool": "x", "arguments": {"value"}}`.
    ///
    /// Only the inner `arguments` object is ever written this way -- the model gets the
    /// outer keys right -- so the repair is: quote-split the whole thing, then hand the
    /// leftovers back as positional values for `parse` to bind.
    private static func bareValueObject(_ json: String) -> [String: Value]? {
        guard let argumentsRange = json.range(of: "\"arguments\"") else { return nil }
        let head = String(json[..<argumentsRange.lowerBound]) + "}"
        guard var object = parseObject(head.replacingOccurrences(
            of: ",\\s*}$", with: "}", options: .regularExpression
        )) else { return nil }

        let tail = String(json[argumentsRange.upperBound...])
        // The *first* close brace after the opening one, not the last: the last is the
        // outer object's, and taking it drags `"}` into the value.
        guard let open = tail.firstIndex(of: "{"),
              let close = tail[tail.index(after: open)...].firstIndex(of: "}")
        else { return nil }
        let inner = String(tail[tail.index(after: open)..<close])
        let values = inner
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            .filter { !$0.isEmpty && !$0.contains(":") }
        guard !values.isEmpty else { return nil }
        object["arguments"] = .bareValues(values.map { .string($0) })
        return object
    }

    private static func convert(_ value: Any) -> Value {
        switch value {
        case let text as String:
            return .string(text)
        case let flag as Bool:
            return .bool(flag)
        case let number as NSNumber:
            // NSNumber bridges booleans too; the `as Bool` above catches those first.
            return .number(number.doubleValue)
        case let nested as [String: Any]:
            var arguments: [String: JSONArgument] = [:]
            for (key, inner) in nested {
                if let argument = argument(from: inner) { arguments[key] = argument }
            }
            return .object(arguments)
        default:
            return .other
        }
    }

    private static func argument(from value: Any) -> JSONArgument? {
        switch value {
        case let text as String: return .string(text)
        case let flag as Bool: return .bool(flag)
        case let number as NSNumber: return .number(number.doubleValue)
        case let list as [Any]: return .strings(list.compactMap { $0 as? String })
        default: return nil
        }
    }
}
