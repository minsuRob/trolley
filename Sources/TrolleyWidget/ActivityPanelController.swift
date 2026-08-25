import AppKit

/// Everything the activity panel renders, assembled by the widget controller.
struct ActivityPanelModel {
    let log: ActivityLog
    let uptime: TimeInterval
    let axGranted: Bool
    let screenRecordingGranted: Bool
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

/// The click-to-open panel: session stats, permission dots, and the most
/// recent tool calls. A child window of the widget panel, so it follows drags.
final class ActivityPanelController {
    private static let width: CGFloat = 360
    private static let inset: CGFloat = 12
    private static var contentWidth: CGFloat { width - inset * 2 }
    private static let maxRows = 8

    private let panel: NSPanel
    private let widgetPanel: NSPanel
    private let stack = NSStackView()

    // The panel refreshes on every tool call, so its chrome is built once and
    // only its text is updated -- rebuilding every view on each refresh was
    // what made the old panel jump around as rows came and went.
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

    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    init(attachedTo widgetPanel: NSPanel) {
        self.widgetPanel = widgetPanel

        panel = {
            final class NonKeyPanel: NSPanel {
                override var canBecomeKey: Bool { false }
                override var canBecomeMain: Bool { false }
            }
            return NonKeyPanel(
                contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 100),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
        }()
        panel.isFloatingPanel = true
        panel.level = .floating
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
            panel.orderFront(nil)
        }
    }

    func refreshIfVisible(_ model: ActivityPanelModel) {
        guard isVisible else { return }
        update(model)
        position()
    }

    func hide() {
        widgetPanel.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    // MARK: - Chrome

    private func buildChrome() {
        let title = Self.makeLabel(Style.title, .labelColor)
        title.stringValue = "trolley"
        stack.addArrangedSubview(headerRow(title, uptimeLabel))
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
    }

    private func permissionPair(_ dot: NSTextField, _ name: NSTextField) -> NSStackView {
        dot.stringValue = "●"
        let pair = NSStackView(views: [dot, name])
        pair.orientation = .horizontal
        pair.alignment = .firstBaseline
        pair.spacing = 4
        return pair
    }

    private func headerRow(_ leading: NSView, _ trailing: NSView) -> NSStackView {
        let row = NSStackView(views: [leading, trailing])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
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

    private static func makeLabel(_ font: NSFont, _ color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        return label
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
