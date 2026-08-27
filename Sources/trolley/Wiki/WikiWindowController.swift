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

    private let table = NSTableView()
    private let tableScroll = NSScrollView()
    private let countLabel = NSTextField(labelWithString: "")

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
        reloadList()
        window.makeKeyAndOrderFront(nil)
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

        folderPopup.addItem(withTitle: "폴더 전체")
        for folder in WikiIndex.indexableFolders + WikiIndex.optionalFolders {
            folderPopup.addItem(withTitle: folder)
        }
        statusPopup.addItem(withTitle: "상태 전체")
        for status in ["진행중", "대기", "보류", "완료"] {
            statusPopup.addItem(withTitle: status)
        }
        for popup in [folderPopup, statusPopup] {
            popup.target = self
            popup.action = #selector(filterChanged)
        }

        let settingsButton = NSButton(title: "상세 설정", target: self, action: #selector(openSettings))
        settingsButton.bezelStyle = .rounded
        let topRow = NSStackView(views: [searchField, folderPopup, statusPopup, NSView(), settingsButton])
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
        for (identifier, title, width) in [
            ("title", "제목", CGFloat(210)), ("status", "상태", 56), ("assignee", "담당", 76)
        ] {
            let column = NSTableColumn(identifier: .init(identifier))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.borderType = .bezelBorder
        tableScroll.translatesAutoresizingMaskIntoConstraints = false
        tableScroll.widthAnchor.constraint(equalToConstant: 360).isActive = true

        countLabel.font = .systemFont(ofSize: 10)
        countLabel.textColor = .secondaryLabelColor
        let leftColumn = NSStackView(views: [tableScroll, countLabel])
        leftColumn.orientation = .vertical
        leftColumn.alignment = .leading
        leftColumn.spacing = 4

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

        let rightColumn = NSStackView(views: [titleLabel, metaLabel, bodyScroll])
        rightColumn.orientation = .vertical
        rightColumn.alignment = .leading
        rightColumn.spacing = 4

        let columns = NSStackView(views: [leftColumn, rightColumn])
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.spacing = 12
        columns.distribution = .fill

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

        let root = NSStackView(views: [topRow, columns, bottom])
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
            columns.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -28),
            bottom.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -28),
            promptField.widthAnchor.constraint(equalTo: bottom.widthAnchor),
            statusRow.widthAnchor.constraint(equalTo: bottom.widthAnchor),
            answerScroll.widthAnchor.constraint(equalTo: bottom.widthAnchor),
            rightColumn.widthAnchor.constraint(greaterThanOrEqualToConstant: 380),
            bodyScroll.widthAnchor.constraint(equalTo: rightColumn.widthAnchor),
            bodyScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
            tableScroll.heightAnchor.constraint(equalTo: bodyScroll.heightAnchor)
        ])
        return container
    }

    // MARK: - The list

    /// The filter the list starts from: whatever the options window stored, narrowed by
    /// the three controls up top.
    ///
    /// `maxCount` is deliberately not the stored one. That number exists to keep a digest
    /// inside a character budget, and nothing here is budgeted -- a person scrolling a
    /// table is not spending context.
    private func currentFilter() -> WikiFilter {
        var filter = WikiSettings.filter
        filter.maxCount = 2_000
        filter.titleContains = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        if folderPopup.indexOfSelectedItem > 0, let folder = folderPopup.titleOfSelectedItem {
            filter.folders = [folder]
        }
        if statusPopup.indexOfSelectedItem > 0, let status = statusPopup.titleOfSelectedItem {
            filter.statuses = [status]
        }
        return filter
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

    @objc private func filterChanged() { reloadList() }

    @objc private func openSettings() { settings.show() }

    @objc private func focusPrompt() { window.makeFirstResponder(promptField) }

    // MARK: - The page

    private func openPage(at row: Int) {
        guard pages.indices.contains(row) else { return }
        let page = pages[row]
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
        default: return page.basename
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        openPage(at: table.selectedRow)
    }
}
