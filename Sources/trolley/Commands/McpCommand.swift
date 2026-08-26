import AppKit
import ArgumentParser
import Foundation
import TrolleyKit
import TrolleyMCP
import TrolleyWidget

/// Runs trolley as an MCP server over stdio, so an LLM client (Claude Code,
/// Claude Desktop, or anything else speaking MCP) can drive the AX primitives
/// directly instead of scraping the CLI's prose output.
struct McpCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Serve trolley's AX primitives as MCP tools over stdio."
    )

    @Flag(inversion: .prefixedNo, help: "Show the floating status widget (needs a GUI session).")
    var widget = true

    func run() throws {
        // Captured before anything else: once the client dies we are reparented
        // to launchd, and this is what tells that apart from having been started
        // by launchd in the first place.
        startOrphanWatch(OrphanWatch(initialParentPID: getppid()))

        // stdout is the JSON-RPC channel; anything else printed there corrupts
        // the protocol stream. Widget diagnostics go to stderr like everything else.
        // The app owns one long-lived widget; a server that drew its own would
        // stack a second pet on screen and take it away again when the client
        // hangs up. Report across instead -- and stay headless, which also means
        // `claude mcp list` health checks no longer make a pet blink in and out.
        let hostRunning = WidgetHost.isRunning()
        let widgetMode = widget && !hostRunning && CGSessionCopyCurrentDictionary() != nil
        if widget && hostRunning {
            log("widget: trolley.app 이 이미 띄워두고 있어 활동만 전달합니다")
        } else if widget && !widgetMode {
            log("widget disabled: no window server session")
        }

        guard widgetMode else {
            // Headless: exactly the pre-widget behavior. The server blocks the
            // main thread, whose run loop AppLauncher.pumpRunLoop turns while
            // polling launches.
            log("trolley mcp: ready on stdio")
            MCPServer(
                provider: makeTools(launcher: AppLauncher()),
                observer: hostRunning ? ActivityBridge.forwardingObserver : ToolCallObserver()
            ).run()
            return
        }

        // Widget mode: AppKit owns the main thread; the MCP loop moves to a
        // background thread. That flips AppLauncher's needs -- pumpRunLoop on a
        // sourceless background run loop returns immediately (a 15s busy-spin),
        // while the NSRunningApplication KVO it exists for is now refreshed by
        // NSApp's own main run loop. A plain sleep is exactly right here.

        // One queue, two owners: the widget's prompt box writes, `take_prompt`
        // reads. Widget mode only -- headless has no box to type into.
        let promptQueue = PromptQueue()
        let controller = StatusWidgetController(
            permissions: {
                (SystemTrustChecker().isProcessTrusted(), CGPreflightScreenCaptureAccess())
            },
            promptQueue: promptQueue,
            // This process serves `take_prompt` itself, so the panel's agent
            // destination has a reader here -- unlike in the app.
            agentReaderAvailable: true,
            onQuit: {
                log("trolley mcp: quitting (widget menu)")
                Darwin.exit(0)
            }
        )
        let tools = makeTools(
            launcher: AppLauncher(sleeper: { Thread.sleep(forTimeInterval: $0) }),
            promptQueue: promptQueue
        )
        let server = MCPServer(provider: tools, observer: controller.observer)

        let thread = Thread {
            log("trolley mcp: ready on stdio (widget on)")
            server.run()
            // stdin EOF is the client hanging up; matches the headless exit.
            // (Darwin's exit -- ParsableCommand has its own `exit` member.)
            DispatchQueue.main.async { Darwin.exit(0) }
        }
        thread.name = "mcp-stdio"
        thread.start()

        let app = NSApplication.shared
        // Unbundled binary: without an explicit policy the panel may not
        // appear; .accessory also keeps us out of the Dock.
        app.setActivationPolicy(.accessory)
        controller.show()
        app.run()
    }

    private func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    /// Backstop for the shutdown path we cannot rely on. Exit is normally stdin
    /// EOF, but a client that dies while something else still holds the pipe's
    /// write end never delivers one -- `readLine()` blocks forever and, in widget
    /// mode, `app.run()` keeps the process alive with no way to reach it.
    ///
    /// Polling on a plain thread rather than a `Timer` so the same code serves
    /// both modes: headless has no free run loop, its main thread being parked in
    /// `readLine()`.
    private func startOrphanWatch(_ watch: OrphanWatch, interval: TimeInterval = 5) {
        let thread = Thread {
            while true {
                Thread.sleep(forTimeInterval: interval)
                if watch.isOrphaned(currentParentPID: getppid()) {
                    log("trolley mcp: client is gone (reparented to launchd), exiting")
                    Darwin.exit(0)
                }
            }
        }
        thread.name = "orphan-watch"
        thread.start()
    }

    private func makeTools(launcher: AppLauncher, promptQueue: PromptQueue? = nil) -> TrolleyTools {
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
            listRunningApps: {
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
            },
            promptQueue: promptQueue,
            // Only when a folder has actually been pointed at. `rootPath` always has a
            // value -- it falls back to a sensible guess -- so the test is whether that
            // folder is really there, not whether the setting is non-empty.
            wiki: Self.wikiTools()
        )
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
