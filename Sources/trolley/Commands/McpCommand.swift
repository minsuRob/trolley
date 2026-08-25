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
        // stdout is the JSON-RPC channel; anything else printed there corrupts
        // the protocol stream. Widget diagnostics go to stderr like everything else.
        let widgetMode = widget && CGSessionCopyCurrentDictionary() != nil
        if widget && !widgetMode {
            log("widget disabled: no window server session")
        }

        guard widgetMode else {
            // Headless: exactly the pre-widget behavior. The server blocks the
            // main thread, whose run loop AppLauncher.pumpRunLoop turns while
            // polling launches.
            log("trolley mcp: ready on stdio")
            MCPServer(provider: makeTools(launcher: AppLauncher())).run()
            return
        }

        // Widget mode: AppKit owns the main thread; the MCP loop moves to a
        // background thread. That flips AppLauncher's needs -- pumpRunLoop on a
        // sourceless background run loop returns immediately (a 15s busy-spin),
        // while the NSRunningApplication KVO it exists for is now refreshed by
        // NSApp's own main run loop. A plain sleep is exactly right here.
        let controller = StatusWidgetController(permissions: {
            (SystemTrustChecker().isProcessTrusted(), CGPreflightScreenCaptureAccess())
        })
        let tools = makeTools(
            launcher: AppLauncher(sleeper: { Thread.sleep(forTimeInterval: $0) })
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

    private func makeTools(launcher: AppLauncher) -> TrolleyTools {
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
            }
        )
    }
}
