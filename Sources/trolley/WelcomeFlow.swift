import AppKit
import Foundation
import TrolleyKit
import TrolleyMCP
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
    /// Owns the six-hour timer. Held for the same reason as the others: dropping
    /// it cancels the schedule, and a checker that stops after one run is worse
    /// than none because it looks like it is working.
    private static var updates: UpdateCoordinator?

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

        // The app has always drawn the widget and never owned any tools; the prompt
        // box was a chat window onto a model that could not touch this Mac, and said
        // so when asked to. These are the same tools `trolley mcp` serves to Claude
        // Code -- what changes is only who gets to call them.
        //
        // The launcher sleeps rather than pumping the run loop: AppKit owns the main
        // thread here, and `TrolleyToolRunner` runs the call off it. Pumping a
        // sourceless background run loop returns immediately and busy-spins.
        let tools = ToolHost.makeTools(
            launcher: AppLauncher(sleeper: { Thread.sleep(forTimeInterval: $0) })
        )
        let runner = TrolleyToolRunner(
            tools: tools,
            // The model's calls land in the same panel list as a server's, so what
            // trolley is doing reads the same whoever asked for it.
            observer: ActivityBridge.forwardingObserver,
            listApps: ToolHost.runningApps
        )
        let controller = StatusWidgetController(
            permissions: {
                (SystemTrustChecker().isProcessTrusted(), CGPreflightScreenCaptureAccess())
            },
            localLLM: LocalLLMSession(toolRunner: runner),
            // A verified download is a whole app bundle. Dropping it on the way
            // out costs a re-fetch that the next six-hour check would have made
            // anyway, and saves leaving hundreds of megabytes beside the install.
            onQuit: {
                updates?.discardStaged()
                NSApp.terminate(nil)
            },
            onOpenSettings: { openSetup() }
        )
        widget = controller
        // Before anything can be sent: `trolley prompt` fires and returns, so a listener
        // installed later would miss a prompt typed the moment the app came up.
        controller.acceptRemotePrompts()
        controller.show()

        startUpdateChecks(reporting: controller)

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

    /// Wires the update checker to the widget and starts its schedule.
    ///
    /// Only the app does this. `trolley mcp --widget` draws the same pet but must
    /// not replace the binary underneath a client that is mid-call, and the CLI
    /// has `trolley update` for the same job done deliberately.
    private static func startUpdateChecks(reporting controller: StatusWidgetController) {
        guard let current = SemanticVersion(TrolleyVersion.current) else { return }
        let layout = InstallLayout.detect(
            executablePath: AccessibilityPermission.currentExecutablePath()
        )
        let coordinator = UpdateCoordinator(current: current, layout: layout)
        coordinator.onChange = { status in controller.showUpdate(status: status) }
        controller.onUpdateAction = { installOrCheck(coordinator, reporting: controller) }
        updates = coordinator
        coordinator.start()
    }

    /// One button, two meanings, decided by what is actually in hand: install
    /// what has been fetched, or -- when nothing has -- go and look.
    private static func installOrCheck(
        _ coordinator: UpdateCoordinator, reporting controller: StatusWidgetController
    ) {
        do {
            guard try coordinator.installStaged() != nil else {
                coordinator.checkNow()
                return
            }
        } catch {
            controller.showUpdate(status: .failed(String(describing: error)))
            return
        }
        // The swap gave the path a new inode, so this process is still running
        // the old copy and cannot become the new one. Schedule the reopen, then
        // leave -- `open -a` while we are still alive would only activate us.
        if UpdatePolicy.default.relaunchesAutomatically {
            TrolleyRelaunch.scheduleRelaunch(bundlePath: coordinator.installedPath)
        }
        NSApp.terminate(nil)
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
