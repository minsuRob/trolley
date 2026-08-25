import ApplicationServices
import ArgumentParser
import Foundation
import TrolleyKit

/// Diagnostic: find an element by text and try AXUIElementSetAttributeValue on
/// it directly (bypassing CGEvent entirely) -- useful for testing whether a
/// given native control accepts direct AX value writes.
struct SetValueByTextCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "setvalue")

    @Option var bundleId: String
    @Option var matchText: String
    @Option var newValue: String
    @Option var maxDepth: Int = 25

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

        guard let target = ranked.first else {
            print("no element found containing \"\(matchText)\"")
            throw ExitCode.failure
        }
        print("target role=\(target.stringAttribute(AXAttr.role) ?? "?")")

        let ok = target.setAttribute(AXAttr.value, value: newValue as CFString)
        print("setAttribute ok=\(ok)")
        print("readback=\(target.stringAttribute(AXAttr.value) ?? "(nil)")")
    }
}
