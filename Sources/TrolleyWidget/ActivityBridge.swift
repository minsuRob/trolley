import AppKit
import Foundation
import TrolleyMCP

/// Carries tool-call activity to whichever process
/// owns the widget.
///
/// The widget used to live inside the server, which meant it only existed while
/// a client held the connection: it never appeared without one, and it blinked
/// in and out as `claude mcp list` spawned servers for its health check and
/// closed them again. Now the app owns one long-lived widget and servers report
/// into it.
///
/// Distributed notifications rather than a socket: there is no state to keep, a
/// missed message costs an animation frame, and there is nothing to clean up when
/// either side dies.
public enum ActivityBridge {
    public static let started = Notification.Name("ink.markhub.trolley.toolCallStarted")
    public static let finished = Notification.Name("ink.markhub.trolley.toolCallFinished")

    /// Handed to the tool runner in place of a widget of our own.
    public static var forwardingObserver: ToolCallObserver {
        ToolCallObserver(
            toolCallStarted: { name in
                post(started, ["tool": name])
            },
            toolCallFinished: { name, isError, duration in
                post(finished, ["tool": name, "isError": isError, "duration": duration])
            }
        )
    }

    /// - Parameters are called on the main queue, ready to touch AppKit.
    public static func observe(
        onStarted: @escaping (String) -> Void,
        onFinished: @escaping (String, Bool, TimeInterval) -> Void
    ) {
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: started, object: nil, queue: .main) { note in
            onStarted(note.userInfo?["tool"] as? String ?? "?")
        }
        center.addObserver(forName: finished, object: nil, queue: .main) { note in
            onFinished(
                note.userInfo?["tool"] as? String ?? "?",
                note.userInfo?["isError"] as? Bool ?? false,
                note.userInfo?["duration"] as? TimeInterval ?? 0
            )
        }
    }

    private static func post(_ name: Notification.Name, _ userInfo: [String: Any]) {
        // deliverImmediately: the default coalesces and delays, which for a
        // progress indicator means the spinner starts after the call finishes.
        DistributedNotificationCenter.default().postNotificationName(
            name, object: nil, userInfo: userInfo, deliverImmediately: true
        )
    }
}

/// Whether a process is already showing the widget.
public enum WidgetHost {
    public static let bundleIdentifier = "ink.markhub.trolley"

    /// Excludes this process: a server that has already created its own
    /// `NSApplication` registers under the same identifier and would otherwise
    /// find itself.
    public static func isRunning() -> Bool {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .contains { $0.processIdentifier != getpid() }
    }
}
