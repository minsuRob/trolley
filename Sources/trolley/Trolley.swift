import ArgumentParser
import TrolleyKit

/// Sits in front of ArgumentParser so a Finder launch can be told apart from a
/// command line before any parsing happens -- with no arguments to parse,
/// ArgumentParser would print help into a void.
@main
struct TrolleyEntry {
    static func main() {
        if WelcomeFlow.shouldRun() {
            WelcomeFlow.run()
            return
        }
        Trolley.main()
    }
}

struct Trolley: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "trolley",
        abstract: "AX-tree grounded macOS UI automation (no screenshots/vision).",
        version: TrolleyVersion.display,
        subcommands: [
            CheckPermissionsCommand.self,
            McpCommand.self,
            AskCommand.self,
            WikiCommand.self,
            UpdateCommand.self,
            DumpTreeCommand.self,
            RunCommand.self,
            ClickCommand.self,
            TypeCommand.self,
            FocusProbeCommand.self,
            SetValueProbeCommand.self,
            SetValueByTextCommand.self,
            ActionNamesProbeCommand.self,
            ExportIconCommand.self
        ]
    )
}
