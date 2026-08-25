import AppKit
import Foundation
import TrolleyKit
import TrolleyWidget

/// The app, as opposed to the CLI: a folder pet that stays on screen, with the
/// setup window behind it.
///
/// The widget used to belong to `trolley mcp`, so it only existed while a client
/// held the connection -- it never appeared on its own, and it blinked in and out
/// as `claude mcp list` spawned servers to health-check them. Owning it here is
/// what makes "always visible" true; servers now report their activity across
/// with `ActivityBridge`.
enum WelcomeFlow {
    private static var widget: StatusWidgetController?
    private static var setup: SetupWindowController?

    /// launchd sets `__CFBundleIdentifier` to the identifier of the bundle it
    /// opened. Merely being set is not enough to go on: Terminal exports its own
    /// (`com.apple.Terminal`) into every shell it spawns, and a plain `trolley`
    /// typed there would then open a window instead of printing help -- measured,
    /// after this check was first written the loose way. It has to match *our*
    /// identifier, which only a launch of this bundle produces. A bare binary has
    /// no identifier at all, so it never matches.
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
        // .accessory: a pet on screen, not an app in the Dock. Windows still
        // open and come forward.
        app.setActivationPolicy(.accessory)

        let controller = StatusWidgetController(
            permissions: {
                (SystemTrustChecker().isProcessTrusted(), CGPreflightScreenCaptureAccess())
            },
            onQuit: { NSApp.terminate(nil) },
            onOpenSettings: { openSetup() }
        )
        widget = controller
        controller.show()

        ActivityBridge.observe(
            onStarted: { tool in controller.record(started: tool) },
            onFinished: { tool, isError, duration in
                controller.record(finished: tool, isError: isError, duration: duration)
            }
        )

        // Shown on launch only while something still needs attention -- a fresh
        // install has to say what to grant. Once it is all set the pet is the
        // whole interface, and the pet's menu is the one way back.
        if !SetupWindowController.isEverythingReady() {
            openSetup()
        }
        app.run()
    }

    /// The only way to open the window after setup is done: 펫 우클릭 → 설정 열기.
    static func openSetup() {
        if let existing = setup, existing.isVisible {
            existing.bringToFront()
            return
        }
        let controller = SetupWindowController()
        setup = controller
        controller.show()
    }
}
