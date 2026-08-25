import CoreGraphics

public enum KeyCodeMap {
    /// Carbon virtual key codes for the letter/digit/punctuation keys, which are
    /// what shortcuts like cmd+n, cmd+a and cmd+s are built from -- without
    /// these, `press` could only send special keys, so no shortcut involving a
    /// character was expressible at all.
    ///
    /// These identify physical key *positions* on a US ANSI layout, which is
    /// what macOS matches shortcuts against, so cmd+n stays "new" regardless of
    /// the active input source. To enter characters as text, see
    /// `asciiKeyStroke(for:)` and `KeyboardActions.typeASCII`, which press these
    /// same positions and therefore need an ASCII-capable input source selected.
    static let characterKeys: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "equal": 24, "9": 25, "7": 26, "minus": 27, "8": 28, "0": 29,
        "rightbracket": 30, "o": 31, "u": 32, "leftbracket": 33, "i": 34, "p": 35,
        "l": 37, "j": 38, "quote": 39, "k": 40, "semicolon": 41, "backslash": 42,
        "comma": 43, "slash": 44, "n": 45, "m": 46, "period": 47, "grave": 50,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111
    ]

    public static let byName: [String: CGKeyCode] = characterKeys.merging([
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
    ]) { character, _ in character }

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

    /// The US-ANSI key position (and whether shift is held) that produces this
    /// character, or nil if no single keystroke does.
    ///
    /// Only printable ASCII maps: these are physical positions, so what actually
    /// appears depends on the active input source. Callers must select an
    /// ASCII-capable source first -- with the Korean 2-Set IME active, pressing
    /// the h and k positions produces "ㅘ", not "hk".
    public static func asciiKeyStroke(for character: Character) -> (key: CGKeyCode, shift: Bool)? {
        switch character {
        case " ": return (49, false)
        case "\n", "\r": return (36, false)
        case "\t": return (48, false)
        default: break
        }

        if let unshifted = characterKeys[String(character)] {
            return (unshifted, false)
        }
        if character.isUppercase, let lower = characterKeys[character.lowercased()] {
            return (lower, true)
        }
        if let named = punctuationKeyNames[character] {
            return characterKeys[named.name].map { ($0, named.shift) }
        }
        return nil
    }

    /// Punctuation by the name its key position carries in `characterKeys`, plus
    /// whether shift is needed. The shifted digits are the easy ones to get
    /// wrong, because the digit row is not in numeric key-code order.
    private static let punctuationKeyNames: [Character: (name: String, shift: Bool)] = [
        "-": ("minus", false), "_": ("minus", true),
        "=": ("equal", false), "+": ("equal", true),
        "[": ("leftbracket", false), "{": ("leftbracket", true),
        "]": ("rightbracket", false), "}": ("rightbracket", true),
        "\\": ("backslash", false), "|": ("backslash", true),
        ";": ("semicolon", false), ":": ("semicolon", true),
        "'": ("quote", false), "\"": ("quote", true),
        ",": ("comma", false), "<": ("comma", true),
        ".": ("period", false), ">": ("period", true),
        "/": ("slash", false), "?": ("slash", true),
        "`": ("grave", false), "~": ("grave", true),
        "!": ("1", true), "@": ("2", true), "#": ("3", true), "$": ("4", true),
        "%": ("5", true), "^": ("6", true), "&": ("7", true), "*": ("8", true),
        "(": ("9", true), ")": ("0", true)
    ]

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
