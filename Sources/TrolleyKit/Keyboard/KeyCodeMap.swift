import CoreGraphics

public enum KeyCodeMap {
    public static let byName: [String: CGKeyCode] = [
        "return": 36,
        "enter": 36,
        "tab": 48,
        "space": 49,
        "escape": 53,
        "delete": 51,
        "forwarddelete": 117,
        "left": 123,
        "right": 124,
        "down": 125,
        "up": 126,
        "home": 115,
        "end": 119,
        "pageup": 116,
        "pagedown": 121,
        "cmd": 55,
        "command": 55,
        "shift": 56,
        "option": 58,
        "alt": 58,
        "control": 59,
        "ctrl": 59
    ]

    public static let modifierFlags: [String: CGEventFlags] = [
        "cmd": .maskCommand,
        "command": .maskCommand,
        "shift": .maskShift,
        "option": .maskAlternate,
        "alt": .maskAlternate,
        "control": .maskControl,
        "ctrl": .maskControl
    ]

    public static func keyCode(forName name: String) -> CGKeyCode? {
        byName[name.lowercased()]
    }

    /// Parses combos like "cmd+a" or "shift+return" into a base key code plus
    /// combined modifier flags.
    public static func parseCombo(_ combo: String) -> (key: CGKeyCode, flags: CGEventFlags)? {
        let parts = combo.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let last = parts.last, let key = keyCode(forName: String(last)) else { return nil }

        var flags: CGEventFlags = []
        for modifierName in parts.dropLast() {
            guard let flag = modifierFlags[modifierName.lowercased()] else { return nil }
            flags.insert(flag)
        }
        return (key, flags)
    }
}
