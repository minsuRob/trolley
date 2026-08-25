import ApplicationServices
import ArgumentParser
import Foundation
import TrolleyKit

/// Diagnostic: find an element by text and list its supported AX action names,
/// then optionally try performing one (e.g. a "confirm/go" action instead of
/// a CGEvent Return keypress).
struct ActionNamesProbeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "actions-probe")

    @Option var bundleId: String
    @Option var matchText: String
    @Option var maxDepth: Int = 25
    @Option(help: "If given, try performing this action name after listing.")
    var perform: String?

    func run() throws {
        let checker = SystemTrustChecker()
        guard AccessibilityPermission.ensureTrusted(checker: checker, prompt: true) else {
            print("not trusted"); throw ExitCode.failure
        }
        guard let pid = try? RunHelpers.activePid(bundleID: bundleId) else {
            print("\(bundleId) not running"); throw ExitCode.failure
        }

        let root = SystemAXElement.application(pid: pid)
        let walker = AXTreeWalker()
        let limits = AXTraversalLimits(maxDepth: maxDepth)
        let matches = walker.findAll(root: root, query: ElementQuery(textContains: matchText), limits: limits)
        let ranked = ElementMatcher.rankByLeafiness(matches.map(\.element))

        guard let target = ranked.first as? SystemAXElement else {
            print("no element found containing \"\(matchText)\"")
            throw ExitCode.failure
        }
        print("target role=\(target.stringAttribute(AXAttr.role) ?? "?")")

        var actionNames: CFArray?
        let err = AXUIElementCopyActionNames(target.rawElement, &actionNames)
        let names = (actionNames as? [String]) ?? []
        print("actions err=\(err.rawValue) names=\(names)")

        if let perform {
            let ok = target.performAction(perform)
            print("performAction(\(perform)) ok=\(ok)")
        }
    }
}
