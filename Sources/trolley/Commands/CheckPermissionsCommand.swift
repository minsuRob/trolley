import ArgumentParser
import TrolleyKit

struct CheckPermissionsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check-permissions",
        abstract: "Check (and optionally prompt for) Accessibility trust for this executable."
    )

    @Flag(help: "Trigger the system Accessibility permission prompt if not yet trusted.")
    var prompt: Bool = false

    func run() throws {
        let path = AccessibilityPermission.currentExecutablePath()
        print("executable: \(path)")

        let checker = SystemTrustChecker()
        let trusted = AccessibilityPermission.ensureTrusted(checker: checker, prompt: prompt)

        if trusted {
            print("status: trusted")
        } else {
            print("status: NOT trusted")
            print("Add the exact path above in System Settings → Privacy & Security → Accessibility, then re-run.")
            throw ExitCode.failure
        }
    }
}
