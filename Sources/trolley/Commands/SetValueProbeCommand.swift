import ApplicationServices
import ArgumentParser
import Foundation
import TrolleyKit

/// Temporary diagnostic: try writing text via AXUIElementSetAttributeValue on
/// the app's focused element, as an alternative to CGEvent HID injection.
struct SetValueProbeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "setvalue-probe")

    @Option var bundleId: String
    @Option var text: String

    func run() throws {
        let checker = SystemTrustChecker()
        guard AccessibilityPermission.ensureTrusted(checker: checker, prompt: true) else {
            print("not trusted"); throw ExitCode.failure
        }
        guard let pid = try? RunHelpers.activePid(bundleID: bundleId) else {
            print("\(bundleId) not running"); throw ExitCode.failure
        }

        let appAX = AXUIElementCreateApplication(pid)
        var focusedUI: AnyObject?
        let err = AXUIElementCopyAttributeValue(appAX, kAXFocusedUIElementAttribute as CFString, &focusedUI)
        print("focusedUI err=\(err.rawValue)")
        guard err == .success, let uiElement = focusedUI else { throw ExitCode.failure }
        let uiAX = uiElement as! AXUIElement

        var role: AnyObject?
        _ = AXUIElementCopyAttributeValue(uiAX, kAXRoleAttribute as CFString, &role)
        print("focused role=\(role as? String ?? "?")")

        let setErr = AXUIElementSetAttributeValue(uiAX, kAXValueAttribute as CFString, text as CFString)
        print("setValue err=\(setErr.rawValue)")

        var readBack: AnyObject?
        _ = AXUIElementCopyAttributeValue(uiAX, kAXValueAttribute as CFString, &readBack)
        print("readBack value=\(readBack as? String ?? "(nil)")")
    }
}
