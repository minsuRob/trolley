import ArgumentParser
import TrolleyKit

@main
struct Trolley: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "trolley",
        abstract: "AX-tree grounded macOS UI automation (no screenshots/vision).",
        version: TrolleyVersion.current,
        subcommands: [
            CheckPermissionsCommand.self,
            McpCommand.self,
            UpdateCommand.self,
            DumpTreeCommand.self,
            RunCommand.self,
            ClickCommand.self,
            TypeCommand.self,
            FocusProbeCommand.self,
            SetValueProbeCommand.self,
            SetValueByTextCommand.self,
            ActionNamesProbeCommand.self
        ]
    )
}
