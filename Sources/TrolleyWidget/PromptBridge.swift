import AppKit
import Foundation

/// Hands a prompt to whichever process owns the widget, and carries the answer back.
///
/// The prompt box runs its tool loop inside the app, and that is not an accident of
/// layout -- it is where the loop *has* to run. macOS attributes an Accessibility grant
/// to the process responsible for launching, so `trolley` started from a shell or by an
/// MCP client is trusted as that shell or that client, not as trolley. Measured on this
/// machine: the app launched from Finder reports trusted while a `trolley mcp` spawned
/// beside it, same binary and same path, reports not trusted.
///
/// So a prompt typed anywhere else has to be *delivered* to the app rather than acted on
/// where it was typed. That is what this is: `trolley prompt "..."` posts here, the app
/// runs the loop with the permissions it actually has, and the final answer comes back
/// the same way.
///
/// Distributed notifications, matching `ActivityBridge` -- there is no state to keep, and
/// nothing to clean up when either side dies.
public enum PromptBridge {
    public static let submitted = Notification.Name("ink.markhub.trolley.promptSubmitted")
    public static let answered = Notification.Name("ink.markhub.trolley.promptAnswered")

    // MARK: - Asking

    /// Posts a prompt to the running app. Returns false when no app is up to take it,
    /// which the caller should report rather than swallow: a prompt posted into an empty
    /// room looks identical to one that is still generating.
    @discardableResult
    public static func submit(_ text: String, requestID: String) -> Bool {
        guard WidgetHost.isRunning() else { return false }
        post(submitted, ["text": text, "requestID": requestID])
        return true
    }

    /// Called by the CLI while it waits. The observer stays registered for the life of
    /// the wait; the caller owns it.
    public static func observeAnswers(
        _ handler: @escaping (_ requestID: String, _ answer: String, _ isError: Bool) -> Void
    ) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(
            forName: answered, object: nil, queue: .main
        ) { note in
            handler(
                note.userInfo?["requestID"] as? String ?? "",
                note.userInfo?["answer"] as? String ?? "",
                note.userInfo?["isError"] as? Bool ?? false
            )
        }
    }

    // MARK: - Answering

    /// Installed by the app. Every prompt that arrives is run through the widget's own
    /// session, so a prompt sent this way and one typed into the box are the same code
    /// path -- there is no second way for a question to be answered.
    public static func observeSubmissions(
        _ handler: @escaping (_ text: String, _ requestID: String) -> Void
    ) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(
            forName: submitted, object: nil, queue: .main
        ) { note in
            guard let text = note.userInfo?["text"] as? String, !text.isEmpty else { return }
            handler(text, note.userInfo?["requestID"] as? String ?? "")
        }
    }

    public static func answer(requestID: String, answer: String, isError: Bool) {
        guard !requestID.isEmpty else { return }
        post(answered, ["requestID": requestID, "answer": answer, "isError": isError])
    }

    private static func post(_ name: Notification.Name, _ userInfo: [String: Any]) {
        DistributedNotificationCenter.default().postNotificationName(
            name, object: nil, userInfo: userInfo, deliverImmediately: true
        )
    }
}
