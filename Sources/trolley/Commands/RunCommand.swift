import ArgumentParser
import TrolleyKit

struct RunCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run a scripted scenario.",
        subcommands: [NotionHeadingSubcommand.self]
    )
}

struct NotionHeadingSubcommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notion-heading",
        abstract: "In Notion, type body text into the block below a heading."
    )

    @Option(help: "Bundle identifier of Notion.")
    var bundleId: String = "notion.id"

    @Option(help: "Text of the heading block to find.")
    var heading: String

    @Option(help: "Text to type into the block below the heading.")
    var body: String

    @Flag(help: "Print the planned action without performing it.")
    var dryRun: Bool = false

    @Flag(help: "Re-search for the body text after typing to confirm it landed.")
    var verify: Bool = false

    @Flag(help: "If the heading block doesn't exist, type it first.")
    var createIfMissing: Bool = false

    func run() throws {
        let checker = SystemTrustChecker()
        guard AccessibilityPermission.ensureTrusted(checker: checker, prompt: true) else {
            print("Accessibility permission not granted. Run `trolley check-permissions` first.")
            throw ExitCode.failure
        }

        let scenario = NotionHeadingBodyScenario(
            bundleID: bundleId,
            heading: heading,
            body: body,
            createIfMissing: createIfMissing,
            dryRun: dryRun
        )

        let launcher = AppLauncher()
        let locator = WorkspaceAppLocator()
        let keyPoster = CGKeyboardSynthesizer()

        do {
            let result = try scenario.run(
                launcher: launcher,
                locator: locator,
                keyPoster: keyPoster,
                makeRoot: { pid in SystemAXElement.application(pid: pid) }
            )

            switch result {
            case .ok:
                print("done")
            case .elementFound(let matches):
                print("matched \(matches.count) element(s)")
            case .failed(let reason):
                print("failed: \(reason)")
                throw ExitCode.failure
            }

            if verify, !dryRun {
                let root = SystemAXElement.application(pid: try launcher.launchOrActivate(bundleID: bundleId, locator: locator))
                let matches = AXTreeWalker().findAll(
                    root: root,
                    query: ElementQuery(textContains: body),
                    limits: AXTraversalLimits()
                )
                print(matches.isEmpty ? "verify: NOT found" : "verify: found \(matches.count) match(es)")
            }
        } catch {
            print("error: \(error)")
            throw ExitCode.failure
        }
    }
}
