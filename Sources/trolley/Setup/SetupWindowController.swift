import AppKit
import Foundation
import TrolleyKit

/// The window a double-click opens: everything trolley needs in order to work,
/// each with the button that fixes it.
///
/// It exists because the alternative was a wall of terminal commands. Grants and
/// MCP registration both key on the executable path, and both are easy to get
/// subtly wrong by hand -- pasting a path from a mounted disk image is the
/// classic one, which is why the install location is checked first.
final class SetupWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let locationRow = SetupRow(title: SetupCopy.locationTitle)
    private let accessibilityRow = SetupRow(title: SetupCopy.accessibilityTitle)
    private let screenRow = SetupRow(title: SetupCopy.screenRecordingTitle)
    private let llmRow = SetupRow(title: SetupCopy.llmTitle)
    private let wikiRow = SetupRow(title: "LLM 위키")
    private var refreshTimer: Timer?

    /// The two faces of this window. Both are built once in `makeContentView()`
    /// and only ever hidden -- never rebuilt. This window has a crash history
    /// around its own lifetime (`isReleasedWhenClosed = false`), and `refresh()`
    /// runs every 1.5 seconds, so anything that recreates views here would be
    /// paying that cost forty times a minute as well as risking the old bug.
    private let readyGroup = NSStackView()
    private let checklistGroup = NSStackView()
    private let detailsGroup = NSStackView()
    private let detailsGrid = NSStackView()
    private let rootStack = NSStackView()
    private let container = NSView()
    private let disclosure = NSButton()
    private lazy var detailsExpanded = UserDefaults.standard.bool(forKey: Self.detailsKey)
    private static let detailsKey = "trolley.setup.detailsExpanded"
    private static let contentWidth: CGFloat = 460
    private static let minContentHeight: CGFloat = 180

    /// Opens the prompt box. Set by `WelcomeFlow`; the ready screen's button is
    /// hidden without it, since a button that does nothing is worse than none.
    var onAsk: (() -> Void)?
    /// Fired the first time this window sees everything go green. `WelcomeFlow`
    /// uses it to introduce the prompt box once.
    var onBecameReady: (() -> Void)?
    private var wasReady = false
    private weak var askButton: NSButton?

    /// Both cached because they shell out; the timer must not run them twice a
    /// second. Re-checked on a slower beat so registering from a terminal still
    /// turns the row green without relaunching.
    private var claudePath: String??

    /// One controller for the life of the window, like the setup window itself: a
    /// window that has already released itself on close takes the process down when
    /// anything touches it again.
    private lazy var wikiSettings = WikiSettingsWindowController()

    /// Same treatment as the MCP and LLM rows. Walking the wiki is fast -- 25ms for
    /// the real vault's 110 files -- but 1.5-second repaints would still mean 40 disk
    /// walks a minute for a folder nobody is editing.
    private var wikiSummary: String?
    private var wikiState: SetupRow.State = .optional
    private var lastWikiCheck: Date?

    /// Same treatment as the MCP row: a network round trip must not ride the
    /// 1.5-second repaint timer.
    private var llmStatus: Result<LocalLLMClient.Status, LocalLLMClient.Failure>?
    private var lastLLMCheck: Date?
    private var llmCheckInFlight = false

    private var executablePath: String { AccessibilityPermission.currentExecutablePath() }
    private var bundlePath: String { Bundle.main.bundleURL.path }

    /// What "가동 시간" counts from. Handed in rather than taken here, because this
    /// window is built the first time somebody opens it: on a Mac where everything
    /// is already granted that is often hours after launch, and a window that timed
    /// itself would report minutes for an app that had been up all morning.
    private let launchedAt: Date

    init(launchedAt: Date = Date()) {
        self.launchedAt = launchedAt
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = "trolley \(TrolleyVersion.display)"
        // NSWindow releases itself on close by default, which under ARC leaves
        // this controller holding freed memory -- reopening then crashed the
        // whole app, pet included, inside `isVisible`. The window's lifetime
        // belongs to this controller.
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.contentView = makeContentView()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Reopened windows come back through here, so never stack a second timer.
        refreshTimer?.invalidate()
        refresh()
        // Permissions are granted in System Settings, in another app -- polling
        // is how the window notices.
        // `.common` rather than `scheduledTimer`'s default mode: "설정" is now
        // usually reached from the status menu, and a `.default`-only timer stalls
        // for as long as a menu is tracking or a window is being dragged.
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    var isVisible: Bool { window.isVisible }

    func bringToFront() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Closing this window does not end the app: the widget outlives it, and the
    /// widget's menu is how the window comes back.
    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// Whether launching the app needs to put this window in front of anyone.
    /// Only that -- an open window is never closed on its own. Watching the last
    /// dot turn green and then having the window vanish reads as a glitch, and
    /// there is nothing gained by taking it away before it is in the way.
    ///
    /// Claude Code is deliberately not part of the test: it is optional, and
    /// waiting on it would greet someone who never wants it with this window on
    /// every launch.
    static func isEverythingReady() -> Bool {
        InstallLocation.detect(bundlePath: Bundle.main.bundleURL.path) == .applications
            && SystemTrustChecker().isProcessTrusted()
            && CGPreflightScreenCaptureAccess()
    }

    // MARK: - Layout

    private func makeContentView() -> NSView {
        buildChecklistGroup()
        buildReadyGroup()
        buildDetailsGroup()

        // `llmRow` stays out of "자세히" on purpose: it is the thing that answers,
        // so a window that says 준비 완료 while it is unreachable would let someone
        // find out by asking a question and getting an error. `wikiRow` keeps its
        // place beside it, untouched.
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 14
        rootStack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20)
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        for view in [readyGroup, checklistGroup, llmRow, wikiRow, disclosureRow(), detailsGroup] {
            rootStack.addArrangedSubview(view)
        }

        container.addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: container.topAnchor),
            rootStack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor)
        ])
        return container
    }

    private func buildChecklistGroup() {
        let heading = NSTextField(labelWithString: SetupCopy.checklistHeading)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)

        checklistGroup.orientation = .vertical
        checklistGroup.alignment = .leading
        checklistGroup.spacing = 14
        for view in [heading, locationRow, accessibilityRow, screenRow] {
            checklistGroup.addArrangedSubview(view)
        }
    }

    private func buildReadyGroup() {
        let title = NSTextField(labelWithString: SetupCopy.readyTitle)
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        readyGroup.orientation = .vertical
        readyGroup.alignment = .leading
        readyGroup.spacing = 6
        readyGroup.addArrangedSubview(title)
        for step in SetupCopy.readySteps {
            readyGroup.addArrangedSubview(bodyLabel(step, color: .labelColor))
        }
        readyGroup.addArrangedSubview(bodyLabel(SetupCopy.readyExample, color: .tertiaryLabelColor))

        let ask = NSButton(title: SetupCopy.readyButton, target: self, action: #selector(askNow))
        ask.bezelStyle = .rounded
        ask.keyEquivalent = "\r"
        askButton = ask
        readyGroup.addArrangedSubview(ask)

        readyGroup.addArrangedSubview(
            bodyLabel(SetupCopy.readyFooter, color: .secondaryLabelColor)
        )
    }

    private func buildDetailsGroup() {
        detailsGrid.orientation = .vertical
        detailsGrid.alignment = .leading
        detailsGrid.spacing = 3

        let copy = NSButton(
            title: SetupCopy.detailsCopyButton, target: self, action: #selector(copyDiagnostics)
        )
        copy.bezelStyle = .rounded
        copy.controlSize = .small

        let resources = NSButton(
            title: SetupCopy.detailsResourceButton, target: self, action: #selector(showResources)
        )
        resources.bezelStyle = .rounded
        resources.controlSize = .small

        // Side by side: both act on the same table above them, and stacking them
        // would grow a window that already resizes itself on a 1.5-second timer.
        let buttons = NSStackView(views: [copy, resources])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8

        detailsGroup.orientation = .vertical
        detailsGroup.alignment = .leading
        detailsGroup.spacing = 10
        for view in [detailsGrid, buttons] {
            detailsGroup.addArrangedSubview(view)
        }
    }

    private func disclosureRow() -> NSView {
        disclosure.bezelStyle = .disclosure
        disclosure.setButtonType(.pushOnPushOff)
        disclosure.title = ""
        disclosure.state = detailsExpanded ? .on : .off
        disclosure.target = self
        disclosure.action = #selector(toggleDetails)

        // The word is clickable too -- a bare triangle is a small target and reads
        // as decoration.
        let label = NSButton(
            title: SetupCopy.detailsToggle, target: self, action: #selector(toggleDetails)
        )
        label.bezelStyle = .inline
        label.isBordered = false
        label.contentTintColor = .secondaryLabelColor

        let row = NSStackView(views: [disclosure, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 2
        return row
    }

    private func bodyLabel(_ text: String, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = color
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 3
        label.preferredMaxLayoutWidth = Self.contentWidth - 40
        return label
    }

    // MARK: - State

    private func refresh() {
        let location = InstallLocation.detect(bundlePath: bundlePath)
        apply(SetupCopy.location(location), to: locationRow) { [weak self] in
            self?.moveToApplications()
        }

        let trusted = SystemTrustChecker().isProcessTrusted()
        apply(SetupCopy.accessibility(granted: trusted), to: accessibilityRow) { [weak self] in
            self?.requestAccessibility()
        }

        let screenRecording = CGPreflightScreenCaptureAccess()
        apply(SetupCopy.screenRecording(granted: screenRecording), to: screenRow) { [weak self] in
            self?.requestScreenRecording()
        }

        refreshLLMRow()
        refreshWikiRow()
        refreshDetailsGrid()
        applyMode()
        syncWindowHeight()
    }

    /// A row whose copy says there is no button gets no action either -- that is
    /// what keeps "허용됨" from staying clickable.
    private func apply(
        _ content: SetupCopy.RowContent, to row: SetupRow, action: @escaping () -> Void
    ) {
        row.update(
            state: content.state,
            detail: content.detail,
            button: content.button,
            action: content.button == nil ? nil : action
        )
    }

    // MARK: - Mode

    /// Which face the window is showing. Re-derived on every tick, so revoking a
    /// permission in System Settings flips it back to the checklist within 1.5s
    /// rather than lying until the next launch.
    private func applyMode() {
        let ready = Self.isEverythingReady()
        readyGroup.isHidden = !ready
        checklistGroup.isHidden = ready
        askButton?.isHidden = onAsk == nil
        detailsGroup.isHidden = !detailsExpanded

        if ready && !wasReady {
            onBecameReady?()
        }
        wasReady = ready
    }

    /// Follows the content, which changes when the mode flips or 자세히 opens.
    ///
    /// The delta gate is what makes this safe on a 1.5-second timer: without it
    /// the window re-frames itself constantly, which fights a drag and reads as a
    /// flicker. Never animated, and pinned by its top-left corner -- `NSWindow`
    /// origins are bottom-left, so resizing without this makes the title bar jump.
    private func syncWindowHeight() {
        container.layoutSubtreeIfNeeded()
        let target = max(rootStack.fittingSize.height, Self.minContentHeight)
        guard abs(target - window.contentLayoutRect.height) > 0.5 else { return }
        var frame = window.frameRect(
            forContentRect: NSRect(x: 0, y: 0, width: Self.contentWidth, height: target)
        )
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true, animate: false)
    }

    private func refreshDetailsGrid() {
        guard detailsExpanded else { return }
        let rows = detailsRows()
        detailsGrid.arrangedSubviews.forEach {
            detailsGrid.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for row in rows {
            let label = NSTextField(labelWithString: "\(row.label)   \(row.value)")
            label.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            label.textColor = .tertiaryLabelColor
            label.lineBreakMode = .byTruncatingMiddle
            label.cell?.truncatesLastVisibleLine = true
            // An explicit width, not just `preferredMaxLayoutWidth`: a single-line
            // label's intrinsic width otherwise wins and a long path runs off the
            // side of a fixed-width window instead of ellipsizing. "정보 복사" is
            // how the untruncated value gets out.
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.widthAnchor.constraint(equalToConstant: Self.contentWidth - 40).isActive = true
            detailsGrid.addArrangedSubview(label)
        }
    }

    private func detailsRows() -> [(label: String, value: String)] {
        let model: String?
        if case .success(let status) = llmStatus {
            model = status.model.map(Self.shortModelName)
        } else {
            model = nil
        }
        return SetupCopy.details(
            version: TrolleyVersion.display,
            uptime: SetupCopy.uptime(Date().timeIntervalSince(launchedAt)),
            path: executablePath,
            model: model,
            address: LocalLLMSettings.baseURLString,
        )
    }

    @objc private func toggleDetails() {
        detailsExpanded.toggle()
        disclosure.state = detailsExpanded ? .on : .off
        UserDefaults.standard.set(detailsExpanded, forKey: Self.detailsKey)
        refreshDetailsGrid()
        detailsGroup.isHidden = !detailsExpanded
        syncWindowHeight()
    }

    @objc private func askNow() {
        onAsk?()
    }

    @objc private func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            SetupCopy.diagnostics(detailsRows()), forType: .string
        )
    }

    /// A snapshot of what the server said, not a fresh question to it.
    ///
    /// `llmStatus` is refilled by the same 5-second-throttled probe that draws the
    /// row's dot, so what this shows is at most five seconds old. Firing a new
    /// request here instead would leave the button doing nothing visible until the
    /// reply landed -- no other button in this window behaves that way, and the
    /// numbers are not moving fast enough to be worth the wait.
    @objc private func showResources() {
        let message: String
        switch llmStatus {
        case .success(let status):
            message = SetupCopy.diagnostics(resourceRows(status))
        case .failure(let failure):
            message = SetupCopy.resourcesUnavailable(failure.localizedDescription)
        case .none:
            message = SetupCopy.resourcesUnavailable("아직 확인 중입니다. 잠시 뒤 다시 눌러 주세요.")
        }
        present(title: SetupCopy.resourceSheetTitle, message: message, critical: false)
    }

    /// The wiki share is counted here rather than on the server because the server
    /// never sees it as a separate thing -- the digest rides inside the question's
    /// one `content` string. A wiki that is off contributes nothing, which is not
    /// the same as a wiki whose folder could not be read; both come back nil and
    /// the copy says the room is all still there.
    private func resourceRows(
        _ status: LocalLLMClient.Status
    ) -> [(label: String, value: String)] {
        let wikiTokens: Int?
        // Only 직접 지정 spends context up front. Under 자동 the wiki costs a tool result
        // when it is used and nothing when it is not, so counting it here as a slice of
        // the window taken would be reporting a reservation nobody made.
        if WikiSettings.mode == .manual, let digest = WikiContext.shared.currentDigest() {
            wikiTokens = WikiDigestRenderer.approximateTokens(characters: digest.characters)
        } else {
            wikiTokens = nil
        }
        return SetupCopy.resources(
            busy: status.busy,
            waiting: status.waiting,
            maxQueueDepth: status.maxQueueDepth,
            maxContext: status.maxContext,
            hardContextLimit: status.hardContextLimit,
            wikiTokens: wikiTokens,
            lastPeakGB: status.lastPeakGB,
            totalJobs: status.totalJobs,
            remoteActive: status.remoteActive,
            remoteLimit: status.remoteLimit
        )
    }

    // MARK: - LLM 위키

    /// The team's markdown vault, read from a local folder and summarised in front of
    /// whatever is typed into the prompt box. Optional like Claude Code and the model
    /// address: trolley automates apps with or without it, so an unset folder is grey.
    private func refreshWikiRow() {
        checkWikiIfDue()
        wikiRow.update(
            state: wikiState,
            detail: wikiSummary ?? "확인 중…",
            button: "설정",
            action: { [weak self] in self?.wikiSettings.show() }
        )
    }

    private func checkWikiIfDue() {
        if let last = lastWikiCheck, Date().timeIntervalSince(last) < 5 { return }
        lastWikiCheck = Date()

        let path = WikiSettings.rootPath
        let mode = WikiSettings.mode
        guard mode != .off else {
            wikiState = .optional
            // Two different silences, and saying the same thing about both is what sent
            // someone hunting for a switch. Off with a wiki sitting right there is a
            // choice that was made; off without one is nothing to choose about yet.
            wikiSummary = WikiSettings.rootIsReadable
                ? "끔으로 설정돼 있습니다. 설정에서 자동을 고르면 다시 켜집니다 — \(path)"
                : "읽을 수 있는 위키 폴더가 없습니다. 폴더를 지정하면 바로 켜집니다 — \(path)"
            return
        }
        guard let digest = WikiContext.shared.currentDigest() else {
            // A folder that cannot be read is orange, not red: a missing wiki never
            // stops a question from being asked, it just goes out bare.
            wikiState = .actionNeeded
            switch WikiContext.shared.lastFailure {
            case .denied:
                // Not the same as "not found", and saying so matters -- the vault sits
                // under ~/Desktop, which macOS gates even for an unsandboxed app, and
                // "없습니다" sends someone hunting for a folder that never moved.
                wikiSummary = "폴더에 접근할 수 없습니다. 설정에서 폴더를 다시 고르면 권한이 붙습니다 — \(path)"
            case .missing:
                wikiSummary = "폴더를 찾을 수 없습니다 — \(path)"
            case .noRoot, .none:
                wikiSummary = "폴더가 지정되지 않았습니다."
            }
            return
        }

        wikiState = .done
        // Under 자동 the digest was still worth building -- it is how this row knows the
        // folder reads at all -- but its size is not what the wiki costs, so the row
        // reports what the mode means instead of a token count nothing will spend.
        guard mode == .manual else {
            // Whoever never opened the options window did not turn this on, and a row
            // that reads 자동 without saying so leaves them looking for the moment they
            // did. The folder being there is the whole reason.
            let why = WikiSettings.modeWasDetected ? "자동 (폴더가 있어 켜짐)" : "자동"
            wikiSummary = why + " — trolley 가 질문에 맞는 문서를 직접 찾습니다 — " + path
            return
        }
        let tokens = WikiDigestRenderer.approximateTokens(characters: digest.characters)
        var detail = "\(digest.matched)/\(digest.total)건 · 약 \(tokens)토큰"
        detail += " (96K의 \(String(format: "%.1f", Double(tokens) / 960))%)"
        if digest.wasTruncated { detail += " · \(digest.total - digest.matched)건 생략" }
        wikiSummary = detail + " — " + path
    }

    // MARK: - Local LLM

    /// The address the widget's prompt box talks to. Optional like Claude Code:
    /// trolley automates apps whether or not a model is reachable, so an
    /// unreachable server is grey, not red.
    private func refreshLLMRow() {
        // The model id, the address and the queue depth used to be in this line.
        // They are the exact vocabulary this change is trying to get out of a
        // first-time user's way, so they moved to "자세히"; what stays is whether
        // asking will work.
        let reachable: Bool?
        switch llmStatus {
        case .success: reachable = true
        case .failure: reachable = false
        case .none: reachable = nil
        }
        apply(SetupCopy.llm(reachable: reachable), to: llmRow) { [weak self] in
            self?.editLLMAddress()
        }
        checkLLMIfDue()
    }

    private func checkLLMIfDue() {
        guard !llmCheckInFlight else { return }
        if let last = lastLLMCheck, Date().timeIntervalSince(last) < 5 { return }
        guard let config = LocalLLMSettings.makeConfig() else {
            llmStatus = .failure(.unreachable("주소가 비어 있습니다"))
            return
        }
        llmCheckInFlight = true
        lastLLMCheck = Date()
        LocalLLMClient(config: config).status { [weak self] result in
            guard let self else { return }
            self.llmCheckInFlight = false
            self.llmStatus = result
            self.refreshLLMRow()
        }
    }

    /// `mlx-community/diffusiongemma-26B-A4B-it-4bit` is most of the row's width
    /// and none of it is the part that identifies the model.
    private static func shortModelName(_ full: String) -> String {
        full.split(separator: "/").last.map(String.init) ?? full
    }

    private func editLLMAddress() {
        let alert = NSAlert()
        alert.messageText = SetupCopy.llmSheetTitle
        alert.informativeText = SetupCopy.llmSheetBody
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = LocalLLMSettings.baseURLString
        field.placeholderString = LocalLLMSettings.fallbackBaseURL
        alert.accessoryView = field
        alert.addButton(withTitle: "저장")
        alert.addButton(withTitle: "취소")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let entered = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !entered.isEmpty, LocalLLMSettings.normalize(entered) == nil {
                self.present(title: "주소를 이해하지 못했습니다", message: entered, critical: true)
                return
            }
            LocalLLMSettings.baseURLString = entered
            // Re-probe now rather than on the next tick: the point of pressing
            // save is finding out whether the new address works.
            self.llmStatus = nil
            self.lastLLMCheck = nil
            self.refreshLLMRow()
        }
        // The sheet opens with the field ready to be replaced wholesale, which
        // is what pasting a new URL wants.
        DispatchQueue.main.async {
            field.selectText(nil)
        }
    }

    /// Looked up once and remembered -- including the answer "not installed", so
    /// a missing CLI does not spawn a login shell on every tick.
    private func locateClaude() -> String? {
        if let cached = claudePath { return cached }
        let found = ClaudeCLI.locate(shellLookup: Self.shellLookupClaude)
        claudePath = .some(found)
        return found
    }

    /// The user's login shell owns the real PATH; a fixed list of install
    /// locations cannot keep up with npm prefixes and version managers.
    private static func shellLookupClaude() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let result = run(shell, ["-lic", "command -v claude"], timeout: 5)
        return result.status == 0 ? result.output : nil
    }

    // MARK: - Actions

    /// Copies rather than moves: the source is usually a read-only disk image.
    private func moveToApplications() {
        let source = Bundle.main.bundleURL
        let destination = URL(fileURLWithPath: "/Applications/\(source.lastPathComponent)")
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            present(title: "옮기지 못했습니다", message: error.localizedDescription, critical: true)
            return
        }
        // Hand off to the copy and step aside, so what stays open is the one at
        // the fixed path -- the path every grant below will be recorded against.
        NSWorkspace.shared.openApplication(at: destination, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    private func requestAccessibility() {
        _ = AccessibilityPermission.ensureTrusted(checker: SystemTrustChecker(), prompt: true)
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private func requestScreenRecording() {
        // Prompts the first time only; afterwards the switch lives in Settings.
        _ = CGRequestScreenCaptureAccess()
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }



    // MARK: - Helpers

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    private func present(title: String, message: String, critical: Bool) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = critical ? .critical : .informational
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    /// - Parameter timeout: seconds before the process is killed. An interactive
    ///   login shell is the reason this exists -- a chatty or prompting rc file
    ///   would otherwise hang the lookup forever.
    private static func run(
        _ launchPath: String,
        _ arguments: [String],
        timeout: TimeInterval? = nil
    ) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        if let timeout {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { process.terminate() }
            }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
