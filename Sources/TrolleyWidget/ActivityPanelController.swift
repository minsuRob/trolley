import AppKit
import TrolleyKit
import TrolleyMCP

/// Where ⏎ in the prompt box sends what was typed.
///
/// Two destinations because they answer different questions. The local model is
/// there right now and replies in the panel; the agent queue only pays off while
/// an MCP client is actually attached and calling `take_prompt`. Defaulting to
/// the model is what makes the box useful with nothing else running.
public enum PromptDestination: String, CaseIterable {
    case localLLM
    case agent

    var title: String {
        switch self {
        case .localLLM: return "로컬 LLM"
        case .agent: return "에이전트"
        }
    }

    var hint: String {
        switch self {
        case .localLLM: return "엔터를 누르면 답이 여기에 나옵니다"
        case .agent: return "⏎ 로 대기열에 넣으면 에이전트가 take_prompt로 가져갑니다"
        }
    }

    static var stored: PromptDestination {
        get {
            let raw = UserDefaults.standard.string(forKey: LocalLLMSettings.destinationKey) ?? ""
            return PromptDestination(rawValue: raw) ?? .localLLM
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: LocalLLMSettings.destinationKey) }
    }
}

/// What the wiki is contributing to the next question, flattened for the hint line.
///
/// Nil when the wiki is off or has nothing to add. Present-but-`attaching == false`
/// means this conversation has already been given the list, which is the normal state
/// after the first question and worth saying so it does not read as a failure.
struct WikiBadge: Equatable {
    let matched: Int
    let attaching: Bool
    let isRefresh: Bool
    /// The wiki changed, but this conversation has had as many refreshes as it may get.
    let capped: Bool
}

/// The local model's side of the panel, flattened for rendering. A snapshot
/// rather than the session itself, so the panel cannot accidentally drive it.
struct LocalLLMSnapshot {
    let prompt: String
    /// The answer so far, or the denoising preview while none has arrived.
    let body: String
    let status: String
    let isBusy: Bool

    var hasContent: Bool { !prompt.isEmpty }

    static let empty = LocalLLMSnapshot(prompt: "", body: "", status: "", isBusy: false)
}

/// Everything the activity panel renders, assembled by the widget controller.
struct ActivityPanelModel {
    let log: ActivityLog
    let uptime: TimeInterval
    let axGranted: Bool
    let screenRecordingGranted: Bool
    let pendingPrompts: [PromptQueue.Prompt]
    let destination: PromptDestination
    let llm: LocalLLMSnapshot
    /// Whether anything can actually call `take_prompt`. False in the app, whose
    /// widget outlives every server: a server started while the app is up goes
    /// headless and does not advertise the tool at all. Without this the agent
    /// destination would queue into a box nobody opens.
    let agentReaderAvailable: Bool
    /// Only ever set for the local-model destination; the agent queue does not carry a
    /// preamble.
    let wiki: WikiBadge?
}

/// Fixed column widths for the call rows. The panel is a fixed width, so
/// placing the columns by hand is what puts every timestamp on the same left
/// edge and every duration on the same right edge -- a monospaced font alone
/// only aligns rows whose fields happen to be the same length.
private enum Column {
    static let time: CGFloat = 56
    static let mark: CGFloat = 12
    static let duration: CGFloat = 64
}

/// Text sizes and colors in one place, so the three sections stay on the same
/// visual grid as they gain rows.
private enum Style {
    static let title = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let body = NSFont.systemFont(ofSize: 11)
    static let mono = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    static let monoName = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let caption = NSFont.systemFont(ofSize: 10)
    static let dot = NSFont.systemFont(ofSize: 9)
}

/// The prompt box. Clicking it is the one moment the widget does take focus:
/// macOS routes hardware keystrokes to the *active* application, so a panel
/// that is key while the app stays inactive receives nothing -- what the user
/// types would go to whatever app is in front. Activating on the click is what
/// makes typing here work at all; `releaseFocus` hands the keyboard back as
/// soon as the prompt is committed or abandoned.
private final class PromptTextField: NSTextField {
    /// Same reason as the widget's own view: the panel belongs to an inactive
    /// app, so without this the click that should put the caret here is spent
    /// on activation instead.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        super.mouseDown(with: event)
        // Activation lands asynchronously. A field editor installed before the
        // app went active can end up without focus -- the click then looks like
        // it worked (the panel is up, the caret blinks nowhere) and the typing
        // goes to the app the user came from. Re-assert on the next turn.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            if window.firstResponder !== window.fieldEditor(false, for: self) {
                window.makeFirstResponder(self)
            }
        }
    }
}

/// Any button inside the panel.
///
/// The panel belongs to an inactive app, and without `acceptsFirstMouse` the
/// first click on one of these is spent activating rather than pressing -- the
/// same trap the prompt field and the widget's own view have to step around.
/// Every button here is one someone reaches for while working in another app,
/// so losing the first click is losing the click.
private final class PanelButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The click-to-open panel: session stats, permission dots, the most recent
/// tool calls, and a box for handing the agent a prompt. A child window of the
/// widget panel, so it follows drags.
final class ActivityPanelController: NSObject, NSTextFieldDelegate {
    private static let width: CGFloat = 360
    private static let inset: CGFloat = 12
    private static var contentWidth: CGFloat { width - inset * 2 }
    private static let maxRows = 8
    /// Enough to see the queue is real without letting it push the panel off
    /// screen; the count label carries the rest.
    private static let maxPendingRows = 3
    /// Past this the answer scrolls. Chosen so the panel still fits above the
    /// widget in its default bottom-right corner.
    private static let maxAnswerHeight: CGFloat = 150
    /// Enough turns to see where a thread went wrong without pushing the panel off the
    /// screen; `새 대화` is the answer to a thread longer than this.
    private static let maxTranscriptRows = 12

    /// The user committed a prompt. The widget controller owns both the queue
    /// and the model session, and decides which one gets it.
    var onSubmitPrompt: ((String) -> Void)?
    /// The destination switch moved.
    var onChangeDestination: ((PromptDestination) -> Void)?
    /// "중지" while the model is generating.
    var onCancelGeneration: (() -> Void)?
    /// ＋ beside the box: drop the thread and start clean.
    var onNewConversation: (() -> Void)?
    /// The transcript toggle asked for the current thread. Answers with condensed
    /// lines, or an error to print in place of them.
    var onLoadTranscript: ((@escaping (Result<[TranscriptRendering.Line], Error>) -> Void) -> Void)?
    /// Opens the setup window. Nil in a host that has none to offer -- a server
    /// drawing its own widget -- and the gear is then not shown at all rather
    /// than shown dead.
    var onOpenSettings: (() -> Void)? {
        didSet { settingsButton.isHidden = onOpenSettings == nil }
    }

    private let panel: NSPanel
    private let widgetPanel: NSPanel
    private let stack = NSStackView()

    // The panel refreshes on every tool call, so its chrome is built once and
    // only its text is updated. Rebuilding would throw away both the prompt the
    // user is halfway through typing and the field's first-responder status.
    private let uptimeLabel = ActivityPanelController.makeLabel(Style.mono, .secondaryLabelColor)
    private let statsLabel = ActivityPanelController.makeLabel(Style.body, .secondaryLabelColor)
    // Dot and name are separate labels rather than one attributed string: a
    // dynamic color inside an attributed string is resolved when the string is
    // built, which on the panel's HUD material came out almost invisible. A
    // label's own `textColor` is resolved at draw time, in the right appearance.
    private let axDot = ActivityPanelController.makeLabel(Style.dot, .systemGreen)
    private let axLabel = ActivityPanelController.makeLabel(Style.body, .secondaryLabelColor)
    private let screenDot = ActivityPanelController.makeLabel(Style.dot, .systemGreen)
    private let screenLabel = ActivityPanelController.makeLabel(Style.body, .secondaryLabelColor)
    private let callsStack = NSStackView()
    private let emptyLabel = ActivityPanelController.makeLabel(Style.body, .tertiaryLabelColor)
    private let pendingCountLabel = ActivityPanelController.makeLabel(Style.caption, .secondaryLabelColor)
    private let pendingStack = NSStackView()
    private let promptField = PromptTextField()
    private let newConversationButton = PanelButton()
    private let transcriptButton = PanelButton()
    private let transcriptStack = NSStackView()
    /// Closed until asked for. Kept here rather than read off `isHidden` so a refresh
    /// that runs while the fetch is in flight does not collapse it.
    private var isTranscriptOpen = false
    private let destinationControl = NSSegmentedControl()
    private let hintLabel = ActivityPanelController.makeLabel(Style.caption, .tertiaryLabelColor)
    private let answerSeparator = ActivityPanelController.makeSeparator()
    private let askedLabel = ActivityPanelController.makeLabel(Style.caption, .secondaryLabelColor)
    private let answerScroll = NSScrollView()
    private let answerText = NSTextView()
    private var answerHeight: NSLayoutConstraint!
    private let llmStatusLabel = ActivityPanelController.makeLabel(Style.caption, .secondaryLabelColor)
    private let stopButton = PanelButton()
    private let settingsButton = PanelButton()

    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    init(attachedTo widgetPanel: NSPanel) {
        self.widgetPanel = widgetPanel

        panel = {
            /// Key, unlike the widget itself: the prompt field needs keystrokes.
            /// `.nonactivatingPanel` plus `becomesKeyOnlyIfNeeded` keeps that
            /// narrow -- opening the panel, and clicking anywhere in it that is
            /// not the prompt field, leaves the app trolley is automating in
            /// front. Only `PromptTextField` takes focus, and gives it back.
            final class PromptablePanel: NSPanel {
                override var canBecomeKey: Bool { true }
                override var canBecomeMain: Bool { false }
            }
            return PromptablePanel(
                contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 100),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
        }()
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(
            top: 10, left: Self.inset, bottom: 10, right: Self.inset
        )
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            // Width is fixed, height follows the content. Without this the panel
            // would breathe sideways as tool names change length.
            stack.widthAnchor.constraint(equalToConstant: Self.width)
        ])
        panel.contentView = effect
        // Opening the panel must not put the caret in the prompt field: AppKit
        // would otherwise adopt it as the initial first responder and the panel
        // would open holding the keyboard, which is exactly what the widget
        // promises never to do.
        panel.initialFirstResponder = nil

        super.init()
        buildChrome()
    }

    var isVisible: Bool { panel.isVisible }

    func toggle(_ model: ActivityPanelModel) {
        if isVisible {
            hide()
        } else {
            update(model)
            position()
            widgetPanel.addChildWindow(panel, ordered: .above)
            // Not makeKey: the panel opens without focus, and only the prompt
            // field takes it, when clicked.
            panel.orderFront(nil)
            panel.makeFirstResponder(nil)
        }
    }

    /// Open, and stay open. `toggle` is wrong for a menu command -- picking
    /// "물어보기" twice would close the panel the second time, which reads as the
    /// menu being broken.
    func present(_ model: ActivityPanelModel) {
        update(model)
        guard !isVisible else { return }
        position()
        widgetPanel.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
    }

    /// Puts the caret in the prompt box.
    ///
    /// `becomesKeyOnlyIfNeeded` is the flag that makes this panel refuse key
    /// status, which is what keeps it from stealing focus from the app trolley is
    /// automating. It also makes a programmatic `makeKeyAndOrderFront` unreliable,
    /// so it comes off for the length of this call and goes straight back on.
    func focusPromptField() {
        let restore = panel.becomesKeyOnlyIfNeeded
        panel.becomesKeyOnlyIfNeeded = false
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(promptField)
        // Activation lands asynchronously, and AppKit re-picks the key window when
        // it does -- the same race `PromptTextField.mouseDown` has to step around.
        // A field editor installed before that finishes ends up holding nothing,
        // and the typing goes to the app the user came from.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible else { return }
            if self.panel.firstResponder !== self.panel.fieldEditor(false, for: self.promptField) {
                self.panel.makeFirstResponder(self.promptField)
            }
            self.panel.becomesKeyOnlyIfNeeded = restore
        }
    }

    func refreshIfVisible(_ model: ActivityPanelModel) {
        guard isVisible else { return }
        update(model)
        position()
    }

    @objc private func closePanel() {
        hide()
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    func hide() {
        releaseFocus()
        widgetPanel.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// Undoes what clicking the prompt field did: drop the caret, then let the
    /// app the user was actually working in come back to the front.
    private func releaseFocus() {
        panel.makeFirstResponder(nil)
        if NSApp.isActive {
            NSApp.deactivate()
        }
    }

    // MARK: - Chrome

    private func buildChrome() {
        let title = Self.makeLabel(Style.title, .labelColor)
        title.stringValue = "trolley"

        let close = PanelButton()
        close.isBordered = false
        close.bezelStyle = .inline
        close.imagePosition = .imageOnly
        close.image = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: "패널 닫기"
        )
        close.contentTintColor = .tertiaryLabelColor
        close.toolTip = "닫기"
        close.target = self
        close.action = #selector(closePanel)
        close.setContentHuggingPriority(.required, for: .horizontal)

        settingsButton.isBordered = false
        settingsButton.bezelStyle = .inline
        settingsButton.imagePosition = .imageOnly
        settingsButton.image = NSImage(
            systemSymbolName: "gearshape.fill",
            accessibilityDescription: "설정 열기"
        )
        settingsButton.contentTintColor = .tertiaryLabelColor
        settingsButton.toolTip = "설정 열기"
        settingsButton.target = self
        settingsButton.action = #selector(openSettings)
        settingsButton.setContentHuggingPriority(.required, for: .horizontal)
        // Until a host assigns the callback there is nothing behind it.
        settingsButton.isHidden = true

        // Top left, ahead of the title: where a window's close button lives. The
        // gear sits beside it because the pet's right-click menu was the only
        // way in, and a menu you have to know about is not a way in.
        let leading = NSStackView(views: [close, settingsButton, title])
        leading.orientation = .horizontal
        leading.alignment = .centerY
        leading.spacing = 6

        stack.addArrangedSubview(headerRow(leading, uptimeLabel, alignment: .centerY))
        stack.addArrangedSubview(statsLabel)

        axLabel.stringValue = "AX"
        screenLabel.stringValue = "화면 기록"
        let permissions = NSStackView(views: [
            permissionPair(axDot, axLabel), permissionPair(screenDot, screenLabel)
        ])
        permissions.orientation = .horizontal
        permissions.alignment = .firstBaseline
        permissions.spacing = 14
        stack.addArrangedSubview(permissions)

        stack.addArrangedSubview(Self.makeSeparator())

        callsStack.orientation = .vertical
        callsStack.alignment = .leading
        callsStack.spacing = 2
        stack.addArrangedSubview(callsStack)
        emptyLabel.stringValue = "아직 툴 호출이 없습니다"
        stack.addArrangedSubview(emptyLabel)

        stack.addArrangedSubview(Self.makeSeparator())

        let promptTitle = Self.makeLabel(Style.body, .labelColor)
        promptTitle.stringValue = "프롬프트"
        stack.addArrangedSubview(headerRow(promptTitle, pendingCountLabel))

        destinationControl.segmentCount = PromptDestination.allCases.count
        destinationControl.segmentStyle = .rounded
        destinationControl.controlSize = .small
        destinationControl.trackingMode = .selectOne
        for (index, destination) in PromptDestination.allCases.enumerated() {
            destinationControl.setLabel(destination.title, forSegment: index)
            destinationControl.setWidth(Self.contentWidth / 2, forSegment: index)
        }
        // Hidden until a model says otherwise. `NSStackView` detaches hidden
        // arranged subviews, so this costs no height in the app -- and starting
        // hidden means the switch never flashes on during the first refresh.
        destinationControl.isHidden = true
        destinationControl.target = self
        destinationControl.action = #selector(destinationChanged)
        stack.addArrangedSubview(destinationControl)

        pendingStack.orientation = .vertical
        pendingStack.alignment = .leading
        pendingStack.spacing = 2
        stack.addArrangedSubview(pendingStack)

        promptField.font = Style.body
        promptField.bezelStyle = .roundedBezel
        promptField.isBezeled = true
        promptField.focusRingType = .default
        promptField.delegate = self
        promptField.target = self
        promptField.action = #selector(promptCommitted)
        // Committing only on ⏎ -- clicking away from a half-typed prompt must
        // not send it.
        promptField.cell?.sendsActionOnEndEditing = false
        // The box no longer spans the panel: the two things someone reaches for while
        // looking at an answer -- start over, see the whole thread -- belong next to it,
        // not buried in the setup window.
        Self.configureIconButton(
            newConversationButton, symbol: "plus.bubble", fallback: "＋",
            tooltip: "새 대화 — 지금까지의 맥락을 버리고 새로 시작합니다"
        )
        newConversationButton.target = self
        newConversationButton.action = #selector(newConversationClicked)

        Self.configureIconButton(
            transcriptButton, symbol: "text.bubble", fallback: "⋯",
            tooltip: "전체 대화 보기"
        )
        transcriptButton.target = self
        transcriptButton.action = #selector(toggleTranscript)

        let promptRow = NSStackView(views: [
            promptField, newConversationButton, transcriptButton
        ])
        promptRow.orientation = .horizontal
        promptRow.alignment = .centerY
        promptRow.spacing = 4
        stack.addArrangedSubview(promptRow)
        promptRow.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        // Only the field absorbs the leftover width; the buttons keep their size.
        for button in [newConversationButton, transcriptButton] {
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        buildTranscriptBlock()

        hintLabel.lineBreakMode = .byWordWrapping
        hintLabel.preferredMaxLayoutWidth = Self.contentWidth
        hintLabel.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        stack.addArrangedSubview(hintLabel)

        buildAnswerBlock()
    }

    /// The model's reply, under the field rather than above it: a growing answer
    /// must not push the box someone is typing into out from under the caret.
    private func buildAnswerBlock() {
        stack.addArrangedSubview(answerSeparator)

        askedLabel.stringValue = ""
        stack.addArrangedSubview(askedLabel)
        askedLabel.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true

        answerText.isEditable = false
        // Selectable so an answer can be copied out; the panel is not a place to
        // keep anything.
        answerText.isSelectable = true
        answerText.drawsBackground = false
        answerText.font = Style.body
        answerText.textColor = .labelColor
        answerText.textContainerInset = NSSize(width: 0, height: 2)
        answerText.isVerticallyResizable = true
        answerText.isHorizontallyResizable = false
        answerText.textContainer?.widthTracksTextView = true
        answerText.textContainer?.containerSize = NSSize(
            width: Self.contentWidth, height: .greatestFiniteMagnitude
        )
        answerScroll.documentView = answerText
        answerScroll.drawsBackground = false
        answerScroll.borderType = .noBorder
        answerScroll.hasVerticalScroller = true
        answerScroll.autohidesScrollers = true
        answerScroll.translatesAutoresizingMaskIntoConstraints = false
        answerHeight = answerScroll.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            answerScroll.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            answerHeight
        ])
        stack.addArrangedSubview(answerScroll)

        stopButton.isBordered = false
        stopButton.bezelStyle = .inline
        stopButton.title = "중지"
        stopButton.font = Style.caption
        stopButton.contentTintColor = .secondaryLabelColor
        stopButton.target = self
        stopButton.action = #selector(cancelGeneration)
        stopButton.setContentHuggingPriority(.required, for: .horizontal)
        stack.addArrangedSubview(headerRow(llmStatusLabel, stopButton, alignment: .centerY))
    }

    /// A square borderless icon button, sized to sit flush with the prompt field.
    ///
    /// SF Symbols with a text fallback: the symbols used here have shipped since
    /// Big Sur, but a missing glyph would render as an empty square with a working
    /// click target, which is worse than a plain character.
    private static func configureIconButton(
        _ button: NSButton, symbol: String, fallback: String, tooltip: String
    ) {
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) {
            button.image = image
            button.imagePosition = .imageOnly
        } else {
            button.title = fallback
            button.font = Style.body
        }
        button.isBordered = false
        button.bezelStyle = .inline
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tooltip
        button.widthAnchor.constraint(equalToConstant: 22).isActive = true
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    /// The whole thread, collapsed to one line per message and closed by default.
    ///
    /// A plain stack in the panel's own column, like `callsStack` and `pendingStack`
    /// above it -- not a scroll view. Two attempts at scrolling this cost a day: first a
    /// wrapper `NSView` that kept `translatesAutoresizingMaskIntoConstraints` and
    /// collapsed to nothing, then an `NSScrollView` whose layout, the moment the
    /// transcript became visible, killed the rest of `setTranscript` -- probed statement
    /// by statement, with no crash, no hang and nothing in the unified log.
    ///
    /// The panel already knows how to be a list. Capping the rows is what scrolling was
    /// for, and a cap is what the other two sections use.
    private func buildTranscriptBlock() {
        transcriptStack.orientation = .vertical
        transcriptStack.alignment = .leading
        transcriptStack.spacing = 3
        transcriptStack.isHidden = true
        stack.addArrangedSubview(transcriptStack)
    }

    @objc private func newConversationClicked() {
        // Deferred for the same reason as `toggleTranscript` -- see there. This one has
        // survived on luck: it only tears rows down, and an empty transcript lays nothing
        // out. It stops being luck the moment it is pressed with the transcript open.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Closed as well: what it is showing is the thread that was just abandoned.
            self.setTranscript(open: false)
            self.onNewConversation?()
        }
    }

    @objc private func toggleTranscript() {
        // Deferred to the next run loop turn, and that is not a style choice -- it is a
        // deadlock fix, found by sampling a frozen app:
        //
        //   main thread:  -[NSTextField setFrameSize:] → -[NSViewHierarchyLock
        //                 _lockForWriting:] → _pthread_cond_wait          (blocked)
        //   HIE thread:   servicing the accessibility request that delivered this click
        //
        // A click that arrives through the accessibility API is dispatched while the
        // accessibility server thread still holds the view hierarchy lock. Building rows
        // here means laying out new `NSTextField`s inside that window, so the main thread
        // asks for the write lock and waits for a thread that is waiting for it. The app
        // does not crash and does not log; it simply stops redrawing, which is exactly
        // what "the button does nothing" looked like from the outside for a day.
        //
        // `새 대화` escaped it by accident: with the transcript closed it has no text
        // fields to lay out, so it never asks for the lock.
        DispatchQueue.main.async { [weak self] in self?.performTranscriptToggle() }
    }

    private func performTranscriptToggle() {
        setTranscript(open: !isTranscriptOpen)
        guard isTranscriptOpen else { return }
        showTranscript(rows: [transcriptRow(.init(kind: .scaffolding, text: "불러오는 중…"))])
        onLoadTranscript? { [weak self] result in
            guard let self, self.isTranscriptOpen else { return }
            switch result {
            case .success(let lines) where lines.isEmpty:
                self.showTranscript(rows: [
                    self.transcriptRow(.init(kind: .scaffolding, text: "아직 주고받은 말이 없습니다"))
                ])
            case .success(let lines):
                self.showTranscript(rows: lines.map(self.transcriptRow))
            case .failure(let error):
                self.showTranscript(rows: [
                    self.transcriptRow(.init(kind: .scaffolding, text: error.localizedDescription))
                ])
            }
        }
    }

    private func setTranscript(open: Bool) {
        isTranscriptOpen = open
        transcriptStack.isHidden = !open
        transcriptButton.contentTintColor = open ? .controlAccentColor : .secondaryLabelColor
        // The label says what pressing it will do next.
        let title = open ? "전체 대화 닫기" : "전체 대화 보기"
        transcriptButton.toolTip = title
        transcriptButton.setAccessibilityLabel(title)
        if !open { replaceRows(of: transcriptStack, with: []) }
        resizeToFit()
    }

    /// Newest last, capped. The tail is the part someone opened this to read -- when a
    /// thread has run long, the question that is bothering them is the recent one.
    private func showTranscript(rows: [NSView]) {
        replaceRows(of: transcriptStack, with: Array(rows.suffix(Self.maxTranscriptRows)))
        resizeToFit()
    }

    private func transcriptRow(_ line: TranscriptRendering.Line) -> NSView {
        let label: NSTextField
        switch line.kind {
        case .question:
            label = Self.makeLabel(Style.body, .labelColor)
            label.stringValue = "묻기: \(line.text)"
        case .answer:
            label = Self.makeLabel(Style.body, .secondaryLabelColor)
            label.stringValue = line.text
        case .tool:
            label = Self.makeLabel(Style.mono, .tertiaryLabelColor)
            label.stringValue = line.text
        case .scaffolding:
            label = Self.makeLabel(Style.caption, .tertiaryLabelColor)
            label.stringValue = line.text
        }
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 3
        label.preferredMaxLayoutWidth = Self.contentWidth
        label.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        return label
    }

    private func permissionPair(_ dot: NSTextField, _ name: NSTextField) -> NSStackView {
        dot.stringValue = "●"
        let pair = NSStackView(views: [dot, name])
        pair.orientation = .horizontal
        pair.alignment = .firstBaseline
        pair.spacing = 4
        return pair
    }

    /// - Parameter alignment: baseline keeps two labels sitting on one line;
    ///   a row carrying the close button needs its centres matched instead,
    ///   since an image has no baseline to share.
    private func headerRow(
        _ leading: NSView,
        _ trailing: NSView,
        alignment: NSLayoutConstraint.Attribute = .firstBaseline
    ) -> NSStackView {
        let row = NSStackView(views: [leading, trailing])
        row.orientation = .horizontal
        row.alignment = alignment
        row.distribution = .fill
        leading.setContentHuggingPriority(.defaultLow, for: .horizontal)
        trailing.setContentHuggingPriority(.required, for: .horizontal)
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
        row.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        return row
    }

    private static func makeSeparator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        return box
    }

    // MARK: - Content

    private func update(_ model: ActivityPanelModel) {
        uptimeLabel.stringValue = "up " + PanelFormat.uptime(model.uptime)
        statsLabel.stringValue = PanelFormat.stats(
            calls: model.log.totalCalls, errors: model.log.errorCount
        )
        axDot.textColor = model.axGranted ? .systemGreen : .systemRed
        screenDot.textColor = model.screenRecordingGranted ? .systemGreen : .systemRed

        replaceRows(of: callsStack, with: model.log.entries.prefix(Self.maxRows).map(callRow))
        emptyLabel.isHidden = !model.log.entries.isEmpty

        updatePromptSection(model)

        resizeToFit()
    }

    /// Grows the panel to whatever the stack now needs.
    ///
    /// Split out of `refresh` because it was trapped there, and that was the whole bug
    /// behind a transcript that would not appear: the toggle set its height constraint
    /// and nothing resized the window, so the block laid out correctly at full height
    /// *outside* the panel's content rect and was clipped away. Every symptom pointed at
    /// the button not firing -- it was firing the entire time.
    ///
    /// Anything that changes the stack's height outside a model refresh has to call this.
    private func resizeToFit() {
        stack.layoutSubtreeIfNeeded()
        panel.setContentSize(NSSize(width: Self.width, height: stack.fittingSize.height))
    }

    /// One of the two destinations is showing at a time: the agent queue, or the
    /// model's reply. Showing both would double the panel's height for one line
    /// of information that only ever applies to the half in use.
    private func updatePromptSection(_ model: ActivityPanelModel) {
        let section = PromptSectionState(model: model)
        destinationControl.isHidden = !section.showsDestinationControl
        destinationControl.selectedSegment = section.selectedSegment
        hintLabel.stringValue = section.hint
        hintLabel.textColor = section.hintIsWarning ? .systemOrange : .tertiaryLabelColor
        hintLabel.maximumNumberOfLines = 2
        promptField.placeholderString = section.placeholder

        let agentMode = section.destination == .agent
        let pending = model.pendingPrompts

        pendingCountLabel.isHidden = !agentMode
        pendingCountLabel.stringValue = pending.isEmpty ? "대기 없음" : "대기 \(pending.count)건"
        replaceRows(
            of: pendingStack,
            with: agentMode ? pending.prefix(Self.maxPendingRows).map(pendingRow) : []
        )

        let llm = model.llm
        let showAnswer = section.showsAnswerBlock
        answerSeparator.isHidden = !showAnswer
        askedLabel.isHidden = !showAnswer
        answerScroll.isHidden = !showAnswer
        llmStatusLabel.isHidden = !showAnswer
        llmStatusLabel.superview?.isHidden = !showAnswer
        stopButton.isHidden = !section.showsStopButton

        guard showAnswer else {
            answerHeight.constant = 0
            return
        }
        askedLabel.stringValue = "묻기: " + llm.prompt.replacingOccurrences(of: "\n", with: " ")
        llmStatusLabel.stringValue = llm.status
        setAnswer(llm.body, streaming: llm.isBusy)
    }

    /// Replaces the text only when it actually changed: assigning `string` on
    /// every refresh would drop a selection the user had made in a finished
    /// answer, and the panel refreshes on every tool call.
    private func setAnswer(_ text: String, streaming: Bool) {
        if answerText.string != MarkdownRendering.plainText(text) {
            // The source is markdown and the reader is a person. Set through the text
            // storage rather than `string`, which would drop every attribute.
            answerText.textStorage?.setAttributedString(MarkdownRendering.attributed(text))
            if streaming {
                // Follow the tail while it is being written; a finished answer is
                // left where the reader put it.
                answerText.scrollToEndOfDocument(nil)
            }
        }
        answerText.layoutManager?.ensureLayout(for: answerText.textContainer!)
        let used = answerText.layoutManager?.usedRect(for: answerText.textContainer!).height ?? 0
        // A floor so the box does not flicker into existence one line at a time,
        // and a ceiling so a long answer scrolls instead of running off screen.
        answerHeight.constant = min(max(used + 6, 34), Self.maxAnswerHeight)
    }

    private func replaceRows(of container: NSStackView, with rows: [NSView]) {
        container.arrangedSubviews.forEach { view in
            container.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        rows.forEach(container.addArrangedSubview)
        container.isHidden = rows.isEmpty
    }

    private func callRow(_ entry: ActivityLog.Entry) -> NSView {
        let time = Self.makeLabel(Style.mono, .secondaryLabelColor)
        time.stringValue = timeFormatter.string(from: entry.finishedAt)

        let mark = Self.makeLabel(Style.mono, entry.isError ? .systemRed : .systemGreen)
        mark.stringValue = entry.isError ? "✗" : "✓"
        mark.alignment = .center

        let name = Self.makeLabel(Style.monoName, entry.isError ? .systemRed : .labelColor)
        name.stringValue = entry.name

        let duration = Self.makeLabel(Style.mono, .secondaryLabelColor)
        duration.stringValue = PanelFormat.duration(entry.duration)
        duration.alignment = .right

        let row = NSStackView(views: [time, mark, name, duration])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.distribution = .fill
        row.spacing = 8
        // Only the name flexes; the other three are the column grid.
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            time.widthAnchor.constraint(equalToConstant: Column.time),
            mark.widthAnchor.constraint(equalToConstant: Column.mark),
            duration.widthAnchor.constraint(equalToConstant: Column.duration),
            row.widthAnchor.constraint(equalToConstant: Self.contentWidth)
        ])
        return row
    }

    private func pendingRow(_ prompt: PromptQueue.Prompt) -> NSView {
        let label = Self.makeLabel(Style.caption, .secondaryLabelColor)
        // Newlines would make one prompt eat several rows' worth of height.
        label.stringValue = "• " + prompt.text.replacingOccurrences(of: "\n", with: " ")
        label.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        return label
    }

    private static func makeLabel(_ font: NSFont, _ color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        return label
    }

    // MARK: - Prompt box

    /// ⏎ means "take it from here", so the keyboard goes back to whatever the
    /// user was doing rather than staying parked in the widget.
    @objc private func promptCommitted() {
        let text = promptField.stringValue
        promptField.stringValue = ""
        releaseFocus()
        onSubmitPrompt?(text)
    }

    @objc private func destinationChanged() {
        let index = destinationControl.selectedSegment
        guard PromptDestination.allCases.indices.contains(index) else { return }
        onChangeDestination?(PromptDestination.allCases[index])
    }

    @objc private func cancelGeneration() {
        onCancelGeneration?()
    }

    /// Escape gives the field back: clear a half-typed prompt, then close.
    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        promptField.stringValue = ""
        hide()
        return true
    }

    // MARK: - Placement

    /// Above the widget when there's room, below otherwise; kept on-screen
    /// horizontally.
    private func position() {
        let widget = widgetPanel.frame
        let size = panel.frame.size
        guard let screen = widgetPanel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame

        var x = widget.midX - size.width / 2
        x = max(visible.minX + 8, min(x, visible.maxX - size.width - 8))
        let above = widget.maxY + 8
        let y = above + size.height <= visible.maxY ? above : widget.minY - size.height - 8
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// The panel's number formatting, kept free of AppKit so the awkward cases
/// (an hour of uptime, a sub-millisecond call) are testable.
enum PanelFormat {
    /// The hint under the prompt box.
    ///
    /// Pure so the combinations are testable: the orphan-queue warning has to win over
    /// everything, the agent destination never mentions the wiki because its prompts do
    /// not carry one, and "already sent" has to read as normal rather than as a fault.
    static func promptHint(
        destination: PromptDestination, wiki: WikiBadge?, orphanQueue: Bool
    ) -> String {
        if orphanQueue {
            return "가져갈 서버가 없습니다 — trolley.app 을 끄고 trolley mcp 로 띄워야 take_prompt 가 열립니다"
        }
        guard destination == .localLLM, let wiki else { return destination.hint }
        if wiki.capped {
            return destination.hint + " · 위키가 바뀌었습니다 (새 대화부터 반영)"
        }
        if wiki.attaching {
            return destination.hint + (wiki.isRefresh
                ? " · 위키 \(wiki.matched)건 다시 첨부"
                : " · 위키 \(wiki.matched)건 첨부")
        }
        return destination.hint + " · 위키 \(wiki.matched)건 (이미 전달됨)"
    }

    static func uptime(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let (hours, minutes, seconds) = (total / 3600, (total % 3600) / 60, total % 60)
        // Hours only once there are any -- "00:14:02" reads as a stopwatch, and
        // a session that old is the exception.
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }

    static func stats(calls: Int, errors: Int) -> String {
        "호출 \(calls) · 실패 \(errors)"
    }

    static func duration(_ interval: TimeInterval) -> String {
        let millis = interval * 1000
        // Anything that took a second is better read in seconds than as a
        // five-digit millisecond count.
        if millis >= 1000 {
            return String(format: "%.1f s", interval)
        }
        // Sub-millisecond calls exist (a rejected argument never touches AX);
        // "0 ms" would read as a broken timer.
        if millis > 0 && millis < 1 {
            return "<1 ms"
        }
        return String(format: "%.0f ms", millis)
    }
}
