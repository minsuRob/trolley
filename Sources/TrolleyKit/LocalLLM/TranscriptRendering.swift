import Foundation

/// Turns a stored conversation into something readable in a 360pt panel.
///
/// The raw thread is not it. A single `[도구 결과] snapshot` message is four thousand
/// characters of AX tree -- measured: five of them account for 18,797 of one widget
/// conversation's 28,362 characters -- and pasting that into a narrow panel buries the
/// handful of lines someone opened the transcript to read.
///
/// So each message is reduced to what a person is actually scanning for: who spoke, and
/// either what they said or which tool ran. The full payload is not shown at any width;
/// the server's own web UI is where the raw thread belongs.
public enum TranscriptRendering {
    public struct Line: Equatable {
        public enum Kind: Equatable {
            case question
            case answer
            /// A tool call or its result, collapsed to one line.
            case tool
            /// The contract and other scaffolding, kept but marked.
            case scaffolding
        }

        public let kind: Kind
        public let text: String

        public init(kind: Kind, text: String) {
            self.kind = kind
            self.text = text
        }
    }

    /// Everything the loop bolts onto a question before sending it. Stripping it is what
    /// makes the transcript show what was *asked* rather than what was transmitted.
    private static let separator = "\n\n---\n\n"

    public static func lines(from messages: [LocalLLMClient.Message]) -> [Line] {
        messages.compactMap(line(from:))
    }

    static func line(from message: LocalLLMClient.Message) -> Line? {
        let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return nil }

        if message.role == "assistant" {
            if let call = toolCallSummary(content) {
                return Line(kind: .tool, text: "→ \(call)")
            }
            return Line(kind: .answer, text: answerText(content))
        }

        if content.hasPrefix("[도구 결과]") {
            return Line(kind: .tool, text: "← \(toolResultSummary(content))")
        }
        if content.hasPrefix("JSON 오브젝트 하나만") {
            return Line(kind: .scaffolding, text: "형식 교정 요청")
        }
        // The contract and the wiki digest ride ahead of the question behind a separator;
        // the question is the last part, and it is the only part worth showing.
        let question = content.components(separatedBy: separator).last ?? content
        return Line(kind: .question, text: question.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// `{"tool": "click", "arguments": {...}}` becomes `click`.
    ///
    /// Parsed rather than pattern-matched on the raw text: the model's spacing varies
    /// between turns and a regex tuned to one turn's formatting silently stops matching
    /// on the next.
    private static func toolCallSummary(_ content: String) -> String? {
        guard let data = content.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tool = json["tool"] as? String
        else { return nil }
        guard let arguments = json["arguments"] as? [String: Any], !arguments.isEmpty else {
            return tool
        }
        // One argument is usually the one that identifies the target; more than two makes
        // the line longer than the panel and tells nobody anything extra.
        let shown = arguments.keys.sorted().prefix(2)
            .compactMap { key -> String? in
                guard let value = arguments[key] else { return nil }
                return "\(key)=\(condense(String(describing: value)))"
            }
        return "\(tool) \(shown.joined(separator: " "))"
    }

    private static func answerText(_ content: String) -> String {
        guard let data = content.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let answer = json["answer"] as? String
        else { return content }
        return answer
    }

    /// `[도구 결과] snapshot\n{"nodeCount":53,...}` becomes `snapshot`.
    ///
    /// Split on any whitespace, newlines included. `resultMessage` puts the payload on
    /// the *next line*, not after a space, so splitting on " " alone matched nothing and
    /// the whole four-thousand-character tree came back as the "name" -- which is the one
    /// thing this view exists to prevent. The unit test missed it by hand-writing the
    /// separator instead of asking `ToolCallContract.resultMessage` for it.
    private static func toolResultSummary(_ content: String) -> String {
        let body = content.dropFirst("[도구 결과]".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name = body.split(whereSeparator: \.isWhitespace).first else {
            return "도구 결과"
        }
        return String(name)
    }

    private static func condense(_ value: String) -> String {
        let flat = value.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 24 ? String(flat.prefix(23)) + "…" : flat
    }
}
