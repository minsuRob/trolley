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

    public init(permissions: @escaping () -> (ax: Bool, screenRecording: Bool)) {
        self.permissions = permissions

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

        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in self?.persistOrigin() }
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
        panel.setFrameOrigin(restoredOrigin())
        panel.orderFrontRegardless()
        render(.idle)
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
            screenRecordingGranted: grants.screenRecording
        )
    }

    private func showMenu(for event: NSEvent) {
        let menu = NSMenu()
        let hide = NSMenuItem(title: "위젯 숨기기", action: #selector(hideWidget), keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)
        NSMenu.popUpContextMenu(menu, with: event, for: iconView)
    }

    @objc private func hideWidget() {
        activityPanel.hide()
        panel.orderOut(nil)
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
            let frame = NSRect(origin: candidate, size: panel.frame.size)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
                return candidate
            }
        }
        guard let screen = NSScreen.main else { return NSPoint(x: 100, y: 100) }
        let visible = screen.visibleFrame
        return NSPoint(
            x: visible.maxX - Self.widgetSize - 24,
            y: visible.minY + 24
        )
    }
}
