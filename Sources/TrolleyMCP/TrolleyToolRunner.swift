import Foundation
import TrolleyKit

/// Runs `TrolleyTools` on behalf of the local model's turn loop.
///
/// The MCP server and this share one `TrolleyTools`, which is the point: a tool the
/// model drives and a tool Claude Code drives are the same code path, so they cannot
/// drift into behaving differently.
public final class TrolleyToolRunner: LocalLLMToolRunning {
    private let tools: TrolleyTools
    private let observer: ToolCallObserver
    private let listApps: () -> [AppSummary]
    /// Tools block -- `wait_for_element` for up to ten seconds, `ActionExecutor` on
    /// every AX call -- and the widget's run loop is the main thread. Running them
    /// there freezes the pet, the panel and the menu bar for the duration.
    private let queue = DispatchQueue(label: "ink.markhub.trolley.toolrunner")

    public init(
        tools: TrolleyTools,
        observer: ToolCallObserver = ToolCallObserver(),
        listApps: @escaping () -> [AppSummary] = { [] }
    ) {
        self.tools = tools
        self.observer = observer
        self.listApps = listApps
    }

    // MARK: - Catalog

    /// The tools the model is told about, as one line each.
    ///
    /// Two of `TrolleyTools`' own definitions are deliberately absent.
    ///
    /// `screenshot` returns a JPEG, and `/api/chat` carries a single text string -- the
    /// image has nowhere to go, so offering it would spend a ten-second round trip to
    /// tell the model it still cannot see. The accessibility tree is what this loop
    /// navigates by, and for automation it is the better surface anyway.
    ///
    /// `check_permissions` is a diagnostic for whoever installed trolley. By the time
    /// the widget is taking questions the answer is yes, and a model that spends its
    /// first step asking is a model that wasted it.
    public var toolCatalog: [ToolCallContract.ToolSummary] {
        var catalog: [ToolCallContract.ToolSummary] = [
            .init(name: "list_apps", parameters: ["nameContains"], summary: "실행 중인 앱과 bundleId 목록"),
            .init(name: "launch_app", parameters: ["bundleId"], summary: "앱을 켜고 앞으로 가져온다"),
            .init(name: "snapshot", parameters: ["bundleId", "textContains", "role"],
                  summary: "앱 화면 구조를 읽는다. 각 노드에 id 와 좌표가 붙는다"),
            .init(name: "find_elements", parameters: ["bundleId", "text", "role"],
                  summary: "글자나 역할로 요소를 찾아 id 를 준다"),
            .init(name: "click", parameters: ["elementId", "bundleId", "text"],
                  summary: "요소를 누른다. elementId 또는 bundleId+text 로 지정"),
            .init(name: "focus", parameters: ["elementId", "bundleId", "text"],
                  summary: "요소에 키보드 초점을 준다"),
            .init(name: "type_text", parameters: ["text", "elementId", "bundleId"],
                  summary: "초점이 있는 곳에 글자를 넣는다. elementId 나 bundleId 를 꼭 함께 준다"),
            .init(name: "press_key", parameters: ["key", "modifiers", "bundleId"],
                  summary: "키를 누른다. key=return, modifiers=[\"cmd\"] 처럼"),
            .init(name: "set_ax_value", parameters: ["elementId", "value"],
                  summary: "요소 값을 직접 쓴다"),
            .init(name: "wait_for_element", parameters: ["bundleId", "text", "role"],
                  summary: "요소가 나타날 때까지 기다린다. 화면이 바뀐 뒤엔 이걸 쓴다"),
            .init(name: "click_at", parameters: ["x", "y"], summary: "화면 좌표를 누른다"),
            .init(name: "move_mouse", parameters: ["x", "y"], summary: "누르지 않고 마우스만 옮긴다")
        ]
        // Prepended, not appended. Thirteen screen-driving tools ahead of them was
        // enough for the model to reach for `launch_app` on a wiki question; a list is
        // read from the top, and these two are the cheapest calls in it.
        if tools.tools.contains(where: { $0.name == "wiki_search" }) {
            catalog.insert(contentsOf: [
                // Parameter names have to be the schemas' own. `ToolSummary.signature`
                // renders them straight into the prompt as the call signature, so the
                // `query`/`path` this used to say was an instruction to make a call that
                // `WikiTools` rejects -- with no way for the model to find that out.
                //
                // And all of them, not the five this listed. Under `.auto` this line is
                // the whole filter UI: whatever it does not name is an axis the model
                // cannot choose, which would leave 유형·분류·영역·우선순위·폴더 to a
                // setting made last week by someone who had not heard the question.
                .init(name: "wiki_search",
                      parameters: [
                          "titleContains", "status", "type", "category", "area",
                          "priority", "assignee", "folder", "sort", "detail", "limit"
                      ],
                      summary: "위키에서 문서를 찾는다. 조건은 필요한 것만 골라 쓰고, 그냥 부르면 전체 목록"),
                .init(name: "wiki_read", parameters: ["title"],
                      summary: "위키 문서 한 건의 본문을 읽는다. 제목은 [[ ]] 없이 그대로 넣는다")
            ], at: 0)
        }
        return catalog
    }

    /// `이름 (bundleId)` per app, so the model can name a target without spending a
    /// step on `list_apps` -- and without guessing the case, which is how it produced
    /// `com.google.chrome` for Chrome when probed.
    public var runningAppSummaries: [String] {
        listApps().map { "\($0.name) (\($0.bundleID))" }
    }

    // MARK: - Running

    public func run(
        name: String,
        arguments: [String: ToolCallContract.JSONArgument],
        completion: @escaping (String) -> Void
    ) {
        let payload = JSONValue.object(arguments.mapValues(Self.value(from:)))
        observer.toolCallStarted(name)
        let startedAt = Date()

        queue.async { [tools, observer] in
            let text: String
            let isError: Bool
            do {
                text = Self.describe(try tools.call(name: name, arguments: payload))
                isError = false
            } catch let error as ToolError {
                // Handed to the model rather than raised: a tool that failed is
                // something to work around, and `jsonValue` carries the hint text that
                // says what to try instead -- the same signal Claude Code gets.
                text = Self.describe(error.jsonValue)
                isError = true
            } catch {
                text = "{\"error\": \"\(error.localizedDescription)\"}"
                isError = true
            }
            let duration = Date().timeIntervalSince(startedAt)
            DispatchQueue.main.async {
                observer.toolCallFinished(name, isError, duration)
                completion(text)
            }
        }
    }

    private static func value(from argument: ToolCallContract.JSONArgument) -> JSONValue {
        switch argument {
        case .string(let text): return .string(text)
        case .number(let number):
            // The tools take pixel counts and depths as ints and timeouts as doubles;
            // a whole number written as 20.0 fails an `intValue` read on the far side.
            return number == number.rounded() ? .int(Int(number)) : .double(number)
        case .bool(let flag): return .bool(flag)
        case .strings(let list): return .array(list.map { .string($0) })
        }
    }

    /// Tool results go back as JSON text, which is what the model was shown in the
    /// contract's own examples -- one notation for both directions.
    private static func describe(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return String(describing: value) }
        return String(decoding: data, as: UTF8.self)
    }
}
