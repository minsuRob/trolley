import Foundation

/// Opens a fresh Terminal window, runs `claude`, and pastes the prompt into
/// the session once it has started.
///
/// The prompt is never interpolated into a shell command line -- it is pasted
/// into the CLI's own prompt box after it starts, the same way a person would
/// type it. That sidesteps quoting entirely: nothing here has to worry about
/// a prompt that contains quotes, newlines, or a stray `$(...)`.
public struct TerminalClaudeDeliverer: ClaudeInvokeDeliverer {
    public let method: ClaudeInvokeMethod = .terminal

    public static let bundleID = "com.apple.Terminal"

    private let claudeLocate: () -> String?
    private let launcher: AppLauncher
    private let locator: RunningAppLocating
    private let keyPoster: () -> KeyEventPosting
    private let textEntry: TextEntryEngine
    private let sleeper: (TimeInterval) -> Void
    private let trust: () -> Bool

    public init(
        claudeLocate: @escaping () -> String? = { ClaudeCLI.locate() },
        launcher: AppLauncher = AppLauncher(),
        locator: RunningAppLocating = WorkspaceAppLocator(),
        keyPoster: @escaping () -> KeyEventPosting = { CGKeyboardSynthesizer() },
        textEntry: TextEntryEngine = TextEntryEngine(
            makePoster: { CGKeyboardSynthesizer(targetPid: $0) },
            clipboard: NSPasteboardClipboard(),
            inputSource: TISInputSourceController()
        ),
        sleeper: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        trust: @escaping () -> Bool = {
            AccessibilityPermission.ensureTrusted(checker: SystemTrustChecker(), prompt: true)
        }
    ) {
        self.claudeLocate = claudeLocate
        self.launcher = launcher
        self.locator = locator
        self.keyPoster = keyPoster
        self.textEntry = textEntry
        self.sleeper = sleeper
        self.trust = trust
    }

    public func deliver(prompt: String, confirm: @escaping (String) -> Bool) -> ClaudeInvokeResult {
        guard let claudePath = claudeLocate() else {
            return ClaudeInvokeResult(
                method: .terminal, success: false,
                message: "claude 명령을 찾지 못했습니다."
            )
        }
        guard trust() else {
            return ClaudeInvokeResult(
                method: .terminal, success: false, message: "손쉬운 사용 권한이 필요합니다."
            )
        }
        do {
            let pid = try launcher.launchOrActivate(bundleID: Self.bundleID, locator: locator)
            sleeper(0.5)
            // A fresh window rather than whatever Terminal already had open --
            // an existing window may be mid-command, or someone's own shell.
            KeyboardActions.press("n", modifiers: ["cmd"], using: keyPoster())
            sleeper(0.6)
            _ = try textEntry.insert(claudePath, method: .paste, element: nil, targetPid: pid)
            KeyboardActions.press("return", modifiers: [], using: keyPoster())
            // The CLI's own startup (model banner, MCP handshake) before its
            // prompt box exists to paste into.
            sleeper(1.4)
            _ = try textEntry.insert(prompt, method: .paste, element: nil, targetPid: pid)
            KeyboardActions.press("return", modifiers: [], using: keyPoster())
            return ClaudeInvokeResult(method: .terminal, success: true, message: "터미널에서 claude 를 호출했습니다.")
        } catch {
            return ClaudeInvokeResult(
                method: .terminal, success: false, message: "터미널을 열지 못했습니다 — \(error)"
            )
        }
    }
}
