import ArgumentParser

@main
struct Trolley: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "trolley",
        abstract: "AX-tree grounded macOS UI automation (no screenshots/vision).",
        subcommands: [
            CheckPermissionsCommand.self,
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
