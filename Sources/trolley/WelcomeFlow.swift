import AppKit
import Foundation
import TrolleyKit

/// What a double-click in Finder does.
///
/// The bundle exists so trolley can be dragged to /Applications, but a CLI
/// launched from Finder has nowhere to print -- without this the icon would just
/// blink and look broken. So it reports what still needs doing and hands over
/// the exact command to paste.
enum WelcomeFlow {
    /// launchd sets `__CFBundleIdentifier` to the identifier of the bundle it
    /// opened. Merely being set is not enough to go on: Terminal exports its own
    /// (`com.apple.Terminal`) into every shell it spawns, and a plain
    /// `trolley` typed there would then pop a dialog instead of printing help --
    /// measured, after this check was first written the loose way. It has to
    /// match *our* identifier, which only a launch of this bundle produces.
    /// A bare binary has no identifier at all, so it never matches.
    static func shouldRun(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> Bool {
        guard arguments.count == 1, let bundleIdentifier else { return false }
        return environment["__CFBundleIdentifier"] == bundleIdentifier
    }

    static func run() {
        let app = NSApplication.shared
        // .regular so the alert can come to the front on its own; the MCP server
        // picks .accessory for itself and never reaches this path.
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)

        let path = AccessibilityPermission.currentExecutablePath()
        let mcpCommand = "claude mcp add trolley -- \(path) mcp"
        let trusted = SystemTrustChecker().isProcessTrusted()
        let screenRecording = CGPreflightScreenCaptureAccess()

        let alert = NSAlert()
        alert.messageText = "trolley \(TrolleyVersion.current)"
        alert.informativeText = """
        손쉬운 사용: \(trusted ? "허용됨" : "필요합니다")
        화면 기록: \(screenRecording ? "허용됨" : "필요합니다 (screenshot 툴 전용)")

        실행 파일
        \(path)

        MCP 등록 — 터미널에 붙여넣으세요
        \(mcpCommand)
        """
        alert.addButton(withTitle: "MCP 명령 복사")
        alert.addButton(withTitle: trusted ? "권한 설정 열기" : "권한 요청")
        alert.addButton(withTitle: "닫기")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(mcpCommand, forType: .string)
        case .alertSecondButtonReturn:
            // The prompt only nudges; the switch still has to be flipped by hand,
            // so open the pane too.
            _ = AccessibilityPermission.ensureTrusted(checker: SystemTrustChecker(), prompt: true)
            if let pane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(pane)
            }
        default:
            break
        }
    }
}
