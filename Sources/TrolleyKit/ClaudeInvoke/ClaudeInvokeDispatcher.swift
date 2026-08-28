import Foundation

/// Runs the checked methods and reports back, once, with everyone's result.
public struct ClaudeInvokeDispatcher {
    private let deliverers: [ClaudeInvokeMethod: ClaudeInvokeDeliverer]

    public init(deliverers: [ClaudeInvokeMethod: ClaudeInvokeDeliverer]) {
        self.deliverers = deliverers
    }

    public static func makeDefault() -> ClaudeInvokeDispatcher {
        ClaudeInvokeDispatcher(deliverers: [
            .terminal: TerminalClaudeDeliverer(),
            .orca: OrcaDispatchDeliverer(),
            .desktop: ClaudeDesktopDeliverer()
        ])
    }

    /// Runs off the caller's thread -- every deliverer blocks on something
    /// (a process, a launch, synthesized input) -- and reports back on the
    /// main queue. Methods run one after another rather than in parallel:
    /// two deliverers racing to activate different apps would fight over
    /// which one is frontmost when its own paste lands.
    public func invoke(
        prompt: String,
        methods: [ClaudeInvokeMethod],
        confirm: @escaping (String) -> Bool,
        completion: @escaping ([ClaudeInvokeResult]) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let results = methods.compactMap { deliverers[$0] }
                .map { $0.deliver(prompt: prompt, confirm: confirm) }
            DispatchQueue.main.async { completion(results) }
        }
    }
}
