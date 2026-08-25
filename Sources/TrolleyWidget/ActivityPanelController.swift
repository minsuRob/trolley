import AppKit
import TrolleyMCP

/// Everything the activity panel renders, assembled by the widget controller.
struct ActivityPanelModel {
    let log: ActivityLog
    let uptime: TimeInterval
    let axGranted: Bool
    let screenRecordingGranted: Bool
    let pendingPrompts: [PromptQueue.Prompt]
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

/// The panel's own close button.
///
/// Clicking the folder again already closes the panel, but that is invisible
/// until someone tries it. This is the same action with a target to aim at.
private final class PanelCloseButton: NSButton {
    /// The panel belongs to an inactive app, and without this the first click on
    /// it is spent activating rather than pressing -- the same trap the prompt
    /// field and the widget's own view have to step around.
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

    /// The user committed a prompt. The widget controller owns the queue.
    var onSubmitPrompt: ((String) -> Void)?

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

    func refreshIfVisible(_ model: ActivityPanelModel) {
        guard isVisible else { return }
        update(model)
        position()
    }

    @objc private func closePanel() {
        hide()
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

        let close = PanelCloseButton()
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

        // Top left, ahead of the title: where a window's close button lives.
        let leading = NSStackView(views: [close, title])
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

        stack.addArrangedSubview(separator())

        callsStack.orientation = .vertical
        callsStack.alignment = .leading
        callsStack.spacing = 2
        stack.addArrangedSubview(callsStack)
        emptyLabel.stringValue = "아직 툴 호출이 없습니다"
        stack.addArrangedSubview(emptyLabel)

        stack.addArrangedSubview(separator())

        let promptTitle = Self.makeLabel(Style.body, .labelColor)
        promptTitle.stringValue = "프롬프트"
        stack.addArrangedSubview(headerRow(promptTitle, pendingCountLabel))

        pendingStack.orientation = .vertical
        pendingStack.alignment = .leading
        pendingStack.spacing = 2
        stack.addArrangedSubview(pendingStack)

        promptField.font = Style.body
        promptField.placeholderString = "에이전트에게 전할 말…"
        promptField.bezelStyle = .roundedBezel
        promptField.isBezeled = true
        promptField.focusRingType = .default
        promptField.delegate = self
        promptField.target = self
        promptField.action = #selector(promptCommitted)
        // Committing only on ⏎ -- clicking away from a half-typed prompt must
        // not queue it.
        promptField.cell?.sendsActionOnEndEditing = false
        stack.addArrangedSubview(promptField)
        promptField.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true

        let hint = Self.makeLabel(Style.caption, .tertiaryLabelColor)
        hint.stringValue = "⏎ 로 대기열에 넣으면 에이전트가 take_prompt로 가져갑니다"
        stack.addArrangedSubview(hint)
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

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
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

        let pending = model.pendingPrompts
        pendingCountLabel.stringValue = pending.isEmpty ? "대기 없음" : "대기 \(pending.count)건"
        replaceRows(
            of: pendingStack,
            with: pending.prefix(Self.maxPendingRows).map(pendingRow)
        )

        panel.setContentSize(NSSize(width: Self.width, height: stack.fittingSize.height))
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
