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
            listRunningApps: runningApps,
            // Only when a folder has actually been pointed at. `rootPath` always has a
            // value -- it falls back to a sensible guess -- so the test is whether that
            // folder is really there, not whether the setting is non-empty.
            wiki: wikiTools()
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

    private static func wikiTools() -> WikiTools? {
        // The same switch that governs the widget's digest. "위키 참고: 꺼짐" has to mean
        // one thing, not "off for my questions but still listed for the agent" -- and a
        // tool list that changes with a setting the person did not think applied to it
        // is worse than either behaviour on its own.
        guard WikiSettings.isEnabled, let root = WikiSettings.rootURL else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }
        return WikiTools()
    }
}
