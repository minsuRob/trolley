import ArgumentParser
import CoreGraphics
import Foundation
import TrolleyKit

/// Generic, reusable action primitives exposed directly on the CLI (not tied
/// to the Notion scenario) so the AX click/focus/type primitives can be
/// exercised against arbitrary apps.
struct ClickCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "click",
        abstract: "Find an element by text and click it (AXPress, falling back to a synthesized mouse click)."
    )

    @Option(help: "Bundle identifier of the target app.")
    var bundleId: String

    @Option(help: "Substring to search for in the element's value/title/description.")
    var text: String

    @Option(help: "Maximum tree depth to search.")
    var maxDepth: Int = 25

    func run() throws {
        let checker = SystemTrustChecker()
        guard AccessibilityPermission.ensureTrusted(checker: checker, prompt: true) else {
            print("not trusted"); throw ExitCode.failure
        }
        guard let pid = try? RunHelpers.activePid(bundleID: bundleId) else {
            print("\(bundleId) is not running"); throw ExitCode.failure
        }

        let root = SystemAXElement.application(pid: pid)
        let walker = AXTreeWalker()
        let limits = AXTraversalLimits(maxDepth: maxDepth)
        let matches = walker.findAll(root: root, query: ElementQuery(textContains: text), limits: limits)
        let ranked = ElementMatcher.rankByLeafiness(matches.map(\.element))

        guard let target = ranked.first else {
            print("no element found containing \"\(text)\"")
            throw ExitCode.failure
        }

        let executor = ActionExecutor(
            root: root,
            walker: walker,
            keyPoster: CGKeyboardSynthesizer(),
            limits: limits,
            mouseClicker: { point in RunHelpers.postMouseClick(at: point) }
        )
        let result = executor.perform(.click(target))
        switch result {
        case .ok: print("clicked element matching \"\(text)\" (role=\(target.stringAttribute(AXAttr.role) ?? "?"))")
        case .failed(let reason): print("failed: \(reason)"); throw ExitCode.failure
        case .elementFound: break
        }
    }
}

struct TypeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "type-text",
        abstract: "Activate an app and type text into whatever currently has keyboard focus (CGEvent-based)."
    )

    @Option(help: "Bundle identifier of the target app.")
    var bundleId: String

    @Option(help: "Text to type.")
    var text: String

    func run() throws {
        let checker = SystemTrustChecker()
        guard AccessibilityPermission.ensureTrusted(checker: checker, prompt: true) else {
            print("not trusted"); throw ExitCode.failure
        }

        let launcher = AppLauncher()
        let locator = WorkspaceAppLocator()
        _ = try launcher.launchOrActivate(bundleID: bundleId, locator: locator)
        Thread.sleep(forTimeInterval: 0.4)

        KeyboardActions.type(text, using: CGKeyboardSynthesizer())
        print("typed \"\(text)\" into \(bundleId)")
    }
}

enum RunHelpers {
    static func activePid(bundleID: String) throws -> pid_t {
        let locator = WorkspaceAppLocator()
        guard let info = locator.runningApplication(bundleID: bundleID) else {
            throw AppLauncherError.applicationNotFound(bundleID: bundleID)
        }
        return info.processIdentifier
    }

    static func postMouseClick(at point: CGPoint) {
        let source: CGEventSource? = nil
        let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
        let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
