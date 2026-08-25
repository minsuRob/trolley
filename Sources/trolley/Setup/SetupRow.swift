import AppKit

/// One line of the setup window: a state dot, a title with an explanation, and
/// the single button that resolves it.
final class SetupRow: NSStackView {
    enum State {
        case done
        case actionNeeded
        case blocked

        var symbol: String {
            switch self {
            case .done: return "●"
            case .actionNeeded: return "●"
            case .blocked: return "●"
            }
        }

        var color: NSColor {
            switch self {
            case .done: return .systemGreen
            case .actionNeeded: return .systemOrange
            case .blocked: return .systemRed
            }
        }
    }

    private let dot = NSTextField(labelWithString: "●")
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let button = NSButton(title: "", target: nil, action: nil)
    private var onAction: (() -> Void)?

    init(title titleText: String) {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .top
        spacing = 10
        translatesAutoresizingMaskIntoConstraints = false

        dot.font = .systemFont(ofSize: 13)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.stringValue = titleText
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byWordWrapping
        detail.maximumNumberOfLines = 3
        detail.preferredMaxLayoutWidth = 300

        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        button.bezelStyle = .rounded
        button.controlSize = .small
        button.target = self
        button.action = #selector(fire)

        addArrangedSubview(dot)
        addArrangedSubview(text)
        addArrangedSubview(NSView())   // spacer keeps the button right-aligned
        addArrangedSubview(button)
        NSLayoutConstraint.activate([text.widthAnchor.constraint(equalToConstant: 300)])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(state: State, detail detailText: String, button buttonTitle: String?, action: (() -> Void)?) {
        dot.stringValue = state.symbol
        dot.textColor = state.color
        detail.stringValue = detailText
        onAction = action
        button.isHidden = buttonTitle == nil
        button.title = buttonTitle ?? ""
        button.isEnabled = action != nil
    }

    @objc private func fire() { onAction?() }
}
