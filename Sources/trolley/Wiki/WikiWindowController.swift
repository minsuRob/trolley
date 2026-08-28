import AppKit
import Foundation
import TrolleyKit
import TrolleyMCP
import TrolleyWidget

/// The wiki, as a place you go rather than a thing that follows you.
///
/// It used to follow you. The vault's list rode in front of whatever was typed into the
/// prompt box, and its two tools sat in every question's catalog -- so asking trolley to
/// open Chrome cost a paragraph about `wiki_search`, and the model, reading a list from
/// the top, sometimes answered a wiki question by launching an app. One surface was doing
/// two unrelated jobs.
///
/// So the vault got its own window, and the split is the design: the prompt box below
/// talks to a model that can read markdown and nothing else, in a conversation of its
/// own, and the widget's prompt box talks to a model that can drive this Mac and has
/// never heard of the wiki. Neither needs a setting to say which is which.
final class WikiWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow

    // Top row -- the axes worth having in reach while reading. Everything else is behind
    // 상세 설정, which opens the options window this one used to be a preview inside.
    private let searchField = NSSearchField()
    private let folderPopup = NSPopUpButton()
    private let statusPopup = NSPopUpButton()
    /// 담당, built at runtime from whatever handles the vault currently holds -- the only
    /// one of the three whose values are not known before a walk.
    private let assigneePopup = NSPopUpButton()
    /// What `assigneePopup` was last built from, so a reload that changes nothing does
    /// not rebuild the menu under someone's open dropdown.
    private var knownAssignees: [String] = []

    private let table = NSTableView()
    private let tableScroll = NSScrollView()
    private let countLabel = NSTextField(labelWithString: "")

    /// Guards `layoutColumns` against the resize notification its own writes raise.
    private var isLayingOutColumns = false
    /// Whether the stored divider position has been read yet. Nothing may be written
    /// before it has: the split view lays out once with its default position while the
    /// window is coming up, and that layout used to store 400 over the width someone
    /// dragged yesterday -- which `restoreListWidth` then dutifully read back.
    private var hasRestoredListWidth = false

    /// The list and the page, and the divider between them.
    ///
    /// A split view rather than two columns of a stack because the list's width was a
    /// number in this file: 360 points, chosen once, and 담당 fell off the right edge of
    /// it the moment a handle was longer than the leftovers. Whoever is reading decides
    /// now, by dragging.
    private let columns = NSSplitView()
    private let listPane = NSView()
    private let pagePane = NSView()

    private let titleLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let bodyText = NSTextView()
    private let bodyScroll = NSScrollView()

    private let promptField = NSTextField()
    private let contextLabel = NSTextField(labelWithString: "")
    private let answerText = NSTextView()
    private let answerScroll = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let newThreadButton = NSButton(title: "새 대화", target: nil, action: nil)

    // Claude 호출 -- a separate destination from the local wiki LLM `promptField` talks
    // to, with its own prompt box so the two conversations never share one text field.
    // Radio buttons rather than checkboxes: a person picks exactly one way to reach
    // Claude at a time, not a fan-out to everything checked.
    private let terminalRadio = NSButton(radioButtonWithTitle: "터미널", target: nil, action: nil)
    private let orcaRadio = NSButton(radioButtonWithTitle: "orca 배분", target: nil, action: nil)
    private let desktopRadio = NSButton(radioButtonWithTitle: "Claude Desktop", target: nil, action: nil)
    private let claudeInvokePromptField = NSTextField()
    private let claudeInvokeButton = NSButton(title: "Claude 호출", target: nil, action: nil)
    private let claudeInvokeStatusLabel = NSTextField(labelWithString: "")
    private let claudeInvokeDispatcher = ClaudeInvokeDispatcher.makeDefault()

    /// The rows on screen, in the order the sort put them.
    private var pages: [WikiPage] = []
    private var openPage: WikiPage?
    private var openBody = ""
    /// Which page the conversation has already been handed.
    ///
    /// The server replays every message of a conversation as the prompt, so a body sent
    /// once is re-sent on every later turn of that thread. Attaching it per question
    /// would cost the whole vault's context by the fifth follow-up -- the same trap that
    /// took the wiki digest off the widget's prompt path. So the body rides exactly once,
    /// and opening a different page starts a fresh thread instead.
    private var attachedPage: String?

    private let session: LocalLLMSession
    private lazy var settings = WikiSettingsWindowController()
    /// Set by `WelcomeFlow`: the options window can change the folder, and this window is
    /// what has to notice.
    private var lastRootPath = WikiSettings.rootPath

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 620),
            // Resizable, unlike the setup window: this one holds a document.
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        // Built before `super.init` can be referenced by the closures below.
        let toolRunner = WikiToolRunner()
        var currentContext: (() -> String?)?
        session = LocalLLMSession(
            makeContext: { currentContext?() },
            slot: .wiki,
            toolRunner: toolRunner
        )
        super.init()
        currentContext = { [weak self] in self?.takeContext() }

        window.title = "위키"
        // Same reason as the other two: an NSWindow that releases itself on close leaves
        // this controller holding freed memory, and reopening then takes the app down.
        window.isReleasedWhenClosed = false
        // Both panes at their minimums, plus the margins around them. Narrower than this
        // there is nothing left to divide -- `enforceMinimums` takes the list's width
        // away first, and below this floor even that has run out.
        window.contentMinSize = NSSize(
            width: Self.minimumListWidth + Self.minimumPageWidth + 30, height: 420
        )
        window.delegate = self
        window.center()
        window.contentView = makeContentView()
        session.onChange = { [weak self] in self?.renderAnswer() }
    }

    func show() {
        // A folder changed in the options window while this was closed has to land.
        if WikiSettings.rootPath != lastRootPath {
            lastRootPath = WikiSettings.rootPath
            openPage = nil
        }
        // The options window's 내 일감 can move 담당 while this one is closed.
        restoreToolbar()
        restoreClaudeInvokeRow()
        reloadList()
        window.makeKeyAndOrderFront(nil)
        restoreListWidth()
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(searchField)
    }

    var isVisible: Bool { window.isVisible }

    // MARK: - Layout

    private func makeContentView() -> NSView {
        searchField.placeholderString = "제목·요약에 포함된 말"
        searchField.target = self
        searchField.action = #selector(filterChanged)
        searchField.sendsSearchStringImmediately = false
        searchField.widthAnchor.constraint(equalToConstant: 220).isActive = true

        folderPopup.addItem(withTitle: Self.anyFolder)
        for folder in WikiIndex.indexableFolders + WikiIndex.optionalFolders {
            folderPopup.addItem(withTitle: folder)
        }
        statusPopup.addItem(withTitle: Self.anyStatus)
        for status in Self.statuses {
            statusPopup.addItem(withTitle: status)
        }
        // 전체/미지정 only until a walk returns; `refreshAssigneeMenu` appends the handles.
        assigneePopup.addItems(withTitles: [Self.anyAssignee, Self.noAssignee])
        for popup in [folderPopup, statusPopup, assigneePopup] {
            popup.target = self
            popup.action = #selector(filterChanged)
        }
        restoreToolbar()

        let settingsButton = NSButton(title: "상세 설정", target: self, action: #selector(openSettings))
        settingsButton.bezelStyle = .rounded
        let topRow = NSStackView(
            views: [searchField, folderPopup, statusPopup, assigneePopup, NSView(), settingsButton]
        )
        topRow.orientation = .horizontal
        topRow.spacing = 8

        // -- left: the list
        table.headerView = NSTableHeaderView()
        table.usesAlternatingRowBackgroundColors = true
        table.rowSizeStyle = .default
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(focusPrompt)
        // Widths a person can drag, and the widths they leave behind. `autosaveName` does
        // the remembering; `layoutColumns` does the arithmetic, which is why none of
        // AppKit's own autoresizing styles is on: they either spread every extra point
        // over all three columns or let the total run wider than what is on screen --
        // and a total wider than the clip view is exactly how 담당 came to be half off
        // the right edge.
        table.columnAutoresizingStyle = .noColumnAutoresizing
        // The order is the reading order -- 제목 first, and the two narrow facts after
        // it. Dragging a header sideways only ever produced a list with 상태 in front of
        // the title, which is nobody's intent while reaching for the divider beside it.
        table.allowsColumnReordering = false
        for (identifier, title, width, minimum, maximum) in [
            // 제목 is the filler: not draggable, because it is whatever the other two
            // leave behind. Dragging it could only mean taking room from itself.
            ("title", "제목", CGFloat(180), CGFloat(90), CGFloat(4_000)),
            ("status", "상태", 56, 44, 160),
            // 담당 holds a handle, and 76 fit eight characters only when nothing else
            // spilled. The default is measured against the longest handle in the vault
            // (`MINHYEOKJEON99`, fourteen characters); anything longer is a drag away.
            ("assignee", "담당", 112, 56, 320)
        ] {
            let column = NSTableColumn(identifier: .init(identifier))
            column.title = title
            column.width = width
            column.minWidth = minimum
            column.maxWidth = maximum
            column.resizingMask = identifier == "title" ? [] : [.userResizingMask]
            table.addTableColumn(column)
        }
        // A fourth, fixed-width column that is a button rather than text -- the quick way
        // to hand a row straight to Claude without opening it first. Cell-based like the
        // three text columns above it (a hover-revealed button would need the whole table
        // rebuilt as view-based rows), so it stays a plain `NSButtonCell`.
        let invokeColumn = NSTableColumn(identifier: .init("invoke"))
        invokeColumn.title = ""
        invokeColumn.width = 56
        invokeColumn.minWidth = 56
        invokeColumn.maxWidth = 56
        invokeColumn.resizingMask = []
        let invokeCell = NSButtonCell()
        invokeCell.title = "실행"
        invokeCell.bezelStyle = .inline
        invokeCell.controlSize = .mini
        invokeCell.font = .systemFont(ofSize: 10)
        invokeColumn.dataCell = invokeCell
        table.addTableColumn(invokeColumn)
        // After the columns exist, never before: `autosaveName` restores widths for the
        // columns the table holds at the moment it is set, and a table that holds none
        // yet restores nothing -- then saves its defaults over what was stored, which is
        // how a dragged 담당 came back at 96 points every launch.
        table.autosaveName = "trolley.wiki.list"
        table.autosaveTableColumns = true
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        // Only reachable by dragging 상태 or 담당 wider than the pane, which is a
        // deliberate act -- but a table drawn wider than its clip view with no way to
        // reach the rest is the same complaint this change started from.
        tableScroll.hasHorizontalScroller = true
        tableScroll.autohidesScrollers = true
        tableScroll.borderType = .bezelBorder
        tableScroll.translatesAutoresizingMaskIntoConstraints = false
        // Every way the list's width can change ends here: the divider dragged, the
        // window resized, the first layout pass after the window opens. Watching the
        // clip view rather than the split view is what makes the last one land -- the
        // divider is put in place before the pane has been given its width, and a
        // `layoutColumns` from there measured a list 100 points narrower than the one
        // that appeared a moment later.
        tableScroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(listWidthChanged),
            name: NSView.frameDidChangeNotification, object: tableScroll.contentView
        )

        countLabel.font = .systemFont(ofSize: 10)
        countLabel.textColor = .secondaryLabelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        listPane.addSubview(tableScroll)
        listPane.addSubview(countLabel)
        NSLayoutConstraint.activate([
            tableScroll.topAnchor.constraint(equalTo: listPane.topAnchor),
            tableScroll.leadingAnchor.constraint(equalTo: listPane.leadingAnchor),
            tableScroll.trailingAnchor.constraint(equalTo: listPane.trailingAnchor),
            countLabel.topAnchor.constraint(equalTo: tableScroll.bottomAnchor, constant: 4),
            countLabel.leadingAnchor.constraint(equalTo: listPane.leadingAnchor),
            countLabel.trailingAnchor.constraint(lessThanOrEqualTo: listPane.trailingAnchor),
            countLabel.bottomAnchor.constraint(equalTo: listPane.bottomAnchor)
        ])

        // -- right: the page
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        metaLabel.font = .systemFont(ofSize: 10)
        metaLabel.textColor = .secondaryLabelColor
        bodyText.isEditable = false
        bodyText.isSelectable = true
        bodyText.textContainerInset = NSSize(width: 10, height: 10)
        bodyText.drawsBackground = false
        bodyScroll.documentView = bodyText
        bodyScroll.hasVerticalScroller = true
        bodyScroll.borderType = .bezelBorder
        bodyScroll.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        pagePane.addSubview(titleLabel)
        pagePane.addSubview(metaLabel)
        pagePane.addSubview(bodyScroll)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: pagePane.topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: pagePane.leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: pagePane.trailingAnchor),
            metaLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            metaLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            metaLabel.trailingAnchor.constraint(equalTo: pagePane.trailingAnchor),
            bodyScroll.topAnchor.constraint(equalTo: metaLabel.bottomAnchor, constant: 4),
            bodyScroll.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            bodyScroll.trailingAnchor.constraint(equalTo: pagePane.trailingAnchor),
            bodyScroll.bottomAnchor.constraint(equalTo: pagePane.bottomAnchor)
        ])

        columns.isVertical = true
        columns.dividerStyle = .thin
        columns.delegate = self
        columns.translatesAutoresizingMaskIntoConstraints = false
        columns.addArrangedSubview(listPane)
        columns.addArrangedSubview(pagePane)
        // The split view is what takes the room a taller window makes; the toolbar and
        // the prompt box below keep the heights they asked for.
        columns.setContentHuggingPriority(.init(1), for: .vertical)
        columns.setContentCompressionResistancePriority(.init(1), for: .vertical)

        // -- bottom: the prompt
        promptField.placeholderString = "이 문서에 대해 물어보세요…"
        promptField.font = .systemFont(ofSize: 12)
        promptField.target = self
        promptField.action = #selector(sendPrompt)
        contextLabel.font = .systemFont(ofSize: 10)
        contextLabel.textColor = .tertiaryLabelColor
        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = .secondaryLabelColor
        newThreadButton.bezelStyle = .rounded
        newThreadButton.controlSize = .small
        newThreadButton.target = self
        newThreadButton.action = #selector(startNewThread)

        answerText.isEditable = false
        answerText.isSelectable = true
        answerText.textContainerInset = NSSize(width: 8, height: 8)
        answerText.drawsBackground = false
        answerScroll.documentView = answerText
        answerScroll.hasVerticalScroller = true
        answerScroll.borderType = .bezelBorder
        answerScroll.translatesAutoresizingMaskIntoConstraints = false
        answerScroll.heightAnchor.constraint(equalToConstant: 110).isActive = true

        let statusRow = NSStackView(views: [contextLabel, NSView(), statusLabel, newThreadButton])
        statusRow.orientation = .horizontal
        statusRow.spacing = 8

        let bottom = NSStackView(views: [promptField, statusRow, answerScroll])
        bottom.orientation = .vertical
        bottom.alignment = .leading
        bottom.spacing = 6

        // -- Claude 호출, just under the search row: its own radio group and its own
        // prompt box, entirely separate from the local wiki LLM's `promptField` below.
        for radio in [terminalRadio, orcaRadio, desktopRadio] {
            radio.target = self
            radio.action = #selector(claudeInvokeMethodToggled)
            radio.controlSize = .small
        }
        claudeInvokePromptField.placeholderString = "Claude 에게 보낼 내용…"
        claudeInvokePromptField.font = .systemFont(ofSize: 12)
        claudeInvokePromptField.target = self
        claudeInvokePromptField.action = #selector(invokeClaude)
        claudeInvokeButton.bezelStyle = .rounded
        claudeInvokeButton.controlSize = .small
        claudeInvokeButton.target = self
        claudeInvokeButton.action = #selector(invokeClaude)
        claudeInvokeStatusLabel.font = .systemFont(ofSize: 10)
        claudeInvokeStatusLabel.textColor = .secondaryLabelColor
        claudeInvokeStatusLabel.lineBreakMode = .byTruncatingTail

        let claudeInvokeMethodRow = NSStackView(views: [terminalRadio, orcaRadio, desktopRadio])
        claudeInvokeMethodRow.orientation = .horizontal
        claudeInvokeMethodRow.spacing = 8

        let claudeInvokeInputRow = NSStackView(
            views: [claudeInvokePromptField, claudeInvokeButton]
        )
        claudeInvokeInputRow.orientation = .horizontal
        claudeInvokeInputRow.spacing = 8

        let root = NSStackView(views: [
            topRow, claudeInvokeMethodRow, claudeInvokeInputRow, claudeInvokeStatusLabel,
            columns, bottom
        ])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        root.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            topRow.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -28),
            claudeInvokeMethodRow.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -28),
            claudeInvokeInputRow.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -28),
            claudeInvokeStatusLabel.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -28),
            columns.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -28),
            bottom.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -28),
            promptField.widthAnchor.constraint(equalTo: bottom.widthAnchor),
            statusRow.widthAnchor.constraint(equalTo: bottom.widthAnchor),
            answerScroll.widthAnchor.constraint(equalTo: bottom.widthAnchor),
            columns.heightAnchor.constraint(greaterThanOrEqualToConstant: 320)
        ])
        return container
    }

    // MARK: - The list

    // 전체 rows, and the one that means "nobody". Named because two places have to agree
    // about what sits at the top of each menu: the code that builds it and the code that
    // reads the selection back.
    static let anyFolder = "폴더 전체"
    static let anyStatus = "상태 전체"
    static let anyAssignee = "담당 전체"
    static let noAssignee = "미지정"
    static let statuses = ["진행중", "대기", "보류", "완료"]
    static var folders: [String] { WikiIndex.indexableFolders + WikiIndex.optionalFolders }

    private func currentFilter() -> WikiFilter {
        Self.filter(
            base: WikiSettings.filter,
            search: searchField.stringValue,
            folder: selection(folderPopup, any: Self.anyFolder),
            status: selection(statusPopup, any: Self.anyStatus),
            assignee: currentAssignee()
        )
    }

    /// The list the window shows: the stored filter, narrowed by the toolbar.
    ///
    /// Pure and static so the rule below can be asserted without a window.
    ///
    /// - Parameter base: what the options window stored. Its `assignees` is **dropped**,
    ///   not merged. That stored handle is why the window used to open on ten pages out
    ///   of two hundred with no visible reason, and the toolbar is now where 담당 is
    ///   decided -- inheriting it would make 담당 전체 mean "전체, except for the person
    ///   somebody picked in another window last week".
    /// - Parameter assignee: nil is 전체, `""` is 미지정, anything else is a handle.
    static func filter(
        base: WikiFilter, search: String,
        folder: String?, status: String?, assignee: String?
    ) -> WikiFilter {
        var filter = base
        // Not the stored `maxCount`: that number keeps a digest inside a character
        // budget, and nothing here is budgeted -- a person scrolling a table is not
        // spending context.
        filter.maxCount = 2_000
        filter.titleContains = search.trimmingCharacters(in: .whitespaces)
        filter.assignees = assignee.map { [$0] } ?? []
        if let folder { filter.folders = [folder] }
        if let status { filter.statuses = [status] }
        return filter
    }

    /// The popup's value, or nil when it is sitting on its 전체 row.
    private func selection(_ popup: NSPopUpButton, any: String) -> String? {
        guard let title = popup.titleOfSelectedItem, title != any else { return nil }
        return title
    }

    private func currentAssignee() -> String? {
        guard let title = assigneePopup.titleOfSelectedItem, title != Self.anyAssignee else {
            return nil
        }
        return title == Self.noAssignee ? "" : title
    }

    // MARK: - The divider, remembered

    /// Room the list never drops below, whatever the divider is dragged to. Under this
    /// the three columns stop being a table and start being a stack of ellipses.
    static let minimumListWidth: CGFloat = 240
    /// The same for the page. A markdown body narrower than this wraps every line twice.
    static let minimumPageWidth: CGFloat = 320
    /// Where the divider sits the first time, before anyone has dragged it: wide enough
    /// for 제목 plus 상태 plus a handle in 담당, which the old fixed 360 was not.
    static let defaultListWidth: CGFloat = 400

    /// Where the divider goes for a given window width.
    ///
    /// Pure because the case that matters is the one nobody drags into on purpose: a
    /// window narrowed until both minimums cannot hold. Clamping to the list's minimum
    /// there would push the page to nothing, so the two share what is left instead --
    /// a cramped page still shows a paragraph, a page of zero width shows the divider.
    static func listWidth(stored: Double?, available: CGFloat) -> CGFloat {
        let wanted = stored.map { CGFloat($0) } ?? defaultListWidth
        let ceiling = available - minimumPageWidth
        guard ceiling > minimumListWidth else { return max(available / 2, 0) }
        return min(max(wanted, minimumListWidth), ceiling)
    }

    /// Puts the divider back where it was left. Idempotent, so calling it on every open
    /// costs nothing: the stored width is the width it already has.
    private func restoreListWidth() {
        window.layoutIfNeeded()
        let available = columns.bounds.width - columns.dividerThickness
        guard available > 0 else { return }
        columns.setPosition(
            Self.listWidth(stored: WikiSettings.windowListWidth, available: available),
            ofDividerAt: 0
        )
        hasRestoredListWidth = true
    }

    @objc private func listWidthChanged() { layoutColumns() }

    /// Hands 제목 whatever 상태 and 담당 are not using.
    ///
    /// Called whenever either width could have moved -- the divider dragged, the window
    /// resized, a column header dragged. The invariant it keeps is the one this whole
    /// change is about: the three columns add up to what is on screen, so none of them
    /// is drawn past the right edge of the list.
    private func layoutColumns() {
        guard !isLayingOutColumns,
              let title = table.tableColumn(withIdentifier: .init("title"))
        else { return }
        let others = table.tableColumns.filter { $0 !== title }
        let spacing = table.intercellSpacing.width * CGFloat(table.tableColumns.count)
        let left = tableScroll.contentSize.width
            - others.reduce(0) { $0 + $1.width }
            - spacing
        isLayingOutColumns = true
        title.width = max(title.minWidth, left)
        isLayingOutColumns = false
    }

    /// Keeps the page above its minimum when the *window* is what shrank.
    ///
    /// `constrainMinCoordinate` only governs the drag. A window dragged narrower resizes
    /// the page alone -- that is the rule right below, and the right one while there is
    /// room -- so without this the page is squeezed toward nothing while the list holds
    /// a width nobody is defending. Reuses `listWidth`, so the window shrinking and the
    /// window reopening land on the same number.
    private func enforceMinimums() {
        let available = columns.bounds.width - columns.dividerThickness
        guard available > 0 else { return }
        let current = listPane.frame.width
        let clamped = Self.listWidth(stored: Double(current), available: available)
        // Terminates: the second pass sees a width that is already clamped.
        if abs(clamped - current) > 0.5 {
            columns.setPosition(clamped, ofDividerAt: 0)
        }
    }

    /// Written the moment the drag ends, like the three dropdowns above it -- no 저장
    /// button, for the same reason.
    ///
    /// The guard is against writing during teardown and during the first pass, when the
    /// split view has been laid out but not yet sized: a zero there would be stored as a
    /// deliberate choice and the list would open collapsed forever after.
    private func rememberListWidth() {
        let available = columns.bounds.width - columns.dividerThickness
        guard hasRestoredListWidth,
              available >= Self.minimumListWidth + Self.minimumPageWidth
        else { return }
        WikiSettings.windowListWidth = Double(listPane.frame.width)
    }

    // MARK: - The toolbar, remembered

    /// Puts the three dropdowns back where they were left.
    ///
    /// A stored value that no longer exists -- a folder dropped from the vault, a 상태
    /// nobody uses any more -- falls back to 전체 rather than selecting nothing. A popup
    /// with no selection reads as 전체 anyway and would then filter by it silently.
    /// 담당 is the exception: its menu is built from a walk that has not happened yet, so
    /// the stored handle is added now and `refreshAssigneeMenu` keeps it.
    private func restoreToolbar() {
        select(folderPopup, WikiSettings.windowFolder, any: Self.anyFolder)
        select(statusPopup, WikiSettings.windowStatus, any: Self.anyStatus)
        switch WikiSettings.windowAssignee {
        case .none: assigneePopup.selectItem(withTitle: Self.anyAssignee)
        case .some(""): assigneePopup.selectItem(withTitle: Self.noAssignee)
        case .some(let handle):
            if !assigneePopup.itemTitles.contains(handle) {
                assigneePopup.addItem(withTitle: handle)
            }
            assigneePopup.selectItem(withTitle: handle)
        }
    }

    private func select(_ popup: NSPopUpButton, _ stored: String?, any: String) {
        popup.selectItem(
            withTitle: Self.toolbarSelection(stored: stored, available: popup.itemTitles, any: any)
        )
    }

    /// Which row a remembered value should land on.
    ///
    /// Pure because the interesting case is the one nobody sees coming: a folder that has
    /// left the vault, or a 상태 this build no longer offers. Selecting nothing there
    /// leaves a popup that reads as 전체 and filters by something else.
    static func toolbarSelection(stored: String?, available: [String], any: String) -> String {
        guard let stored, available.contains(stored) else { return any }
        return stored
    }

    /// Written the moment a dropdown moves. No 저장 button: these are the knobs someone
    /// turns while reading, and a knob that forgets is one they turn again every morning.
    private func rememberToolbar() {
        WikiSettings.windowFolder = selection(folderPopup, any: Self.anyFolder)
        WikiSettings.windowStatus = selection(statusPopup, any: Self.anyStatus)
        let assignee = currentAssignee()
        WikiSettings.windowAssignee = assignee
        // Whoever you keep filtering to is who 내 일감 means. Learned from the pick rather
        // than asked for in a field of its own -- this used to live on the options
        // window's 저장, which is where 담당 used to live.
        if let assignee, !assignee.isEmpty { WikiSettings.me = assignee }
    }

    /// Rebuilds 담당 from what the walk found, without losing the current pick.
    ///
    /// The union with the selection is the part that matters: a handle that has left the
    /// vault -- or one the CLI wrote and no snapshot has shown yet -- still has to appear,
    /// because a selection that quietly falls off the menu is a filter that quietly
    /// widens. Same rule the options window used when this popup lived there.
    private func refreshAssigneeMenu(from handles: [String]) {
        let selected = currentAssignee()
        let merged = Set(handles).union(selected.map { [$0] } ?? [])
            .filter { !$0.isEmpty }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        guard merged != knownAssignees else { return }
        knownAssignees = merged

        assigneePopup.removeAllItems()
        assigneePopup.addItems(withTitles: [Self.anyAssignee, Self.noAssignee])
        if !merged.isEmpty {
            assigneePopup.menu?.addItem(.separator())
            assigneePopup.addItems(withTitles: merged)
        }
        switch selected {
        case .none: assigneePopup.selectItem(withTitle: Self.anyAssignee)
        case .some(""): assigneePopup.selectItem(withTitle: Self.noAssignee)
        case .some(let handle): assigneePopup.selectItem(withTitle: handle)
        }
    }

    /// Walks the vault and fills the table -- off the main thread, always.
    ///
    /// It ran inline at first, and the freeze was total: `show()` called this, this
    /// called `WikiIndex.snapshot`, and the enumerator sat in `open()` while macOS held a
    /// consent prompt for `~/Desktop` that nobody could answer, because the thread that
    /// would have drawn it was this one. Even granted, a cold walk of a vault this size is
    /// not something a window opening should stop for -- and `WikiIndex` bounds its walk
    /// four ways precisely because it cannot bound one blocking `open`.
    ///
    /// `WikiIndex.snapshot` is already safe to call from anywhere: it copies its cache out
    /// under a lock, walks with no lock held, and copies back.
    private func reloadList() {
        guard let root = WikiSettings.rootURL else {
            pages = []
            countLabel.stringValue = "폴더가 지정되지 않았습니다."
            table.reloadData()
            return
        }
        let filter = currentFilter()
        reloadToken += 1
        let token = reloadToken
        if pages.isEmpty { countLabel.stringValue = "읽는 중…" }
        // A walk that has not come back by now is not slow, it is waiting on something.
        //
        // The one that happens: macOS gates `~/Desktop` for an unsandboxed app, and the
        // gate is a consent dialog that an `.accessory` app does not always get in front
        // of anyone. Until it is answered the enumerator sits inside `open()` -- no error,
        // no log, and nothing on screen but 읽는 중… forever. A vault on a slow network
        // share looks the same from here. Either way the honest thing is to say what is
        // probably happening and where the switch is, rather than to keep spinning.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.slowWalkWarning) { [weak self] in
            guard let self, token == self.reloadToken, self.pages.isEmpty else { return }
            self.countLabel.stringValue =
                "폴더를 읽는 중입니다. 오래 걸리면 macOS 가 접근 허락을 기다리는 중일 수 있습니다"
                + " — 시스템 설정 → 개인정보 보호 및 보안 → 파일 및 폴더."
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Every folder, always. The stored `folders` narrows the *list* a person is
            // shown, and narrowing the walk to match would make the folder popup unable
            // to widen it back.
            let outcome = Result {
                try WikiIndex.shared.snapshot(
                    root: root, folders: WikiIndex.indexableFolders + WikiIndex.optionalFolders
                )
            }
            DispatchQueue.main.async {
                guard let self, token == self.reloadToken else { return }
                self.apply(outcome, filter: filter)
            }
        }
    }

    /// How long a walk may take before the window stops saying only 읽는 중….
    ///
    /// Four seconds because a cold walk of the real vault is 25ms and a warm one is
    /// nothing; anything past a second here is already not a walk.
    static let slowWalkWarning: TimeInterval = 4

    /// Which reload the table is allowed to show.
    ///
    /// Typing in the search box starts one walk per keystroke and they can finish out of
    /// order; without this the list would settle on whichever the disk happened to return
    /// last rather than on what is in the box.
    private var reloadToken = 0

    private func apply(_ outcome: Result<WikiSnapshot, Error>, filter: WikiFilter) {
        switch outcome {
        case .success(let snapshot):
            // From the snapshot the walk already returned, not a second one.
            refreshAssigneeMenu(from: snapshot.pages.map(\.assignee))
            let (kept, dropped) = filter.apply(to: snapshot.pages)
            pages = kept
            countLabel.stringValue = dropped > 0
                ? "\(kept.count)건 (조건에 맞지 않는 \(dropped)건 제외)"
                : "\(kept.count)건"
            if !snapshot.skipped.isEmpty {
                countLabel.stringValue += " · 읽지 못한 파일 \(snapshot.skipped.count)건"
            }
        case .failure(let error):
            pages = []
            // The one failure worth telling apart. `~/Desktop` is gated by macOS even for
            // an unsandboxed app, and "폴더를 읽지 못했습니다" sends someone looking for a
            // folder that is exactly where they left it.
            // Matched by case, not by value: `denied` carries the expanded path and
            // `rootPath` keeps its `~`, so comparing the two never says yes.
            if case .denied = error as? WikiIndex.Failure {
                countLabel.stringValue =
                    "폴더에 접근할 수 없습니다. 상세 설정에서 폴더를 다시 고르면 권한이 붙습니다."
            } else {
                countLabel.stringValue = "폴더를 읽지 못했습니다 — \(WikiSettings.rootPath)"
            }
        }
        table.reloadData()
        restoreSelection()
    }

    /// Keeps the open page selected across a reload, so typing in the search box does not
    /// close the document being read.
    private func restoreSelection() {
        guard let openPage, let row = pages.firstIndex(where: { $0.path == openPage.path }) else {
            return
        }
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func filterChanged() {
        rememberToolbar()
        reloadList()
    }

    @objc private func openSettings() { settings.show() }

    @objc private func focusPrompt() { window.makeFirstResponder(promptField) }

    // MARK: - The page

    /// Opens the window already showing `page`, whatever the toolbar's filters would
    /// otherwise include -- used by the panel's 내 일감 preview, which can name a page
    /// the window's own stored filter would hide.
    ///
    /// Renders immediately from `page` itself rather than waiting on `reloadList`'s walk:
    /// `openPage(at:)` already reads a page's body straight from `page.path`, never from
    /// the snapshot, so nothing here needs the walk to have finished. If the walk later
    /// turns up this same path, `restoreSelection` -- which reads the `openPage` this
    /// sets -- highlights it in the list on its own.
    func open(_ page: WikiPage) {
        show()
        present(page)
    }

    private func openPage(at row: Int) {
        guard pages.indices.contains(row) else { return }
        present(pages[row])
    }

    private func present(_ page: WikiPage) {
        guard page.path != openPage?.path else { return }
        openPage = page
        titleLabel.stringValue = page.basename
        metaLabel.stringValue = [
            page.status, page.type, page.assignee, page.areas.joined(separator: "·"),
            page.updated.isEmpty ? "" : "갱신 \(page.updated)", page.relativePath
        ].filter { !$0.isEmpty }.joined(separator: " · ")

        // Read by the path the index handed us. That is the same guarantee `wiki_read`
        // relies on: a path that came out of the walk cannot be one the walk refused.
        let body = (try? String(contentsOfFile: page.path, encoding: .utf8)) ?? ""
        openBody = body
        // Rendered without the frontmatter, kept with it. Markdown has nothing to say
        // about a YAML block, so it draws as a rule and a run-on paragraph -- 유형, 상태,
        // 분류, 담당 all collapsed into one line of prose, above the line that already
        // says them properly. The model still gets the block: 상태 and 담당 are things it
        // is asked about, and it reads YAML fine.
        let shown = Self.withoutFrontmatter(body)
        bodyText.textStorage?.setAttributedString(
            shown.isEmpty
                ? NSAttributedString(string: "본문이 비어 있습니다.")
                : MarkdownRendering.attributed(shown, style: .document)
        )
        bodyText.scrollToBeginningOfDocument(nil)
        updateContextLabel()
    }

    /// The page without its leading `---` block.
    ///
    /// Only a *leading* one, and only a closed one: a page that opens with a horizontal
    /// rule is not a page with broken frontmatter, and dropping to the next `---` in that
    /// case would eat the first section.
    static func withoutFrontmatter(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let close = lines.dropFirst().firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespaces) == "---"
              })
        else { return text }
        return lines[(close + 1)...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// How much of a page rides in front of a question.
    ///
    /// Below `wiki_read`'s own 8,000 for the same reason it has one: an agent reading
    /// five pages should not be able to spend a context window without noticing, and here
    /// the body is joined by the tool contract and the question itself.
    static let contextLimit = 6_000

    /// The material for the next question, or nil when there is none to add.
    ///
    /// Called once per send, and it *takes*: a page already handed to this conversation
    /// is not handed to it again. See `attachedPage`.
    private func takeContext() -> String? {
        guard let openPage, !openBody.isEmpty, attachedPage != openPage.path else { return nil }
        attachedPage = openPage.path
        let body = openBody.count > Self.contextLimit
            ? String(openBody.prefix(Self.contextLimit)) + "\n\n…(본문 일부 생략)"
            : openBody
        return """
        아래는 지금 사람이 열어놓고 보고 있는 위키 문서다. 제목은 [[\(openPage.basename)]] 이다.
        이 문서에 없는 내용은 wiki_search 나 wiki_read 로 확인하고, 확인하지 못한 것은 추측하지 마라.

        \(body)
        """
    }

    private func updateContextLabel() {
        guard let openPage else {
            contextLabel.stringValue = "문서를 고르면 그 본문을 놓고 물어볼 수 있습니다."
            return
        }
        contextLabel.stringValue = attachedPage == openPage.path
            ? "[[\(openPage.basename)]] 로 이야기 중"
            : "[[\(openPage.basename)]] — 다음 질문에 본문이 함께 갑니다"
    }

    // MARK: - Asking

    @objc private func sendPrompt() {
        let text = promptField.stringValue
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // A different page than the thread was built around starts a new thread rather
        // than stacking a second body onto the first. Two documents in one replayed
        // history is how an answer starts quoting the page nobody is looking at.
        if let openPage, let attached = attachedPage, attached != openPage.path {
            session.startNewConversation()
        }
        guard session.send(text) else {
            renderAnswer()
            return
        }
        promptField.stringValue = ""
        updateContextLabel()
    }

    @objc private func startNewThread() {
        session.startNewConversation()
        attachedPage = nil
        answerText.textStorage?.setAttributedString(NSAttributedString())
        updateContextLabel()
        renderAnswer()
    }

    private func renderAnswer() {
        let body = session.visibleAnswer.isEmpty ? session.draft : session.visibleAnswer
        answerText.textStorage?.setAttributedString(
            MarkdownRendering.attributed(body, style: .panel)
        )
        answerText.scrollToEndOfDocument(nil)
        statusLabel.stringValue = LocalLLMSession.statusLine(
            for: session.phase, backend: session.backend
        )
    }

    // MARK: - Claude 호출

    /// Written the moment a radio moves, like the toolbar dropdowns above -- no 저장
    /// button, because picking a method right before pressing 호출 is not filling out a
    /// form. Radios in the same stack view are mutually exclusive on their own, so
    /// exactly one of the three is ever on.
    @objc private func claudeInvokeMethodToggled() {
        if terminalRadio.state == .on { ClaudeInvokeSettings.invokeMethod = .terminal }
        else if orcaRadio.state == .on { ClaudeInvokeSettings.invokeMethod = .orca }
        else if desktopRadio.state == .on { ClaudeInvokeSettings.invokeMethod = .desktop }
    }

    /// Reapplies the radio group's remembered state -- the settings window can
    /// change the per-method options while this window is closed, and the
    /// radios themselves can be toggled here and should still read back the
    /// same on the next `show()`.
    private func restoreClaudeInvokeRow() {
        let method = ClaudeInvokeSettings.invokeMethod
        terminalRadio.state = method == .terminal ? .on : .off
        orcaRadio.state = method == .orca ? .on : .off
        desktopRadio.state = method == .desktop ? .on : .off
    }

    @objc private func invokeClaude() {
        let text = claudeInvokePromptField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let prompt = ClaudeInvokePromptBuilder.compose(
            userText: text,
            pageTitle: openPage?.basename,
            pageBody: openBody,
            attachContext: ClaudeInvokeSettings.attachWikiContext && openPage != nil
        )
        send(prompt: prompt, label: nil)
    }

    /// The quick way to hand a row straight to Claude without opening it first -- the
    /// "실행" button in the list's fourth column. Reuses whatever is already typed in
    /// `claudeInvokePromptField` as the instruction, so the flow is "write it once, fire
    /// it at as many rows as it applies to" rather than guessing a default instruction
    /// per press.
    private func quickInvokeClaude(for page: WikiPage) {
        let text = claudeInvokePromptField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            claudeInvokeStatusLabel.stringValue = "먼저 프롬프트를 입력하세요."
            return
        }
        // Read straight from disk, like `present(_:)` does for the row someone opens --
        // this row need not be the one currently open.
        let body = (try? String(contentsOfFile: page.path, encoding: .utf8)) ?? ""
        let prompt = ClaudeInvokePromptBuilder.compose(
            userText: text, pageTitle: page.basename, pageBody: body, attachContext: true
        )
        send(prompt: prompt, label: page.basename)
    }

    /// Shared by the main 호출 button and each row's quick-invoke button. `label`, when
    /// given, prefixes the status line so a row's result is not mistaken for the main
    /// prompt's.
    private func send(prompt: String, label: String?) {
        claudeInvokeButton.isEnabled = false
        claudeInvokeStatusLabel.stringValue = "호출하는 중…"
        claudeInvokeDispatcher.invoke(
            prompt: prompt,
            methods: [ClaudeInvokeSettings.invokeMethod],
            confirm: { [weak self] message in
                guard let self else { return false }
                // Called from the dispatcher's background queue; NSAlert needs
                // the main thread, and the background side is free to block on
                // it since it is not itself holding anything main needs.
                return DispatchQueue.main.sync { self.confirmSend(message) }
            }
        ) { [weak self] results in
            guard let self else { return }
            self.claudeInvokeButton.isEnabled = true
            let line = results
                .map { "\($0.success ? "✓" : "✗") \($0.message)" }
                .joined(separator: "  ·  ")
            self.claudeInvokeStatusLabel.stringValue = label.map { "[[\($0)]] · \(line)" } ?? line
        }
    }

    private func confirmSend(_ message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Claude 호출"
        alert.informativeText = message
        alert.addButton(withTitle: "보내기")
        alert.addButton(withTitle: "취소")
        return alert.runModal() == .alertFirstButtonReturn
    }

    @objc private func rowInvokeButtonClicked(_ sender: NSButtonCell) {
        guard pages.indices.contains(sender.tag) else { return }
        quickInvokeClaude(for: pages[sender.tag])
    }
}

extension WikiWindowController: NSSplitViewDelegate {
    func splitView(
        _ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        max(proposedMinimumPosition, Self.minimumListWidth)
    }

    func splitView(
        _ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        min(
            proposedMaximumPosition,
            splitView.bounds.width - splitView.dividerThickness - Self.minimumPageWidth
        )
    }

    /// A wider window widens the page, not the list. The list is three columns and a
    /// person sized them; the page is prose and always wants more.
    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        view !== listPane
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        enforceMinimums()
        rememberListWidth()
    }
}

extension WikiWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { pages.count }

    func tableView(
        _ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int
    ) -> Any? {
        guard pages.indices.contains(row) else { return nil }
        let page = pages[row]
        switch tableColumn?.identifier.rawValue {
        case "status": return page.status
        case "assignee": return page.assignee
        case "invoke": return nil
        default: return page.basename
        }
    }

    /// Gives the "실행" cell its own target/action, carrying the row in `tag` --
    /// rather than leaning on `NSTableView.clickedRow`, which is only set by a
    /// literal mouse-down the table view itself tracks. A press performed through
    /// the accessibility tree (VoiceOver, or `trolley click` on this very button)
    /// calls `NSCell.performClick`, which fires the *cell's* target/action and
    /// never touches `clickedRow` at all -- so without this, the row's button
    /// would work for a mouse but not for the automation this app is built on.
    func tableView(
        _ tableView: NSTableView, willDisplayCell cell: Any, for tableColumn: NSTableColumn?,
        row: Int
    ) {
        guard tableColumn?.identifier.rawValue == "invoke", let buttonCell = cell as? NSButtonCell
        else { return }
        buttonCell.tag = row
        buttonCell.target = self
        buttonCell.action = #selector(rowInvokeButtonClicked(_:))
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        openPage(at: table.selectedRow)
    }

    /// A header divider was dragged. 상태 and 담당 keep what they were given; 제목 gives
    /// up or takes back the difference, so the total still fits.
    func tableViewColumnDidResize(_ notification: Notification) {
        layoutColumns()
    }
}
