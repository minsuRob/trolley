import AppKit
import TrolleyMCP

/// A floating panel that must never take keyboard focus away from the app
/// trolley is automating.
private final class WidgetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The content view: draws the folder, distinguishes click from drag, and
/// forwards both to the controller.
private final class WidgetContentView: FolderIconView {
    var onClick: (() -> Void)?
    var onRightClick: ((NSEvent) -> Void)?
    private var originAtMouseDown: NSPoint?

    /// trolley is almost never the active app -- it is a companion to whatever
    /// the user is working in. Without this, the first click on the widget is
    /// swallowed as an activation click and the panel only opens on the second.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        originAtMouseDown = window?.frame.origin
        // Not calling super lets isMovableByWindowBackground handle the drag.
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if let before = originAtMouseDown, let after = window?.frame.origin,
           abs(before.x - after.x) < 1, abs(before.y - after.y) < 1 {
            onClick?()
        }
        originAtMouseDown = nil
        super.mouseUp(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(event)
    }
}

/// The "folder pet": an always-on-top companion showing what trolley is doing.
///
/// Main-thread only. The `observer` property bridges from the MCP thread by
/// hopping every event onto the main queue before touching any of this.
public final class StatusWidgetController {
    private static let originDefaultsKey = "trolley.widget.origin"
    private static let widgetSize: CGFloat = 72
    private static let badgeDisplaySeconds: TimeInterval = 2.5

    private let panel: WidgetPanel
    private let iconView: WidgetContentView
    private let activityPanel: ActivityPanelController
    private var machine = WidgetStateMachine()
    private var log = ActivityLog()
    private var badgeTimer: DispatchWorkItem?
    private let sessionStartedAt = Date()
    private let permissions: () -> (ax: Bool, screenRecording: Bool)
    private let promptQueue: PromptQueue
    private let onQuit: () -> Void

    /// - Parameter promptQueue: shared with the tool provider -- the panel's
    ///   prompt box is the writer, `take_prompt` the reader.
    /// - Parameter onQuit: what "위젯 종료" does. Injected so this module never
    ///   decides how the process dies -- `trolley mcp` exits the same way it does
    ///   on stdin EOF.
    public init(
        permissions: @escaping () -> (ax: Bool, screenRecording: Bool),
        promptQueue: PromptQueue = PromptQueue(),
        onQuit: @escaping () -> Void = { NSApplication.shared.terminate(nil) }
    ) {
        self.permissions = permissions
        self.promptQueue = promptQueue
        self.onQuit = onQuit

        let size = Self.widgetSize
        panel = WidgetPanel(
            contentRect: NSRect(x: 0, y: 0, width: size, height: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false

        iconView = WidgetContentView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        panel.contentView = iconView
        activityPanel = ActivityPanelController(attachedTo: panel)

        iconView.onClick = { [weak self] in self?.toggleActivityPanel() }
        iconView.onRightClick = { [weak self] event in self?.showMenu(for: event) }
        activityPanel.onSubmitPrompt = { [weak self] text in
            self?.submitPrompt(text)
        }
        // The agent drains from the MCP thread; without this the panel would go
        // on listing prompts that have already been collected.
        promptQueue.onChange = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.activityPanel.refreshIfVisible(self.makePanelModel())
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in self?.persistOrigin() }

        // Unplugging a display can leave the widget parked on coordinates no
        // screen covers any more. Nothing else can bring it back -- there is no
        // Dock icon and no menu bar item -- so re-assert it here.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.reassertVisibility() }
    }

    /// The bridge handed to `MCPServer`. Fires on the MCP thread.
    public var observer: ToolCallObserver {
        ToolCallObserver(
            toolCallStarted: { name in
                DispatchQueue.main.async { self.apply(.started(tool: name)) }
            },
            toolCallFinished: { name, isError, duration in
                let finishedAt = Date()
                DispatchQueue.main.async {
                    self.log.record(ActivityLog.Entry(
                        name: name, finishedAt: finishedAt, isError: isError, duration: duration
                    ))
                    self.apply(.finished(isError: isError))
                }
            }
        )
    }

    public func show() {
        installEditMenu()
        panel.setFrameOrigin(restoredOrigin())
        panel.orderFrontRegardless()
        render(.idle)
    }

    /// An accessory app shows no menu bar, but the main menu is still what
    /// routes ⌘X/⌘C/⌘V/⌘A to the first responder. Without one, the prompt box
    /// silently refuses every paste -- which is how most people put a long
    /// prompt, or any Korean text an IME already committed elsewhere, into it.
    private func installEditMenu() {
        guard NSApp.mainMenu == nil else { return }
        let edit = NSMenu(title: "Edit")
        for (title, selector, key) in [
            ("Undo", "undo:", "z"), ("Redo", "redo:", "Z"),
            ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
            ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")
        ] {
            edit.addItem(withTitle: title, action: Selector((selector)), keyEquivalent: key)
        }
        let editItem = NSMenuItem()
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    // MARK: - State

    private func apply(_ event: WidgetEvent) {
        badgeTimer?.cancel()
        badgeTimer = nil
        let state = machine.handle(event)

        if case .badge = state {
            let timer = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.render(self.machine.handle(.badgeTimedOut))
            }
            badgeTimer = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.badgeDisplaySeconds, execute: timer)
        }
        render(state)
        activityPanel.refreshIfVisible(makePanelModel())
    }

    private func render(_ state: WidgetState) {
        switch state {
        case .idle:
            stopWorkingAnimation()
            hideBadge(animated: true)
            iconView.toolTip = "trolley — idle"
        case .working(let tool):
            hideBadge(animated: false)
            startWorkingAnimation()
            iconView.toolTip = "trolley — running \(tool)…"
        case .badge(let success):
            stopWorkingAnimation()
            showBadge(success: success)
            iconView.toolTip = success ? "trolley — done" : "trolley — last call failed"
        }
    }

    // MARK: - Animations

    private func startWorkingAnimation() {
        guard let layer = iconView.layer else { return }
        if layer.animation(forKey: "bob") == nil {
            let bob = CABasicAnimation(keyPath: "transform.translation.y")
            bob.fromValue = -3
            bob.toValue = 3
            bob.duration = 0.6
            bob.autoreverses = true
            bob.repeatCount = .infinity
            bob.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(bob, forKey: "bob")
        }
        iconView.spinnerLayer.opacity = 1
        if iconView.spinnerLayer.animation(forKey: "spin") == nil {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = 2 * Double.pi
            spin.duration = 1.2
            spin.repeatCount = .infinity
            iconView.spinnerLayer.add(spin, forKey: "spin")
        }
    }

    private func stopWorkingAnimation() {
        iconView.layer?.removeAnimation(forKey: "bob")
        iconView.spinnerLayer.removeAnimation(forKey: "spin")
        iconView.spinnerLayer.opacity = 0
    }

    private func showBadge(success: Bool) {
        let badge = iconView.badgeLayer
        badge.string = success ? "✅" : "❌"
        badge.opacity = 1
        let pop = CASpringAnimation(keyPath: "transform.scale")
        pop.fromValue = 0.4
        pop.toValue = 1.0
        pop.damping = 12
        pop.initialVelocity = 8
        pop.duration = pop.settlingDuration
        badge.add(pop, forKey: "pop")
    }

    private func hideBadge(animated: Bool) {
        let badge = iconView.badgeLayer
        guard badge.opacity > 0 else { return }
        if animated {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = 0.3
            badge.add(fade, forKey: "fade")
        }
        badge.opacity = 0
    }

    // MARK: - Click / menu

    private func toggleActivityPanel() {
        activityPanel.toggle(makePanelModel())
    }

    private func makePanelModel() -> ActivityPanelModel {
        let grants = permissions()
        return ActivityPanelModel(
            log: log,
            uptime: Date().timeIntervalSince(sessionStartedAt),
            axGranted: grants.ax,
            screenRecordingGranted: grants.screenRecording,
            pendingPrompts: promptQueue.pendingPrompts
        )
    }

    /// Whitespace-only text is dropped by the queue, which is what makes a
    /// stray ⏎ a no-op rather than a blank instruction to the agent.
    private func submitPrompt(_ text: String) {
        promptQueue.submit(text)
    }

    /// Quitting is the only way to make the widget go away. Hiding used to live
    /// here and was a trap: it left the server running with no UI surface at all,
    /// so the process could only be found with `ps`.
    private func showMenu(for event: NSEvent) {
        let menu = NSMenu()

        // Names the process the quit item kills, and gives the PID to anyone who
        // would rather reach for `kill`.
        let info = NSMenuItem(title: "trolley mcp — PID \(getpid())", action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "위젯 종료", action: #selector(quitWidget), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)

        NSMenu.popUpContextMenu(menu, with: event, for: iconView)
    }

    @objc private func quitWidget() {
        activityPanel.hide()
        panel.orderOut(nil)
        onQuit()
    }

    // MARK: - Position persistence

    private func persistOrigin() {
        let origin = panel.frame.origin
        UserDefaults.standard.set([Double(origin.x), Double(origin.y)], forKey: Self.originDefaultsKey)
    }

    private func restoredOrigin() -> NSPoint {
        if let stored = UserDefaults.standard.array(forKey: Self.originDefaultsKey) as? [Double],
           stored.count == 2 {
            let candidate = NSPoint(x: stored[0], y: stored[1])
            if isOnVisibleScreen(NSRect(origin: candidate, size: panel.frame.size)) {
                return candidate
            }
        }
        return defaultOrigin()
    }

    /// Pulls the widget back onto a screen that still exists and re-orders it to
    /// the front. Cheap enough to run on every screen-parameter change.
    private func reassertVisibility() {
        if !isOnVisibleScreen(panel.frame) {
            panel.setFrameOrigin(defaultOrigin())
        }
        panel.orderFrontRegardless()
    }

    private func isOnVisibleScreen(_ frame: NSRect) -> Bool {
        NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
    }

    private func defaultOrigin() -> NSPoint {
        guard let screen = NSScreen.main else { return NSPoint(x: 100, y: 100) }
        let visible = screen.visibleFrame
        return NSPoint(
            x: visible.maxX - Self.widgetSize - 24,
            y: visible.minY + 24
        )
    }
}
