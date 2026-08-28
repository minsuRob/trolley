import Foundation

/// What actually gets sent, once for whichever methods are checked.
///
/// Pure and static so the one rule worth asserting -- context rides in front
/// of the question, not the other way round -- is testable without a window.
public enum ClaudeInvokePromptBuilder {
    public static func compose(
        userText: String,
        pageTitle: String?,
        pageBody: String?,
        attachContext: Bool
    ) -> String {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard attachContext, let pageTitle, let pageBody, !pageBody.isEmpty else { return trimmed }
        return """
        [[\(pageTitle)]] 위키 문서를 보고 있다:

        \(pageBody)

        ---

        \(trimmed)
        """
    }
}
