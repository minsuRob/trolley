import AppKit
import TrolleyKit
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

/// The update affordance drawn over the pet.
///
/// Circular and centred rather than tucked into a corner: the pet is 72pt and
/// already carries a status badge top-right and a spinner low-centre, so the
/// middle is the only place left that reads as "this is about the whole thing"
/// rather than "this is about the last tool call".
private final class UpdateBadgeButton: NSButton {
    /// The pet belongs to an inactive app. Without this the first click is spent
    /// activating and the badge looks broken -- the same trap the pet's own view
    /// and every panel button step around.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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
    private let localLLM: LocalLLMSession
    private var cachedWikiBadge: WikiBadge?
    private var lastWikiBadgeCheck: Date?
    /// One-shot observer for `presentPromptPanel(focus:)`; see there.
    private var activationObserver: NSObjectProtocol?
    /// Held for the life of the controller: `PromptBridge` is how `trolley prompt`
    /// reaches the one process whose Accessibility grant actually works.
    private var promptBridgeObserver: NSObjectProtocol?
    /// The `trolley prompt` call waiting on the current question, if any. Cleared as
    /// soon as it is answered so a later question typed into the box does not report
    /// back to a CLI that has long since exited.
    private var pendingRequestID: String?
    private let onQuit: () -> Void
    private let onOpenSettings: (() -> Void)?
    /// Hidden until an update is actually installable; see `showUpdate`.
    private let updateBadge = UpdateBadgeButton()
    /// What the badge and the panel's button both call. The widget knows nothing
    /// about feeds -- it reports that a person asked and lets the app decide.
    public var onUpdateAction: (() -> Void)? {
        didSet { activityPanel.onUpdateAction = onUpdateAction }
    }

    /// - Parameter onQuit: what "위젯 종료" does. Injected so this module never
    ///   decides how the process dies.
    /// - Parameter onOpenSettings: shown in the menu when the host has a setup
    ///   window to offer. Omitted by a server that only draws the widget.
    /// - Parameter localLLM: the model side of the same box. Injected so tests
    ///   and the CLI can hand in one that talks to nothing.
    public init(
        permissions: @escaping () -> (ax: Bool, screenRecording: Bool),
        localLLM: LocalLLMSession = LocalLLMSession(),
        onQuit: @escaping () -> Void = { NSApplication.shared.terminate(nil) },
        onOpenSettings: (() -> Void)? = nil
    ) {
        self.permissions = permissions
        self.localLLM = localLLM
        self.onQuit = onQuit
        self.onOpenSettings = onOpenSettings

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

        buildUpdateBadge()
        iconView.onClick = { [weak self] in self?.toggleActivityPanel() }
        iconView.onRightClick = { [weak self] event in self?.showMenu(for: event) }
        activityPanel.onSubmitPrompt = { [weak self] text in
            self?.submitPrompt(text)
        }
        activityPanel.onCancelGeneration = { [weak self] in
            self?.localLLM.cancel()
        }
        // Same action as the pet's menu item, in the place someone looks first.
        // Assigned only when the host has a window, which is what decides
        // whether the gear appears.
        if onOpenSettings != nil {
            activityPanel.onOpenSettings = { [weak self] in self?.onOpenSettings?() }
        }
        activityPanel.onNewConversation = { [weak self] in
            guard let self else { return }
            self.localLLM.startNewConversation()
            // The queue is the other destination's memory and is not part of the thread;
            // clearing it here would throw away prompts the agent has not collected.
            self.activityPanel.refreshIfVisible(self.makePanelModel())
        }
        activityPanel.onLoadTranscript = { [weak self] completion in
            self?.localLLM.loadTranscript(completion: completion)
        }
        // Tokens arrive one at a time on the main queue; each one is a repaint.
        localLLM.onChange = { [weak self] in
            guard let self else { return }
            self.activityPanel.refreshIfVisible(self.makePanelModel())
            self.reportIfSettled()
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

    /// The bridge handed to the tool runner. Fires off the main thread.
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

    /// Activity that happened in another process -- see `ActivityBridge`. Same
    /// path as the in-process observer, so a forwarded call animates exactly like
    /// a local one.
    public func record(started tool: String) {
        apply(.started(tool: tool))
    }

    public func record(finished tool: String, isError: Bool, duration: TimeInterval) {
        log.record(ActivityLog.Entry(
            name: tool, finishedAt: Date(), isError: isError, duration: duration
        ))
        apply(.finished(isError: isError))
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

    /// Open the prompt box from outside the widget -- the menu bar's "물어보기",
    /// and the setup window's "지금 물어보기".
    ///
    /// - Parameter focus: put the caret in the box. True when the user asked for
    ///   this in so many words; false when something else opened it on their
    ///   behalf, where taking the keyboard would be an interruption.
    public func presentPromptPanel(focus: Bool) {
        activityPanel.present(makePanelModel())
        guard focus else { return }
        if NSApp.isActive {
            activityPanel.focusPromptField()
            return
        }
        // Order matters: activate first, then take focus once the app is actually
        // active. Doing it the other way round loses the caret, because becoming
        // active makes AppKit re-decide which window is key. Clicking a status item
        // does not activate the owning app, so this is the usual path.
        // Held in a property rather than a local so the observer can remove itself:
        // this fires once per request, and a second 물어보기 while the first is
        // still pending must not stack another.
        if let pending = activationObserver {
            NotificationCenter.default.removeObserver(pending)
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if let pending = self.activationObserver {
                NotificationCenter.default.removeObserver(pending)
                self.activationObserver = nil
            }
            self.activityPanel.focusPromptField()
        }
        NSApp.activate()
    }

    private func makePanelModel() -> ActivityPanelModel {
        let grants = permissions()
        return ActivityPanelModel(
            log: log,
            uptime: Date().timeIntervalSince(sessionStartedAt),
            axGranted: grants.ax,
            screenRecordingGranted: grants.screenRecording,
            llm: LocalLLMSnapshot(
                prompt: localLLM.prompt,
                // The denoising preview stands in until the first real token, so
                // the box is never blank while the model is visibly working.
                // `visibleAnswer`, never `answer`: mid-loop the latter is the tool-call
                // JSON, and this is the one surface that belongs to the person asking.
                body: localLLM.visibleAnswer.isEmpty ? localLLM.draft : localLLM.visibleAnswer,
                status: LocalLLMSession.statusLine(for: localLLM.phase, backend: localLLM.backend),
                isBusy: localLLM.isBusy
            ),
            wiki: wikiBadge()
        )
    }

    /// What the wiki will contribute to the next question.
    ///
    /// Read from the same settings and index the send path uses, so the hint cannot
    /// claim one thing while the request carries another. Nil whenever the wiki is off
    /// or has nothing to say, which keeps the line unchanged for anyone not using it.
    ///
    /// Gated at 5 seconds like the setup window's rows, and for a sharper reason: this
    /// is called from `makePanelModel`, which runs on **every arriving token**. Ungated
    /// it would walk the wiki on the main thread throughout a streaming answer. The
    /// digest itself only moves when a filter or a file does, so a stale-by-seconds
    /// count is the right trade.
    private func wikiBadge() -> WikiBadge? {
        if let last = lastWikiBadgeCheck, Date().timeIntervalSince(last) < 5 {
            return cachedWikiBadge
        }
        lastWikiBadgeCheck = Date()
        cachedWikiBadge = computeWikiBadge()
        return cachedWikiBadge
    }

    private func computeWikiBadge() -> WikiBadge? {
        guard WikiSettings.isEnabled, let digest = WikiContext.shared.currentDigest(),
              !digest.isEmpty
        else { return nil }
        let conversationID = LocalLLMSettings.conversationID
        let sent = WikiSettings.sent
        let alreadyToldThisOne = sent?.conversationID == conversationID
        let isSameContent = alreadyToldThisOne && sent?.digestHash == digest.hash
        return WikiBadge(
            matched: digest.matched,
            attaching: !isSameContent && !WikiContext.shared.isRefreshCapped(conversationID: conversationID),
            isRefresh: alreadyToldThisOne && !isSameContent,
            capped: !isSameContent && WikiContext.shared.isRefreshCapped(conversationID: conversationID)
        )
    }

    private func buildUpdateBadge() {
        let diameter: CGFloat = 34
        updateBadge.frame = NSRect(
            x: (Self.widgetSize - diameter) / 2,
            y: (Self.widgetSize - diameter) / 2,
            width: diameter,
            height: diameter
        )
        updateBadge.isBordered = false
        updateBadge.bezelStyle = .inline
        updateBadge.imagePosition = .imageOnly
        updateBadge.image = NSImage(
            systemSymbolName: "arrow.down.circle.fill",
            accessibilityDescription: "업데이트 설치"
        )
        updateBadge.image?.isTemplate = false
        updateBadge.contentTintColor = .controlAccentColor
        updateBadge.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 30, weight: .semibold)
        updateBadge.target = self
        updateBadge.action = #selector(updateBadgeTapped)
        updateBadge.isHidden = true
        iconView.addSubview(updateBadge)
    }

    @objc private func updateBadgeTapped() {
        onUpdateAction?()
    }

    /// Shows the update state in both places the user might be looking.
    ///
    /// The badge appears only for a finished download. An update that is merely
    /// *known about* is not yet actionable -- covering the pet with a button that
    /// means "wait" would take the face away and give nothing back.
    public func showUpdate(status: UpdateStatus) {
        updateBadge.isHidden = !status.deservesAttention
        updateBadge.toolTip = status.summary
        activityPanel.showUpdate(status: status)
        activityPanel.refreshIfVisible(makePanelModel())
    }

    /// Starts listening for prompts sent by `trolley prompt`.
    ///
    /// Only the app calls this. A prompt arriving here is put through `submitPrompt`,
    /// the same function the ⏎ key calls, so there is exactly one path a question can
    /// take and no chance of the two drifting apart.
    public func acceptRemotePrompts() {
        promptBridgeObserver = PromptBridge.observeSubmissions { [weak self] text, requestID in
            guard let self else { return }
            self.pendingRequestID = requestID.isEmpty ? nil : requestID
            // Shown, not just run: a prompt that arrives from a terminal should leave
            // the same visible trace as one that was typed, or the tool calls happen
            // with nothing on screen accounting for them.
            self.presentPromptPanel(focus: false)
            self.submitPrompt(text)
        }
    }

    /// Reports the finished exchange back to a waiting `trolley prompt`.
    ///
    /// Driven off `onChange` rather than a completion handler because the loop has no
    /// single end: it settles into `.done`, `.failed` or `.cancelled` after some number
    /// of tool steps, and those are the three phases worth reporting.
    private func reportIfSettled() {
        guard let requestID = pendingRequestID else { return }
        switch localLLM.phase {
        case .done:
            pendingRequestID = nil
            PromptBridge.answer(requestID: requestID, answer: localLLM.answer, isError: false)
        case .failed(let message):
            pendingRequestID = nil
            PromptBridge.answer(requestID: requestID, answer: message, isError: true)
        case .cancelled:
            pendingRequestID = nil
            PromptBridge.answer(requestID: requestID, answer: "중지됨", isError: true)
        case .idle:
            // `clear()` reached us with a question still outstanding -- 새 대화 was
            // pressed, or the panel was reset, while a `trolley prompt` was waiting.
            // Measured: without this the caller sits until its timeout for an answer
            // that was thrown away before it could exist.
            pendingRequestID = nil
            PromptBridge.answer(
                requestID: requestID, answer: "대화가 초기화되었습니다", isError: true
            )
        case .queued, .generating, .acting:
            break
        }
    }

    /// Whitespace-only text is dropped by the session, which is what makes a stray ⏎
    /// a no-op rather than a blank instruction.
    private func submitPrompt(_ text: String) {
        localLLM.send(text)
    }

    /// Quitting is the only way to make the widget go away. Hiding used to live
    /// here and was a trap: it left the server running with no UI surface at all,
    /// so the process could only be found with `ps`.
    private func showMenu(for event: NSEvent) {
        let menu = NSMenu()

        // Names the process the quit item kills, and gives the PID to anyone who
        // would rather reach for `kill`.
        let info = NSMenuItem(title: "trolley — PID \(getpid())", action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        menu.addItem(.separator())

        if onOpenSettings != nil {
            let settings = NSMenuItem(title: "설정 열기", action: #selector(openSettings), keyEquivalent: "")
            settings.target = self
            menu.addItem(settings)
        }

        let quit = NSMenuItem(title: "위젯 종료", action: #selector(quitWidget), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)

        NSMenu.popUpContextMenu(menu, with: event, for: iconView)
    }

    @objc private func openSettings() {
        onOpenSettings?()
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
