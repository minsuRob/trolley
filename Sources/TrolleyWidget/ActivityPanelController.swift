import AppKit

/// Everything the activity panel renders, assembled by the widget controller.
struct ActivityPanelModel {
    let log: ActivityLog
    let uptime: TimeInterval
    let axGranted: Bool
    let screenRecordingGranted: Bool
}

/// The click-to-open panel: session stats, permission dots, and the most
/// recent tool calls. A child window of the widget panel, so it follows drags.
final class ActivityPanelController {
    private static let width: CGFloat = 320
    private static let maxRows = 8

    private let panel: NSPanel
    private let widgetPanel: NSPanel
    private let stack = NSStackView()

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
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor)
        ])
        panel.contentView = effect
    }

    var isVisible: Bool { panel.isVisible }

    func toggle(_ model: ActivityPanelModel) {
        if isVisible {
            hide()
        } else {
            rebuild(model)
            position()
            widgetPanel.addChildWindow(panel, ordered: .above)
            panel.orderFront(nil)
        }
    }

    func refreshIfVisible(_ model: ActivityPanelModel) {
        guard isVisible else { return }
        rebuild(model)
        position()
    }

    func hide() {
        widgetPanel.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    // MARK: - Content

    private func rebuild(_ model: ActivityPanelModel) {
        stack.arrangedSubviews.forEach { view in
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let uptime = Self.formatUptime(model.uptime)
        addLabel(
            "trolley  ·  \(model.log.totalCalls) calls  ·  \(model.log.errorCount) errors  ·  up \(uptime)",
            color: .labelColor, bold: true
        )
        addLabel(
            "AX \(model.axGranted ? "✓" : "✗")   Screen Recording \(model.screenRecordingGranted ? "✓" : "✗")",
            color: .secondaryLabelColor
        )

        if !model.log.entries.isEmpty {
            addSeparator()
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            for entry in model.log.entries.prefix(Self.maxRows) {
                let mark = entry.isError ? "✗" : "✓"
                let duration = String(format: "%5dms", Int(entry.duration * 1000))
                let name = entry.name.padding(toLength: 16, withPad: " ", startingAt: 0)
                addLabel(
                    "\(formatter.string(from: entry.finishedAt))  \(mark) \(name) \(duration)",
                    color: entry.isError ? .systemRed : .labelColor
                )
            }
        } else {
            addLabel("아직 툴 호출이 없습니다", color: .tertiaryLabelColor)
        }

        panel.setContentSize(stack.fittingSize)
    }

    private func addLabel(_ text: String, color: NSColor, bold: Bool = false) {
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedSystemFont(ofSize: 11, weight: bold ? .semibold : .regular)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(label)
    }

    private func addSeparator() {
        let box = NSBox()
        box.boxType = .separator
        stack.addArrangedSubview(box)
        box.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
    }

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

    private static func formatUptime(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
