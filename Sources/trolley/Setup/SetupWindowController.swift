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
    private let locationRow = SetupRow(title: "설치 위치")
    private let accessibilityRow = SetupRow(title: "손쉬운 사용")
    private let screenRow = SetupRow(title: "화면 기록")
    private let mcpRow = SetupRow(title: "Claude Code 연결")
    private let pathLabel = NSTextField(labelWithString: "")
    private var refreshTimer: Timer?

    /// Both cached because they shell out; the timer must not run them twice a
    /// second. Re-checked on a slower beat so registering from a terminal still
    /// turns the row green without relaunching.
    private var mcpRegistered: Bool?
    private var lastMCPCheck: Date?
    private var mcpCheckInFlight = false
    private var claudePath: String??

    private var executablePath: String { AccessibilityPermission.currentExecutablePath() }
    private var bundlePath: String { Bundle.main.bundleURL.path }

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 330),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = "trolley \(TrolleyVersion.current)"
        window.delegate = self
        window.center()
        window.contentView = makeContentView()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refresh()
        // Permissions are granted in System Settings, in another app -- polling
        // is how the window notices.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        NSApp.terminate(nil)
    }

    // MARK: - Layout

    private func makeContentView() -> NSView {
        let heading = NSTextField(labelWithString: "위 세 가지가 준비되면 trolley는 동작합니다.")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)

        pathLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        pathLabel.textColor = .tertiaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle

        let stack = NSStackView(views: [
            heading, locationRow, accessibilityRow, screenRow, mcpRow, NSView(), pathLabel
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor)
        ])
        return container
    }

    // MARK: - State

    private func refresh() {
        pathLabel.stringValue = executablePath

        let location = InstallLocation.detect(bundlePath: bundlePath)
        switch location {
        case .applications:
            locationRow.update(state: .done, detail: "응용 프로그램 폴더에 설치됨", button: nil, action: nil)
        case .diskImage:
            locationRow.update(
                state: .blocked,
                detail: "디스크 이미지에서 실행 중입니다. 여기서 준 권한은 이미지를 꺼내면 사라집니다.",
                button: "Applications로 이동",
                action: { [weak self] in self?.moveToApplications() }
            )
        case .elsewhere:
            locationRow.update(
                state: .actionNeeded,
                detail: "응용 프로그램 폴더 밖입니다. 옮기면 경로가 고정돼 권한이 유지됩니다.",
                button: "Applications로 이동",
                action: { [weak self] in self?.moveToApplications() }
            )
        }

        let trusted = SystemTrustChecker().isProcessTrusted()
        accessibilityRow.update(
            state: trusted ? .done : .actionNeeded,
            detail: trusted ? "허용됨" : "AX 트리를 읽고 조작하려면 필요합니다.",
            button: trusted ? nil : "허용하기",
            action: trusted ? nil : { [weak self] in self?.requestAccessibility() }
        )

        let screenRecording = CGPreflightScreenCaptureAccess()
        screenRow.update(
            state: screenRecording ? .done : .actionNeeded,
            detail: screenRecording ? "허용됨" : "screenshot 툴에만 필요합니다. 없어도 나머지는 동작합니다.",
            button: screenRecording ? nil : "허용하기",
            action: screenRecording ? nil : { [weak self] in self?.requestScreenRecording() }
        )

        refreshMCPRow()
    }

    /// Optional by design: trolley works as a CLI without it, and someone who
    /// wants to connect Claude Code later should not be looking at a red dot in
    /// the meantime.
    private func refreshMCPRow() {
        guard let claude = locateClaude() else {
            mcpRow.update(
                state: .optional,
                detail: "선택 사항. claude 명령을 찾지 못했으니, 연결하려면 아래 명령을 터미널에서 실행하세요.",
                button: "명령 복사",
                action: { [weak self] in self?.copyManualCommand() }
            )
            return
        }
        if mcpRegistered == true {
            mcpRow.update(state: .done, detail: "MCP 서버로 등록됨 (user 스코프)", button: "다시 등록", action: { [weak self] in
                self?.registerMCP(claude: claude)
            })
        } else {
            mcpRow.update(
                state: .optional,
                detail: "선택 사항. 지금 연결해도 되고 나중에 이 창을 다시 열어도 됩니다.",
                button: "연결하기",
                action: { [weak self] in self?.registerMCP(claude: claude) }
            )
        }
        checkRegistrationIfDue(claude: claude)
    }

    /// Re-asks every few seconds rather than once per launch, so a registration
    /// made in a terminal shows up here without a relaunch.
    private func checkRegistrationIfDue(claude: String) {
        guard !mcpCheckInFlight else { return }
        if let last = lastMCPCheck, Date().timeIntervalSince(last) < 4 { return }
        mcpCheckInFlight = true
        lastMCPCheck = Date()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let listed = Self.run(claude, ["mcp", "list"])
            let registered = MCPRegistration.isRegistered(listOutput: listed.output)
            DispatchQueue.main.async {
                guard let self else { return }
                self.mcpCheckInFlight = false
                if self.mcpRegistered != registered {
                    self.mcpRegistered = registered
                    self.refreshMCPRow()
                }
            }
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

    private func registerMCP(claude: String) {
        let path = executablePath
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Replacing rather than adding twice: re-running after a move has to
            // overwrite the stale path, and `add` alone refuses.
            _ = Self.run(claude, MCPRegistration.removeArguments())
            let result = Self.run(claude, MCPRegistration.addArguments(executablePath: path))
            DispatchQueue.main.async {
                guard let self else { return }
                if result.status == 0 {
                    self.mcpRegistered = true
                    self.refreshMCPRow()
                } else {
                    self.present(
                        title: "등록에 실패했습니다",
                        message: result.output.isEmpty ? "claude가 \(result.status)로 끝났습니다." : result.output,
                        critical: true
                    )
                }
            }
        }
    }

    private func copyManualCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(MCPRegistration.manualCommand(executablePath: executablePath), forType: .string)
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
