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
            print("accessibility: trusted")
        } else {
            print("accessibility: NOT trusted")
            print("Add the exact path above in System Settings → Privacy & Security → Accessibility, then re-run.")
        }

        // Screen Recording only gates the screenshot tool; AX-only workflows
        // are fine without it, so missing it is reported but not fatal.
        let capturer = SystemScreenCapturer()
        if capturer.hasScreenRecordingAccess() {
            print("screen recording: granted")
        } else {
            print("screen recording: NOT granted (only needed for the screenshot MCP tool)")
            print("Add the same path in System Settings → Privacy & Security → Screen Recording, then restart trolley.")
        }

        if !trusted {
            throw ExitCode.failure
        }
    }
}
