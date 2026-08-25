import AppKit
import ArgumentParser
import Foundation
import TrolleyKit
import TrolleyMCP

/// Runs trolley as an MCP server over stdio, so an LLM client (Claude Code,
/// Claude Desktop, or anything else speaking MCP) can drive the AX primitives
/// directly instead of scraping the CLI's prose output.
struct McpCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Serve trolley's AX primitives as MCP tools over stdio."
    )

    func run() throws {
        // stdout is the JSON-RPC channel; anything else printed there corrupts
        // the protocol stream.
        let tools = TrolleyTools(
            trustChecker: SystemTrustChecker(),
            locator: WorkspaceAppLocator(),
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

        FileHandle.standardError.write(Data("trolley mcp: ready on stdio\n".utf8))
        MCPServer(provider: tools).run()
    }
}
