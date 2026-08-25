import ApplicationServices

/// Centralizes the AX attribute/action string constants this tool actually uses.
public enum AXAttr {
    public static let role = kAXRoleAttribute as String
    public static let title = kAXTitleAttribute as String
    public static let value = kAXValueAttribute as String
    public static let description = kAXDescriptionAttribute as String
    public static let children = kAXChildrenAttribute as String
    public static let focused = kAXFocusedAttribute as String
    public static let position = kAXPositionAttribute as String
    public static let size = kAXSizeAttribute as String

    /// Chromium/Electron-specific attribute (not a stock kAX* constant) that
    /// forces the accessibility tree to fully populate instead of staying lazy.
    public static let manualAccessibility = "AXManualAccessibility"
}

public enum AXAction {
    public static let press = kAXPressAction as String
    public static let raise = kAXRaiseAction as String
}
