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

    /// Defaults to on: unlike the terminal and Desktop methods, which only ever
    /// act on a window trolley itself just opened, orca can deliver into a pane
    /// someone else is looking at. Confirming first is the same discipline
    /// copy-chat's own dry-run step exists for.
    public static var orcaConfirmBeforeSend: Bool {
        get { defaults.object(forKey: orcaConfirmKey) as? Bool ?? true }
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
