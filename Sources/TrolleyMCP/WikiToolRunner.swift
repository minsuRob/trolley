import Foundation
import TrolleyKit

/// The wiki's two tools, and nothing else, for the wiki window's prompt.
///
/// A sibling of `TrolleyToolRunner` rather than a flag on it, because what the two offer
/// has no overlap at all. That runner exists to drive this Mac -- thirteen tools that
/// launch apps, read accessibility trees, click and type. This one reads markdown files.
/// A model asked about a wiki page has no business being told it can press ⌘T, and the
/// list is read from the top: with the screen tools present the 26B model reached for
/// `launch_app` on a wiki question, which is why they used to be *prepended* to work
/// around a catalog they should never have shared.
///
/// Keeping them apart is the separation itself. The widget's prompt box cannot reach the
/// vault, and this cannot reach the screen, and neither needs a setting to say so.
public final class WikiToolRunner: LocalLLMToolRunning {
    private let wiki: WikiTools
    private let observer: ToolCallObserver
    /// Walking the vault is disk work -- 25ms warm, more when the index is cold -- and
    /// the window's run loop is the main thread. Same reason `TrolleyToolRunner` has one.
    private let queue = DispatchQueue(label: "ink.markhub.trolley.wikitoolrunner")

    public init(wiki: WikiTools = WikiTools(), observer: ToolCallObserver = ToolCallObserver()) {
        self.wiki = wiki
        self.observer = observer
    }

    public var toolCatalog: [ToolCallContract.ToolSummary] { WikiTools.summaries }

    /// Empty, and it has to be. The contract prints this as "지금 실행 중인 앱", and naming
    /// the apps on this Mac to a model that cannot touch any of them is an invitation to
    /// answer a wiki question by talking about Chrome.
    public var runningAppSummaries: [String] { [] }

    public func run(
        name: String,
        arguments: [String: ToolCallContract.JSONArgument],
        completion: @escaping (String) -> Void
    ) {
        let payload = JSONValue.object(arguments.mapValues(TrolleyToolRunner.value(from:)))
        observer.toolCallStarted(name)
        let startedAt = Date()

        queue.async { [wiki, observer] in
            let text: String
            var isError = false
            do {
                switch name {
                case "wiki_search": text = TrolleyToolRunner.describe(try wiki.search(Arguments(payload)))
                case "wiki_read": text = TrolleyToolRunner.describe(try wiki.read(Arguments(payload)))
                default:
                    isError = true
                    text = TrolleyToolRunner.describe(
                        ToolError(.invalidArgument, "Unknown tool \"\(name)\".").jsonValue
                    )
                }
            } catch let error as ToolError {
                isError = true
                text = TrolleyToolRunner.describe(error.jsonValue)
            } catch {
                isError = true
                text = "{\"error\": \"\(error.localizedDescription)\"}"
            }
            let elapsed = Date().timeIntervalSince(startedAt)
            DispatchQueue.main.async {
                observer.toolCallFinished(name, isError, elapsed)
                completion(text)
            }
        }
    }
}
