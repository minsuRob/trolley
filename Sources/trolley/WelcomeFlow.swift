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
    /// Held for the life of the process: this static is the only strong reference
    /// to the status item, and to the target every menu item points at weakly.
    private static var menuBar: MenuBarController?

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

        // The menu bar is the way in for someone who has not been told the folder
        // on screen is clickable. Only the app installs one -- `trolley mcp
        // --widget` draws the same pet but must not put an icon up there.
        let bar = MenuBarController(
            onAsk: { controller.presentPromptPanel(focus: true) },
            onOpenSettings: { openSetup() },
            onQuit: { NSApp.terminate(nil) }
        )
        menuBar = bar
        bar.install()

        // Warmed here so the first question does not pay for a cold walk of the wiki on
        // the main thread, between the keystroke and the request.
        if WikiSettings.isEnabled, let root = WikiSettings.rootURL {
            WikiIndex.shared.prewarm(root: root)
        }

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
        // Already ready at launch -- a reinstall, or the second run after granting.
        // The setup window is not open in that case, so nothing else would observe
        // the transition.
        introduceIfFirstTime(readyNow: SetupWindowController.isEverythingReady())
        app.run()
    }

    /// Opens the prompt box once, ever, so the first thing someone sees after
    /// setup is the box rather than a screen telling them where the box is.
    ///
    /// - Parameter readyNow: what the caller just observed.
    private static func introduceIfFirstTime(readyNow: Bool) {
        var latch = FirstReadyLatch(hasFired: FirstReadyStore.hasIntroduced)
        guard latch.observe(isReady: readyNow) else { return }
        FirstReadyStore.hasIntroduced = latch.hasFired

        // Focus is a judgement call, not a constant. Becoming ready mid-session
        // means the user is in System Settings with a switch under their finger;
        // pulling the keyboard out from under that is rude and misdelivers
        // keystrokes. Taking focus is only right when they are already here.
        let setupIsFront = setup?.isVisible == true
        widget?.presentPromptPanel(focus: NSApp.isActive && !setupIsFront)
    }

    /// The only way to open the window after setup is done: 펫 우클릭 → 설정 열기.
    ///
    /// One controller for the life of the app. Building a fresh one per open
    /// dropped the previous one, and a window that has already released itself
    /// on close takes the process down with it when anything touches it again.
    static func openSetup() {
        if setup == nil {
            let controller = SetupWindowController()
            controller.onAsk = { widget?.presentPromptPanel(focus: true) }
            // The other place the transition is seen: the window is open exactly
            // when something still needs granting, so it always witnesses the
            // moment the last dot turns green.
            controller.onBecameReady = { introduceIfFirstTime(readyNow: true) }
            setup = controller
        }
        setup?.show()
    }
}
