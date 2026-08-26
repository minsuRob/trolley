import AppKit
import Foundation
import TrolleyKit

/// The wiki's folder and its filters, with a running count of what they cost.
///
/// A window rather than the `NSAlert` + `accessoryView` sheet the rest of this folder
/// uses for editing a value. That idiom is right for one text field and wrong here for
/// three reasons: there are a dozen controls and a folder picker; the live preview *is*
/// the feature, and an alert re-laying out its accessory view on every control change
/// fights the framework; and this should stay open while someone edits the wiki in
/// Obsidian and presses 다시 읽기.
///
/// The preview is the point of the whole window. What is being managed here is how many
/// characters ride in front of every first question, and a filter UI that does not show
/// the number it is changing hides the one thing worth knowing.
final class WikiSettingsWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow

    private let pathField = NSTextField(labelWithString: "")
    private let enabledCheckbox = NSButton(checkboxWithTitle: "위키 참고", target: nil, action: nil)

    private let typePopup = NSPopUpButton()
    private let statusPopup = NSPopUpButton()
    private let categoryPopup = NSPopUpButton()
    private let priorityPopup = NSPopUpButton()
    private let areaField = NSTextField()
    private let assigneeField = NSTextField()
    private let searchField = NSTextField()
    private let summaryCheckbox = NSButton(checkboxWithTitle: "요약 포함", target: nil, action: nil)
    private let sortPopup = NSPopUpButton()
    private let limitField = NSTextField()
    private let budgetField = NSTextField()
    private let folderCheckboxes: [(folder: String, button: NSButton)]

    private let summaryLabel = NSTextField(labelWithString: "")
    private let previewText = NSTextView()
    private let previewScroll = NSScrollView()

    /// The closed enums, from the vault's own `CLAUDE.md`. 영역 and 담당 are open sets
    /// and are free text instead -- hard-coding them would drop a new teammate out of
    /// the filter on the day they join.
    private static let types = ["일감", "개념", "데일리", "회의", "사람"]
    private static let statuses = ["진행중", "대기", "보류", "완료"]
    private static let categories = ["버그", "기능", "인프라", "기획", "UX"]
    private static let priorities = ["최우선", "중간", "하순위"]

    /// `_private` is deliberately not here and cannot be switched on: the vault's rules
    /// exclude it from every index, and a rule that can be toggled eventually is.
    private static let offerableFolders = WikiIndex.indexableFolders + WikiIndex.optionalFolders

    /// Recomputing on every keystroke would walk the index per character.
    private var previewWorkItem: DispatchWorkItem?
    /// Set while controls are being populated, so filling them in does not read back as
    /// twelve edits and twelve previews.
    private var isPopulating = false

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        folderCheckboxes = Self.offerableFolders.map {
            ($0, NSButton(checkboxWithTitle: $0, target: nil, action: nil))
        }
        super.init()

        window.title = "LLM 위키"
        // Same reason as the setup window: an NSWindow releases itself on close by
        // default, which under ARC leaves this controller holding freed memory.
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.contentView = makeContentView()
    }

    var isVisible: Bool { window.isVisible }

    func show() {
        populate()
        refreshPreview()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        previewWorkItem?.cancel()
    }

    // MARK: - Layout

    private func makeContentView() -> NSView {
        pathField.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        pathField.textColor = .secondaryLabelColor
        pathField.lineBreakMode = .byTruncatingMiddle
        pathField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let chooseButton = NSButton(title: "폴더 선택…", target: self, action: #selector(chooseFolder))
        chooseButton.bezelStyle = .rounded
        chooseButton.controlSize = .small
        let reloadButton = NSButton(title: "다시 읽기", target: self, action: #selector(reload))
        reloadButton.bezelStyle = .rounded
        reloadButton.controlSize = .small

        let pathRow = NSStackView(views: [pathField, NSView(), chooseButton, reloadButton])
        pathRow.orientation = .horizontal
        pathRow.spacing = 8

        enabledCheckbox.target = self
        enabledCheckbox.action = #selector(controlChanged)
        summaryCheckbox.target = self
        summaryCheckbox.action = #selector(controlChanged)

        let optionsBox = NSBox()
        optionsBox.title = "상세 옵션"
        optionsBox.contentView = makeOptionsView()

        summaryLabel.font = .systemFont(ofSize: 11, weight: .medium)
        summaryLabel.textColor = .secondaryLabelColor

        previewText.isEditable = false
        previewText.isSelectable = true
        previewText.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        previewText.textContainerInset = NSSize(width: 6, height: 6)
        previewScroll.documentView = previewText
        previewScroll.hasVerticalScroller = true
        previewScroll.borderType = .bezelBorder
        previewScroll.translatesAutoresizingMaskIntoConstraints = false
        previewScroll.heightAnchor.constraint(equalToConstant: 170).isActive = true

        let saveButton = NSButton(title: "저장", target: self, action: #selector(save))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        let cancelButton = NSButton(title: "취소", target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        let buttonRow = NSStackView(views: [NSView(), cancelButton, saveButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let stack = NSStackView(views: [
            heading("위키 폴더"), pathRow, enabledCheckbox,
            optionsBox, heading("미리보기"), summaryLabel, previewScroll, buttonRow
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 14, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            pathRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            optionsBox.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            previewScroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36)
        ])
        return container
    }

    private func makeOptionsView() -> NSView {
        for (popup, values) in [
            (typePopup, Self.types), (statusPopup, Self.statuses),
            (categoryPopup, Self.categories), (priorityPopup, Self.priorities)
        ] {
            popup.removeAllItems()
            // "전체" first, because no constraint is the resting state of every axis.
            popup.addItem(withTitle: "전체")
            popup.addItems(withTitles: values)
            popup.target = self
            popup.action = #selector(controlChanged)
            popup.controlSize = .small
        }

        sortPopup.removeAllItems()
        sortPopup.addItems(withTitles: WikiFilter.Sort.allCases.map(\.title))
        sortPopup.target = self
        sortPopup.action = #selector(controlChanged)
        sortPopup.controlSize = .small

        for field in [areaField, assigneeField, searchField, limitField, budgetField] {
            field.controlSize = .small
            field.font = .systemFont(ofSize: 11)
            field.target = self
            field.action = #selector(controlChanged)
            field.delegate = self
        }
        areaField.placeholderString = "전체 (쉼표로 구분: web, be)"
        assigneeField.placeholderString = "전체 (쉼표로 구분, 미지정 가능)"
        searchField.placeholderString = "제목·요약에 포함된 말"

        let folderRow = NSStackView(views: folderCheckboxes.map(\.button))
        folderRow.orientation = .horizontal
        folderRow.spacing = 10
        for (_, button) in folderCheckboxes {
            button.target = self
            button.action = #selector(controlChanged)
            button.controlSize = .small
        }

        let limitRow = NSStackView(views: [
            label("최대 건수"), limitField, label("문자 예산"), budgetField, summaryCheckbox
        ])
        limitRow.orientation = .horizontal
        limitRow.spacing = 6
        limitField.widthAnchor.constraint(equalToConstant: 54).isActive = true
        budgetField.widthAnchor.constraint(equalToConstant: 64).isActive = true

        let grid = NSGridView(views: [
            [label("유형"), typePopup, label("상태"), statusPopup],
            [label("분류"), categoryPopup, label("우선순위"), priorityPopup],
            [label("영역"), areaField, label("담당"), assigneeField],
            [label("검색"), searchField, label("정렬"), sortPopup]
        ])
        grid.rowSpacing = 7
        grid.columnSpacing = 8
        grid.column(at: 1).width = 150
        grid.column(at: 3).width = 150

        let stack = NSStackView(views: [grid, label("폴더"), folderRow, limitRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        return stack
    }

    private func heading(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 12, weight: .semibold)
        return field
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        return field
    }

    // MARK: - Settings in, settings out

    private func populate() {
        isPopulating = true
        defer { isPopulating = false }

        pathField.stringValue = WikiSettings.rootPath
        enabledCheckbox.state = WikiSettings.isEnabled ? .on : .off

        let filter = WikiSettings.filter
        select(typePopup, filter.types)
        select(statusPopup, filter.statuses)
        select(categoryPopup, filter.categories)
        select(priorityPopup, filter.priorities)
        areaField.stringValue = filter.areas.sorted().joined(separator: ", ")
        assigneeField.stringValue = filter.assignees.sorted()
            .map { $0.isEmpty ? "미지정" : $0 }
            .joined(separator: ", ")
        searchField.stringValue = filter.titleContains
        summaryCheckbox.state = filter.includeSummary ? .on : .off
        sortPopup.selectItem(at: WikiFilter.Sort.allCases.firstIndex(of: filter.sort) ?? 0)
        limitField.stringValue = String(filter.maxCount)
        budgetField.stringValue = String(WikiSettings.budgetCharacters)
        for (folder, button) in folderCheckboxes {
            button.state = filter.folders.contains(folder) ? .on : .off
        }
    }

    /// The popups hold one value each, so a filter carrying several on that axis --
    /// which the CLI can write -- shows as 전체 rather than silently picking one.
    private func select(_ popup: NSPopUpButton, _ values: Set<String>) {
        guard values.count == 1, let only = values.first, popup.itemTitles.contains(only) else {
            popup.selectItem(at: 0)
            return
        }
        popup.selectItem(withTitle: only)
    }

    private func currentFilter() -> WikiFilter {
        var filter = WikiSettings.filter
        filter.types = chosen(typePopup)
        filter.statuses = chosen(statusPopup)
        filter.categories = chosen(categoryPopup)
        filter.priorities = chosen(priorityPopup)
        filter.areas = tokens(areaField.stringValue)
        filter.assignees = Set(tokens(assigneeField.stringValue).map { $0 == "미지정" ? "" : $0 })
        filter.titleContains = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        filter.includeSummary = summaryCheckbox.state == .on
        filter.sort = WikiFilter.Sort.allCases[max(0, sortPopup.indexOfSelectedItem)]
        filter.maxCount = max(1, Int(limitField.stringValue) ?? filter.maxCount)
        filter.folders = Set(folderCheckboxes.filter { $0.button.state == .on }.map(\.folder))
        return filter
    }

    private func chosen(_ popup: NSPopUpButton) -> Set<String> {
        guard popup.indexOfSelectedItem > 0, let title = popup.titleOfSelectedItem else { return [] }
        return [title]
    }

    private func tokens(_ raw: String) -> Set<String> {
        Set(
            raw.split(whereSeparator: { $0 == "," || $0 == "\n" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
    }

    private func currentBudget() -> Int {
        min(max(Int(budgetField.stringValue) ?? WikiSettings.budgetCharacters, 500), 20_000)
    }

    // MARK: - Actions

    /// The picker is the only way to set the folder from the GUI, and that is not a
    /// simplification. The vault lives under `~/Desktop`, which macOS gates even for an
    /// unsandboxed app; choosing it here is what records consent. A typed path would be
    /// accepted, look right, and read nothing.
    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "선택"
        panel.message = "markhub-llm-wiki 폴더를 고르세요."
        if let existing = WikiSettings.rootURL,
           FileManager.default.fileExists(atPath: existing.path) {
            panel.directoryURL = existing
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.pathField.stringValue = url.path
            WikiIndex.shared.invalidate()
            WikiContext.shared.invalidate()
            self.refreshPreview()
        }
    }

    @objc private func reload() {
        WikiIndex.shared.invalidate()
        WikiContext.shared.invalidate()
        refreshPreview()
    }

    @objc private func controlChanged() {
        guard !isPopulating else { return }
        schedulePreview()
    }

    @objc private func save() {
        WikiSettings.rootPath = pathField.stringValue
        WikiSettings.isEnabled = enabledCheckbox.state == .on
        WikiSettings.budgetCharacters = currentBudget()
        WikiSettings.filter = currentFilter()
        // Different filters are different content, so a conversation that already holds
        // the old list has to be handed the new one.
        WikiSettings.clearSent()
        WikiIndex.shared.invalidate()
        WikiContext.shared.invalidate()
        if let root = WikiSettings.rootURL { WikiIndex.shared.prewarm(root: root) }
        window.close()
    }

    @objc private func cancel() {
        window.close()
    }

    // MARK: - Preview

    private func schedulePreview() {
        previewWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshPreview() }
        previewWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func refreshPreview() {
        let path = NSString(string: pathField.stringValue).expandingTildeInPath
        guard !path.isEmpty else {
            show(summary: "폴더가 지정되지 않았습니다.", body: "")
            return
        }
        let root = URL(fileURLWithPath: path)
        let filter = currentFilter()
        let budget = currentBudget()

        let snapshot: WikiSnapshot
        do {
            snapshot = try WikiIndex.shared.snapshot(root: root, folders: walkTargets(for: filter))
        } catch let failure as WikiIndex.Failure {
            show(summary: describe(failure), body: "")
            return
        } catch {
            show(summary: "폴더를 읽지 못했습니다.", body: "")
            return
        }

        let digest = WikiDigestRenderer.render(
            pages: snapshot.pages, filter: filter,
            rootName: root.lastPathComponent, budgetCharacters: budget
        )
        // The number this window exists to show: what the filter costs the model. 96,000
        // is the server's measured soft context limit, so the share of it is the honest
        // unit -- characters alone mean nothing to someone choosing a checkbox.
        let tokens = Int(Double(digest.characters) / 2.2)
        var summary = "\(digest.matched)/\(digest.total)건 · \(digest.characters)자"
        summary += " · 예산의 \(Int((Double(digest.characters) / Double(budget) * 100).rounded()))%"
        summary += " · 96K 컨텍스트의 \(String(format: "%.1f", Double(tokens) / 960))%"
        if digest.wasTruncated {
            summary += "  ⚠︎ \(digest.total - digest.matched)건 생략"
        }
        if !snapshot.skipped.isEmpty {
            summary += "  ⚠︎ 읽지 못한 파일 \(snapshot.skipped.count)건"
        }
        show(summary: summary, body: digest.text)
    }

    private func walkTargets(for filter: WikiFilter) -> [String] {
        guard !filter.folders.isEmpty else { return WikiIndex.indexableFolders }
        return Self.offerableFolders.filter { candidate in
            filter.folders.contains { $0 == candidate || candidate.hasPrefix($0 + "/") }
        }
    }

    private func show(summary: String, body: String) {
        summaryLabel.stringValue = summary
        previewText.string = body
        previewText.scrollToBeginningOfDocument(nil)
    }

    private func describe(_ failure: WikiIndex.Failure) -> String {
        switch failure {
        case .noRoot: return "폴더가 지정되지 않았습니다."
        case .missing(let path): return "폴더를 찾을 수 없습니다 — \(path)"
        case .denied: return "폴더에 접근할 수 없습니다. 폴더 선택으로 다시 지정하면 권한이 붙습니다."
        }
    }
}

extension WikiSettingsWindowController: NSTextFieldDelegate {
    /// Typing in 영역/담당/검색 has to move the preview as it happens; waiting for ⏎
    /// would leave the number stale while someone is deciding what to type.
    func controlTextDidChange(_ notification: Notification) {
        controlChanged()
    }
}
