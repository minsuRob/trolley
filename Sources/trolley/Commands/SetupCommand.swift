import ArgumentParser

/// The same window a double-click opens, reachable from a terminal.
struct SetupCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Open the setup window: permissions and Claude Code registration."
    )

    func run() throws {
        WelcomeFlow.run(alwaysShowSetup: true)
    }
}
