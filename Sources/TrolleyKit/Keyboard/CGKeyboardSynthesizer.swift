import CoreGraphics
import Foundation

/// Seam over CGEvent posting so `KeyboardActions` orchestration is testable with
/// a recording fake, without actually injecting OS-level input.
public protocol KeyEventPosting {
    func post(keyCode: CGKeyCode, down: Bool, flags: CGEventFlags)
    func postUnicode(_ chunk: [UniChar], down: Bool)
}

/// Real CGEvent-backed implementation.
public struct CGKeyboardSynthesizer: KeyEventPosting {
    private let source = CGEventSource(stateID: .hidSystemState)

    public init() {}

    public func post(keyCode: CGKeyCode, down: Bool, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    public func postUnicode(_ chunk: [UniChar], down: Bool) {
        // virtualKey: 0 is standard for pure-Unicode injection (bypasses keycode
        // mapping entirely, which is what lets this type Korean text directly).
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { return }
        var mutableChunk = chunk
        event.keyboardSetUnicodeString(stringLength: mutableChunk.count, unicodeString: &mutableChunk)
        event.post(tap: .cghidEventTap)
    }
}

public enum KeyboardActions {
    /// Types arbitrary Unicode text (including Korean) by chunking the UTF-16
    /// buffer into small groups with a short delay between chunks -- posting an
    /// entire long string in one CGEvent is unreliable against Chromium-based
    /// rich text editors.
    public static func type(
        _ text: String,
        using poster: KeyEventPosting,
        chunkSize: Int = 20,
        interKeyDelayMS: UInt32 = 2,
        sleeper: (UInt32) -> Void = { usleep($0 * 1000) }
    ) {
        let units = Array(text.utf16)
        guard !units.isEmpty else { return }

        var index = 0
        while index < units.count {
            let end = min(index + chunkSize, units.count)
            let chunk = Array(units[index..<end])
            poster.postUnicode(chunk, down: true)
            poster.postUnicode(chunk, down: false)
            index = end
            if index < units.count {
                sleeper(interKeyDelayMS)
            }
        }
    }

    public static func press(
        _ keyName: String,
        modifiers: [String] = [],
        using poster: KeyEventPosting
    ) {
        guard let keyCode = KeyCodeMap.keyCode(forName: keyName) else { return }
        var flags: CGEventFlags = []
        for modifier in modifiers {
            if let flag = KeyCodeMap.modifierFlags[modifier.lowercased()] {
                flags.insert(flag)
            }
        }
        poster.post(keyCode: keyCode, down: true, flags: flags)
        poster.post(keyCode: keyCode, down: false, flags: flags)
    }
}
