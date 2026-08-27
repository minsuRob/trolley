import AppKit
import Foundation
import TrolleyKit
import TrolleyMCP

/// Builds the `TrolleyTools` this machine's tools actually run against.
///
/// Lifted out of `McpCommand`, which was its only caller until the app grew a reason to
/// need one: the widget's prompt box now drives the same tools through
/// `TrolleyToolRunner`. Two constructions of this wiring would be two sets of
/// adapters that could quietly disagree about, say, which apps count as running --
/// and the whole point of the loop is that the model and Claude Code drive the same
/// trolley.
enum ToolHost {
    static func makeTools(launcher: AppLauncher) -> TrolleyTools {
        TrolleyTools(
            trustChecker: SystemTrustChecker(),
            locator: WorkspaceAppLocator(),
            launcher: launcher,
            makeKeyPoster: { targetPid in CGKeyboardSynthesizer(targetPid: targetPid) },
            mousePoster: CGMouseEventPoster(),
            screenCapturer: SystemScreenCapturer(),
            makeRoot: { pid, policy in
                SystemAXElement.application(pid: pid, childrenRetryPolicy: policy)
            },
            activateApp: { pid in
                guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
                return app.activate()
            },
            listRunningApps: runningApps
            // No `wiki:`. These tools drive the screen; the vault is read in its own
            // window, by its own runner, in its own conversation. Passing it here is
            // what put `wiki_search` in front of every "크롬 켜줘" -- the tool catalog
            // rides on every question, so a tool nobody asked about is a tax on all of
            // them. `WikiToolRunner` is the only place it belongs now.
        )
    }

    /// Also handed to the model as the list of things it can address, which is why it
    /// is named rather than inlined: the ids the contract shows and the ids `list_apps`
    /// returns have to be the same ids.
    static func runningApps() -> [AppSummary] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let bundleID = app.bundleIdentifier else { return nil }
                return AppSummary(
                    name: app.localizedName ?? bundleID,
                    bundleID: bundleID,
                    pid: app.processIdentifier,
                    isActive: app.isActive
                )
            }
    }
}
