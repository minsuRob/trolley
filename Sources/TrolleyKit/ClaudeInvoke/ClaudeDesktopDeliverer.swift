import CoreGraphics
import Foundation

/// Pastes a prompt into the Claude Desktop app's composer.
///
/// Claude Desktop is Electron, and its accessibility tree stays empty even
/// under `AXManualAccessibility` -- `dump-tree` against
/// `com.anthropic.claudefordesktop` shows nothing past an `AXWebArea` with
/// zero children, the same limitation the README documents for
/// Chromium/Electron content in general. A coordinate click *does* reach a
/// real text area there (confirmed against a live window with
/// `AXUIElementCopyElementAtPosition`, the mechanism behind a raw
/// click-at-point), so delivery here is: activate, click a point near the
/// window's bottom-center to focus the composer, then paste with no element
/// targeted -- the same "best effort, can't verify" path
/// `TypeCommand`/`InteractCommands.swift` already uses for arbitrary apps.
///
/// Enter is not pressed unless `desktopAutoSubmit` says to: a paste that
/// cannot be read back is not a paste this module can confirm landed in the
/// composer rather than, say, a channel switcher.
public struct ClaudeDesktopDeliverer: ClaudeInvokeDeliverer {
    public let method: ClaudeInvokeMethod = .desktop

    public static let bundleID = "com.anthropic.claudefordesktop"
    /// How far above the window's bottom edge the composer sits, measured
    /// against a live 1200x800 window.
    static let composerInsetFromBottom: CGFloat = 60

    private let launcher: AppLauncher
    private let locator: RunningAppLocating
    private let mouse: MouseAnimator
    private let textEntry: TextEntryEngine
    private let keyPoster: () -> KeyEventPosting
    private let sleeper: (TimeInterval) -> Void
    private let autoSubmit: () -> Bool
    private let trust: () -> Bool
    private let windowFrame: (pid_t) -> (origin: CGPoint, size: CGSize)?

    public init(
        launcher: AppLauncher = AppLauncher(),
        locator: RunningAppLocating = WorkspaceAppLocator(),
        mouse: MouseAnimator = MouseAnimator(poster: CGMouseEventPoster()),
        textEntry: TextEntryEngine = TextEntryEngine(
            makePoster: { CGKeyboardSynthesizer(targetPid: $0) },
            clipboard: NSPasteboardClipboard(),
            inputSource: TISInputSourceController()
        ),
        keyPoster: @escaping () -> KeyEventPosting = { CGKeyboardSynthesizer() },
        sleeper: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        autoSubmit: @escaping () -> Bool = { ClaudeInvokeSettings.desktopAutoSubmit },
        trust: @escaping () -> Bool = {
            AccessibilityPermission.ensureTrusted(checker: SystemTrustChecker(), prompt: true)
        },
        windowFrame: @escaping (pid_t) -> (origin: CGPoint, size: CGSize)? = ClaudeDesktopDeliverer.frontWindowFrame
    ) {
        self.launcher = launcher
        self.locator = locator
        self.mouse = mouse
        self.textEntry = textEntry
        self.keyPoster = keyPoster
        self.sleeper = sleeper
        self.autoSubmit = autoSubmit
        self.trust = trust
        self.windowFrame = windowFrame
    }

    public func deliver(prompt: String, confirm: @escaping (String) -> Bool) -> ClaudeInvokeResult {
        guard trust() else {
            return ClaudeInvokeResult(method: .desktop, success: false, message: "손쉬운 사용 권한이 필요합니다.")
        }
        do {
            let pid = try launcher.launchOrActivate(bundleID: Self.bundleID, locator: locator)
            sleeper(0.6)
            guard let frame = windowFrame(pid) else {
                return ClaudeInvokeResult(method: .desktop, success: false, message: "Claude 창을 찾지 못했습니다.")
            }
            let point = CGPoint(
                x: frame.origin.x + frame.size.width / 2,
                y: frame.origin.y + frame.size.height - Self.composerInsetFromBottom
            )
            mouse.animatedClick(to: point)
            sleeper(0.3)
            _ = try textEntry.insert(prompt, method: .paste, element: nil, targetPid: pid)
            let sendsEnter = autoSubmit()
            if sendsEnter {
                sleeper(0.2)
                KeyboardActions.press("return", modifiers: [], using: keyPoster())
            }
            return ClaudeInvokeResult(
                method: .desktop, success: true,
                message: sendsEnter
                    ? "Claude 앱에 붙여넣고 전송했습니다."
                    : "Claude 앱에 붙여넣었습니다 — 직접 Enter 를 눌러 보내세요."
            )
        } catch {
            return ClaudeInvokeResult(
                method: .desktop, success: false, message: "Claude 앱을 열지 못했습니다 — \(error)"
            )
        }
    }

    /// The frontmost app-level window's position and size. Even though the
    /// web content inside is opaque, the window frame itself is ordinary AX
    /// (`AXWindow` shows up under the app root in `dump-tree`), so this needs
    /// nothing beyond `children()` and the two frame attributes.
    public static func frontWindowFrame(pid: pid_t) -> (origin: CGPoint, size: CGSize)? {
        let root = SystemAXElement.application(pid: pid)
        guard let window = root.children().first(where: { $0.stringAttribute(AXAttr.role) == "AXWindow" }),
              let position = window.pointAttribute(AXAttr.position),
              let size = window.sizeAttribute(AXAttr.size)
        else { return nil }
        return (position, size)
    }
}
