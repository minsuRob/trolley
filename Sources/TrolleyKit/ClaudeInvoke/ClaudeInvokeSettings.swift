import Foundation

/// Which of the three ways to reach a real Claude are turned on, and the knobs
/// specific to each -- same shape as `WikiSettings`: static properties over
/// `UserDefaults.standard`, keys under `trolley.claudeInvoke.`.
///
/// The three checkboxes (터미널/orca/Desktop) are written the moment they are
/// toggled, like the wiki window's toolbar -- there is no 저장 button for them,
/// because a person picking methods while about to send is not filling out a
/// form. The per-method options below live in the settings window instead,
/// behind its own 저장, since those are tuned once and forgotten.
public enum ClaudeInvokeSettings {
    public static let terminalEnabledKey = "trolley.claudeInvoke.terminal"
    public static let orcaEnabledKey = "trolley.claudeInvoke.orca"
    public static let desktopEnabledKey = "trolley.claudeInvoke.desktop"
    public static let attachWikiContextKey = "trolley.claudeInvoke.attachContext"
    public static let orcaConfirmKey = "trolley.claudeInvoke.orca.confirm"
    public static let orcaTargetHandleKey = "trolley.claudeInvoke.orca.targetHandle"
    public static let desktopAutoSubmitKey = "trolley.claudeInvoke.desktop.autoSubmit"

    private static var defaults: UserDefaults { .standard }

    public static var terminalEnabled: Bool {
        get { defaults.bool(forKey: terminalEnabledKey) }
        set { defaults.set(newValue, forKey: terminalEnabledKey) }
    }

    public static var orcaEnabled: Bool {
        get { defaults.bool(forKey: orcaEnabledKey) }
        set { defaults.set(newValue, forKey: orcaEnabledKey) }
    }

    public static var desktopEnabled: Bool {
        get { defaults.bool(forKey: desktopEnabledKey) }
        set { defaults.set(newValue, forKey: desktopEnabledKey) }
    }

    /// Defaults to on: a page someone has open is almost always what "호출" is
    /// about, and the person who does not want it is one click from the
    /// checkbox that turns it off -- unlike the wiki prompt's own context
    /// attach, this has no per-conversation replay cost to worry about, since
    /// each 호출 is a single fire-and-forget message.
    public static var attachWikiContext: Bool {
        get { defaults.object(forKey: attachWikiContextKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: attachWikiContextKey) }
    }

    /// Defaults to off: 사용자가 매번 뜨는 확인창을 원치 않는다고 명시적으로 요청했다.
    /// orca 대상은 어차피 이 사람 자신의 터미널 pane 이라 잘못 보낼 위험이 낮다고 판단한
    /// 것이므로, 그래도 확인이 필요하면 설정 창의 "보내기 전 확인" 체크박스로 다시 켤 수 있다.
    public static var orcaConfirmBeforeSend: Bool {
        get { defaults.object(forKey: orcaConfirmKey) as? Bool ?? false }
        set { defaults.set(newValue, forKey: orcaConfirmKey) }
    }

    /// An orca terminal handle to always target, or "" to pick the first idle
    /// claude pane automatically.
    public static var orcaTargetHandle: String {
        get { defaults.string(forKey: orcaTargetHandleKey) ?? "" }
        set {
            let cleaned = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty {
                defaults.removeObject(forKey: orcaTargetHandleKey)
            } else {
                defaults.set(cleaned, forKey: orcaTargetHandleKey)
            }
        }
    }

    /// Off by default: a paste into Claude Desktop's composer cannot be read
    /// back to confirm it landed where intended (its AX tree does not expose
    /// the composer -- see `ClaudeDesktopDeliverer`), so pressing Enter for
    /// someone is a guess this module should not make unless asked to.
    public static var desktopAutoSubmit: Bool {
        get { defaults.bool(forKey: desktopAutoSubmitKey) }
        set { defaults.set(newValue, forKey: desktopAutoSubmitKey) }
    }
}
