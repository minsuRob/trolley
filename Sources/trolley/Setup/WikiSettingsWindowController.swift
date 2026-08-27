import AppKit
import Foundation
import TrolleyKit
// For `WikiTools.mapFilter` -- the preview under 자동 has to be the list the tool
// actually returns, not a second guess at it kept in sync by hand.
import TrolleyMCP

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
    /// 끔 / 자동 / 직접 지정, as radio buttons rather than the single 위키 참고 checkbox
    /// they replaced. Three states cannot be a checkbox, and the middle one is the
    /// point: 자동 hands the filter below to trolley, which picks it per question.
    private let modeButtons: [(mode: WikiSettings.Mode, button: NSButton)]
    /// Says what 자동 means where the filter grid is, since that grid goes grey under it.
    private let modeNote = NSTextField(labelWithString: "")

    private let typePopup = NSPopUpButton()
    private let categoryPopup = NSPopUpButton()
    private let priorityPopup = NSPopUpButton()
    private let areaField = NSTextField()
    private let assigneePopup = NSPopUpButton()
    private let searchField = NSTextField()
    private let detailPopup = NSPopUpButton()
    private let sortPopup = NSPopUpButton()
    private let limitField = NSTextField()
    private let budgetField = NSTextField()
    private let folderCheckboxes: [(folder: String, button: NSButton)]
    private let statusCheckboxes: [(status: String, button: NSButton)]
    private let myWorkButton = NSButton(title: "내 일감", target: nil, action: nil)

    /// Handles offered by 담당, held so the menu can be rebuilt without a rebuild being
    /// visible as a flicker or a lost selection.
    private var knownAssignees: [String] = []
    /// What the stored filter had on the 담당 axis. A filter naming several people --
    /// which only the CLI can write -- cannot be shown by a single-select popup, so it
    /// is kept verbatim and handed back on save rather than silently widened to 전체.
    private var storedAssignees: Set<String> = []

    private let summaryLabel = NSTextField(labelWithString: "")
    private let previewText = NSTextView()
    private let previewScroll = NSScrollView()

    /// Held so `show()` can size the window to whatever the controls actually need.
    private let container = NSView()
    private let rootStack = NSStackView()

    /// The closed enums, from the vault's own `CLAUDE.md`. 영역 and 담당 are open sets:
    /// 영역 is free text, and 담당 is a popup filled from the snapshot at display time --
    /// hard-coding either would drop a new teammate out of the filter on the day they
    /// join.
    private static let types = ["일감", "개념", "데일리", "회의", "사람"]
    private static let statuses = ["진행중", "대기", "보류", "완료"]
    private static let categories = ["버그", "기능", "인프라", "기획", "UX"]
    private static let priorities = ["최우선", "중간", "하순위"]

    /// The two 담당 entries that are not handles. Named rather than typed twice, because
    /// `refreshAssigneeMenu` rebuilds the menu and `currentAssignees` reads it back by
    /// index -- the two have to agree about what sits above the separator.
    private static let allAssignees = "전체"
    private static let noAssignee = "미지정"

    /// `_private` is deliberately not here and cannot be switched on: the vault's rules
    /// exclude it from every index, and a rule that can be toggled eventually is.
    private static let offerableFolders = WikiIndex.indexableFolders + WikiIndex.optionalFolders

    /// Recomputing on every keystroke would walk the index per character.
    private var previewWorkItem: DispatchWorkItem?
    /// Set while controls are being populated, so filling them in does not read back as
    /// twelve edits and twelve previews.
    private var isPopulating = false

    /// Wide enough for the filter grid's two label+control pairs without squeezing
    /// 제목·요약에 포함된 말 down to a stub.
    private static let contentWidth: CGFloat = 560
    private static let minContentHeight: CGFloat = 520

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth, height: Self.minContentHeight),
            // Resizable because the preview is the point: giving it more room is the
            // one adjustment someone reading a 7,000-character digest actually wants.
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        modeButtons = WikiSettings.Mode.allCases.map {
            ($0, NSButton(radioButtonWithTitle: $0.title, target: nil, action: nil))
        }
        folderCheckboxes = Self.offerableFolders.map {
            ($0, NSButton(checkboxWithTitle: $0, target: nil, action: nil))
        }
        // Checkboxes rather than the popup this replaced, because the default is now two
        // statuses and a popup cannot say two. Same shape as `folderCheckboxes`, so the
        // read and the write are the same one-liner.
        statusCheckboxes = Self.statuses.map {
            ($0, NSButton(checkboxWithTitle: $0, target: nil, action: nil))
        }
        super.init()

        window.title = "LLM 위키"
        // Same reason as the setup window: an NSWindow releases itself on close by
        // default, which under ARC leaves this controller holding freed memory.
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = makeContentView()
        window.contentMinSize = NSSize(width: Self.contentWidth, height: Self.minContentHeight)
        sizeToFit()
        window.center()
    }

    var isVisible: Bool { window.isVisible }

    /// The laid-out view tree, so `WikiSettingsLayoutTests` can assert that no two
    /// controls sit on top of each other. Nothing in the app reads this.
    var contentViewForTesting: NSView { container }

    func show() {
        populate()
        refreshPreview()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The window opens at whatever the controls need rather than at a number typed
    /// into `contentRect`. A guessed height is how a control ends up off the bottom
    /// edge -- unreachable, but with nothing on screen saying so.
    private func sizeToFit() {
        container.layoutSubtreeIfNeeded()
        let height = max(rootStack.fittingSize.height, Self.minContentHeight)
        var frame = window.frameRect(
            forContentRect: NSRect(x: 0, y: 0, width: Self.contentWidth, height: height)
        )
        // NSWindow origins are bottom-left, so resizing without this drops the title
        // bar down the screen.
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: false, animate: false)
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

        for (_, button) in modeButtons {
            button.target = self
            button.action = #selector(modeChanged)
            button.controlSize = .small
        }
        // One superview and one action is what makes AppKit treat them as a group, so
        // picking one clears the others without any state kept here.
        let modeRow = NSStackView(views: modeButtons.map(\.button))
        modeRow.orientation = .horizontal
        modeRow.spacing = 12

        modeNote.font = .systemFont(ofSize: 10)
        modeNote.textColor = .secondaryLabelColor
        modeNote.lineBreakMode = .byTruncatingTail

        // Deliberately not an NSBox. `NSBox.contentView = someAutoLayoutView` does not
        // constrain what it is handed, so the options stack was left unpositioned and
        // drew upward out of the box across the heading and the path row -- every
        // filter control landed on top of something else and half of them could not be
        // clicked at all. A plain heading is also what 위키 폴더 and 미리보기 already use.
        let optionsView = makeOptionsView()

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
        previewScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 170).isActive = true
        // The one view that should absorb whatever height the window is dragged to.
        // Everything above it is a fixed-size control; stretching those would only
        // scatter them.
        previewScroll.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)

        let saveButton = NSButton(title: "저장", target: self, action: #selector(save))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        let cancelButton = NSButton(title: "취소", target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        let buttonRow = NSStackView(views: [NSView(), cancelButton, saveButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 10
        rootStack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 14, right: 18)
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        for view in [
            heading("위키 폴더"), pathRow, heading("참고 방식"), modeRow, modeNote,
            heading("상세 옵션"), optionsView,
            heading("미리보기"), summaryLabel, previewScroll, buttonRow
        ] {
            rootStack.addArrangedSubview(view)
        }

        container.addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: container.topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            pathRow.widthAnchor.constraint(equalTo: rootStack.widthAnchor, constant: -36),
            optionsView.widthAnchor.constraint(equalTo: rootStack.widthAnchor, constant: -36),
            previewScroll.widthAnchor.constraint(equalTo: rootStack.widthAnchor, constant: -36),
            buttonRow.widthAnchor.constraint(equalTo: rootStack.widthAnchor, constant: -36)
        ])
        return container
    }

    private func makeOptionsView() -> NSView {
        for (popup, values) in [
            (typePopup, Self.types),
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

        detailPopup.removeAllItems()
        detailPopup.addItems(withTitles: WikiFilter.Detail.allCases.map(\.title))

        // 전체 first for the same reason every other axis has it; 미지정 second because an
        // absent 담당 is a real selection and not the absence of one. Real handles are
        // appended by `refreshAssigneeMenu` from whatever the snapshot holds.
        assigneePopup.removeAllItems()
        assigneePopup.addItems(withTitles: [Self.allAssignees, Self.noAssignee])

        for popup in [sortPopup, detailPopup, assigneePopup] {
            popup.target = self
            popup.action = #selector(controlChanged)
            popup.controlSize = .small
        }

        for field in [areaField, searchField, limitField, budgetField] {
            field.controlSize = .small
            field.font = .systemFont(ofSize: 11)
            field.target = self
            field.action = #selector(controlChanged)
            field.delegate = self
        }
        areaField.placeholderString = "전체 (쉼표로 구분: web, be)"
        searchField.placeholderString = "제목·요약에 포함된 말"

        let folderRow = NSStackView(views: folderCheckboxes.map(\.button))
        folderRow.orientation = .horizontal
        folderRow.spacing = 10

        let statusRow = NSStackView(views: statusCheckboxes.map(\.button))
        statusRow.orientation = .horizontal
        statusRow.spacing = 10

        for (_, button) in folderCheckboxes + statusCheckboxes {
            button.target = self
            button.action = #selector(controlChanged)
            button.controlSize = .small
        }

        myWorkButton.target = self
        myWorkButton.action = #selector(applyMyWorkPreset)
        myWorkButton.bezelStyle = .rounded
        myWorkButton.controlSize = .small
        myWorkButton.toolTip = "담당=나 · 진행중·대기 · 제목만"

        let limitRow = NSStackView(views: [
            label("최대 건수"), limitField, label("문자 예산"), budgetField, myWorkButton
        ])
        limitRow.orientation = .horizontal
        limitRow.spacing = 6
        limitField.widthAnchor.constraint(equalToConstant: 54).isActive = true
        budgetField.widthAnchor.constraint(equalToConstant: 64).isActive = true

        let grid = NSGridView(views: [
            [label("유형"), typePopup, label("분류"), categoryPopup],
            [label("영역"), areaField, label("우선순위"), priorityPopup],
            [label("담당"), assigneePopup, label("정렬"), sortPopup],
            [label("검색"), searchField, label("상세"), detailPopup]
        ])
        grid.rowSpacing = 7
        grid.columnSpacing = 8
        grid.column(at: 1).width = 150
        grid.column(at: 3).width = 150
        // Without this the stack stretches the grid to the window's width and the
        // slack all lands in the 상태/우선순위/담당/정렬 label column, leaving each of
        // those labels stranded a hundred points from the control it names.
        grid.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [
            grid, label("상태"), statusRow, label("폴더"), folderRow, limitRow
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        // Indented under its heading rather than boxed -- see `makeContentView`.
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 10, bottom: 4, right: 0)
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
        let mode = WikiSettings.mode
        for (candidate, button) in modeButtons {
            button.state = candidate == mode ? .on : .off
        }
        applyMode(mode)

        let filter = WikiSettings.filter
        select(typePopup, filter.types)
        select(categoryPopup, filter.categories)
        select(priorityPopup, filter.priorities)
        areaField.stringValue = filter.areas.sorted().joined(separator: ", ")
        storedAssignees = filter.assignees
        // No snapshot here on purpose: `populate` runs from `show()`, and `refreshPreview`
        // is a line later with the real handles. Reading the vault to build a menu would
        // put a disk walk in front of a window that may be about to show an error.
        refreshAssigneeMenu(from: knownAssignees, selecting: filter.assignees)
        searchField.stringValue = filter.titleContains
        detailPopup.selectItem(at: WikiFilter.Detail.allCases.firstIndex(of: filter.detail) ?? 0)
        sortPopup.selectItem(at: WikiFilter.Sort.allCases.firstIndex(of: filter.sort) ?? 0)
        limitField.stringValue = String(filter.maxCount)
        budgetField.stringValue = String(WikiSettings.budgetCharacters)
        for (folder, button) in folderCheckboxes {
            button.state = filter.folders.contains(folder) ? .on : .off
        }
        for (status, button) in statusCheckboxes {
            button.state = filter.statuses.contains(status) ? .on : .off
        }
    }

    /// Rebuilds 담당 from the snapshot without losing the current pick.
    ///
    /// The union with `selection` is the part that matters. A handle that has left the
    /// vault -- or one the CLI wrote and no snapshot has shown yet -- still has to appear,
    /// because a selection that quietly falls off the menu is a filter that quietly widens
    /// the next time 저장 is pressed.
    private func refreshAssigneeMenu(from handles: [String], selecting selection: Set<String>) {
        let wasPopulating = isPopulating
        isPopulating = true
        defer { isPopulating = wasPopulating }

        let merged = Set(handles).union(selection)
            .filter { !$0.isEmpty }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        guard merged != knownAssignees || assigneePopup.numberOfItems < 2 else {
            selectAssignee(selection)
            return
        }
        knownAssignees = merged
        assigneePopup.removeAllItems()
        assigneePopup.addItems(withTitles: [Self.allAssignees, Self.noAssignee])
        if !merged.isEmpty {
            assigneePopup.menu?.addItem(.separator())
            assigneePopup.addItems(withTitles: merged)
        }
        selectAssignee(selection)
    }

    private func selectAssignee(_ selection: Set<String>) {
        if selection.isEmpty { assigneePopup.selectItem(at: 0); return }
        if selection == [""] { assigneePopup.selectItem(at: 1); return }
        if selection.count == 1, let only = selection.first,
           assigneePopup.itemTitles.contains(only) {
            assigneePopup.selectItem(withTitle: only)
            return
        }
        // Several people. The popup cannot say it, so it says 전체 and `currentAssignees`
        // hands the stored set back untouched instead of widening it on save.
        assigneePopup.selectItem(at: 0)
    }

    /// The closed-enum popups hold one value each, so a filter carrying several on that
    /// axis -- which the CLI can write -- shows as 전체 rather than silently picking one.
    /// 담당 has the same problem and its own version, `selectAssignee`, because its menu
    /// is built at runtime.
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
        filter.statuses = Set(statusCheckboxes.filter { $0.button.state == .on }.map(\.status))
        filter.categories = chosen(categoryPopup)
        filter.priorities = chosen(priorityPopup)
        filter.areas = tokens(areaField.stringValue)
        filter.assignees = currentAssignees()
        filter.titleContains = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        filter.detail = WikiFilter.Detail.allCases[max(0, detailPopup.indexOfSelectedItem)]
        filter.sort = WikiFilter.Sort.allCases[max(0, sortPopup.indexOfSelectedItem)]
        filter.maxCount = max(1, Int(limitField.stringValue) ?? filter.maxCount)
        filter.folders = Set(folderCheckboxes.filter { $0.button.state == .on }.map(\.folder))
        return filter
    }

    private func currentAssignees() -> Set<String> {
        switch assigneePopup.indexOfSelectedItem {
        case 0:
            // 전체 sitting on top of a multi-value stored filter means the popup could not
            // show what is set, not that anyone cleared it. Actually picking 전체 goes
            // through `controlChanged`, which clears `storedAssignees` first.
            return storedAssignees.count > 1 ? storedAssignees : []
        case 1:
            return [""]
        default:
            return assigneePopup.titleOfSelectedItem.map { [$0] } ?? []
        }
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

    private func currentMode() -> WikiSettings.Mode {
        modeButtons.first { $0.button.state == .on }?.mode ?? .off
    }

    /// Greys the filter grid for the two modes that do not read it.
    ///
    /// Disabled rather than hidden. The controls still hold what was set, and someone
    /// switching back to 직접 지정 has to find their filter where they left it -- a grid
    /// that vanishes and reappears reads as though the settings went with it. Greyed
    /// also answers the question the window would otherwise raise: under 자동 these
    /// values are not being ignored silently, they are visibly not in play.
    private func applyMode(_ mode: WikiSettings.Mode) {
        let editable = mode == .manual
        let controls: [NSControl] = [
            typePopup, categoryPopup, priorityPopup, areaField, assigneePopup,
            searchField, detailPopup, sortPopup, limitField, budgetField, myWorkButton
        ] + folderCheckboxes.map(\.button) + statusCheckboxes.map(\.button)
        for control in controls { control.isEnabled = editable }

        switch mode {
        case .off:
            modeNote.stringValue = "위키를 아예 보지 않습니다. 도구 목록에서도 빠집니다."
        case .auto:
            modeNote.stringValue =
                "질문 앞에 붙는 목록은 없습니다. trolley 가 질문을 읽고 필요한 조건을 직접 골라 찾습니다."
        case .manual:
            modeNote.stringValue = "아래 필터로 뽑은 목록이 대화의 첫 질문 앞에 함께 갑니다."
        }
    }

    @objc private func modeChanged() {
        applyMode(currentMode())
        controlChanged()
    }

    @objc private func controlChanged() {
        guard !isPopulating else { return }
        // A deliberate pick replaces whatever the CLI had written, 전체 included.
        storedAssignees = currentAssignees()
        schedulePreview()
    }

    /// 담당=나 · 진행중·대기 · 제목만, as one press.
    ///
    /// The handle comes from `WikiSettings.me`, then from whatever 담당 is currently set
    /// to, and if neither exists the preset applies the other two axes and leaves 담당
    /// alone. Honest degradation: a wrong guess here would file someone else's work under
    /// 내 일감, which is worse than a button that does two thirds of its job.
    @objc private func applyMyWorkPreset() {
        isPopulating = true
        let stored = WikiSettings.me
        let current = currentAssignees()
        let handle = !stored.isEmpty
            ? stored
            : (current.count == 1 ? (current.first ?? "") : "")
        if !handle.isEmpty {
            refreshAssigneeMenu(from: knownAssignees, selecting: [handle])
            storedAssignees = [handle]
        }
        for (status, button) in statusCheckboxes {
            button.state = (status == "진행중" || status == "대기") ? .on : .off
        }
        detailPopup.selectItem(at: WikiFilter.Detail.allCases.firstIndex(of: .titles) ?? 0)
        isPopulating = false
        // Not debounced. A button press is not a keystroke, and the whole point of the
        // preset is seeing the number drop.
        refreshPreview()
    }

    @objc private func save() {
        WikiSettings.rootPath = pathField.stringValue
        WikiSettings.mode = currentMode()
        WikiSettings.budgetCharacters = currentBudget()
        // Whoever you keep filtering to is who 내 일감 means. Learned from the pick rather
        // than asked for in a field of its own.
        let picked = currentAssignees()
        if picked.count == 1, let handle = picked.first, !handle.isEmpty {
            WikiSettings.me = handle
        }
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
        let mode = currentMode()
        // Under 자동 the grid below is not what trolley reads, so previewing it would show
        // a list nothing will ever send. What trolley does see, before it has narrowed
        // anything, is the unfiltered `wiki_search` -- so that is what goes in the box.
        let filter = mode == .auto
            ? WikiTools.mapFilter(folders: Set(Self.offerableFolders))
            : currentFilter()
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

        // The snapshot the preview already needed, reused. `WikiIndex` gates rewalks at
        // its revalidate interval, so this costs no extra disk.
        refreshAssigneeMenu(from: snapshot.pages.map(\.assignee), selecting: filter.assignees)

        let digest = WikiDigestRenderer.render(
            pages: snapshot.pages, filter: filter,
            rootName: root.lastPathComponent, budgetCharacters: budget
        )
        // The number this window exists to show: what the filter costs the model. 96,000
        // is the server's measured soft context limit, so the share of it is the honest
        // unit -- characters alone mean nothing to someone choosing a checkbox.
        let tokens = WikiDigestRenderer.approximateTokens(characters: digest.characters)
        var summary = "\(digest.matched)/\(digest.total)건 · \(digest.characters)자"
        switch mode {
        case .auto:
            // No budget line: nothing rides in front of the question under 자동, so the
            // share-of-budget number would be measuring a cost that is not paid. What is
            // paid is one tool result, and 4,000 characters is where that gets truncated.
            summary = "trolley 가 조건 없이 찾을 때 보는 목록 — " + summary
            summary += " · 도구 결과 한도의 \(Int((Double(digest.characters) / 4_000 * 100).rounded()))%"
        case .manual:
            summary += " · 예산의 \(Int((Double(digest.characters) / Double(budget) * 100).rounded()))%"
            summary += " · 96K 컨텍스트의 \(String(format: "%.1f", Double(tokens) / 960))%"
        case .off:
            summary = "끔 — 지금은 어디에도 쓰이지 않습니다 · " + summary
        }
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
