import AppKit
import ArgumentParser
import Foundation
import TrolleyKit

struct DumpTreeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dump-tree",
        abstract: "Dump an app's accessibility tree to inspect its real structure."
    )

    @Option(help: "Bundle identifier of the target app.")
    var bundleId: String = "notion.id"

    @Option(help: "Maximum tree depth to walk.")
    var maxDepth: Int = 20

    @Option(help: "Write output to this file instead of stdout.")
    var output: String?

    func run() throws {
        let checker = SystemTrustChecker()
        guard AccessibilityPermission.ensureTrusted(checker: checker, prompt: true) else {
            print("Accessibility permission not granted. Run `trolley check-permissions` first.")
            throw ExitCode.failure
        }

        guard let app = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == bundleId }) else {
            print("\(bundleId) is not running. Launch it first (or use `trolley run` which launches it for you).")
            throw ExitCode.failure
        }

        let root = SystemAXElement.application(pid: app.processIdentifier)
        // Best effort: Chromium/Electron apps often need this to fully populate
        // their AX tree beyond the chrome (tab bar, etc). Ignore failure. This is
        // an async signal to Chromium to start building the tree, so give it real
        // wall-clock time before walking.
        _ = root.setAttribute(AXAttr.manualAccessibility, value: true as CFBoolean)
        Thread.sleep(forTimeInterval: 1.5)
        let limits = AXTraversalLimits(maxDepth: maxDepth)
        let text = AXTreeDumper().dump(root: root, limits: limits)

        if let output {
            try text.write(toFile: output, atomically: true, encoding: .utf8)
            print("wrote tree dump to \(output)")
        } else {
            print(text)
        }
    }
}
