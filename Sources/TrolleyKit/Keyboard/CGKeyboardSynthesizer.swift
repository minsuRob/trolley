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

    /// When set, events are delivered straight to this process instead of through
    /// the system event tap, so they reach the intended app even if it is not
    /// frontmost at the moment they are posted.
    private let targetPid: pid_t?

    public init(targetPid: pid_t? = nil) {
        self.targetPid = targetPid
    }

    private func deliver(_ event: CGEvent) {
        if let targetPid {
            event.postToPid(targetPid)
        } else {
            event.post(tap: .cghidEventTap)
        }
    }

    public func post(keyCode: CGKeyCode, down: Bool, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { return }
        event.flags = flags
        deliver(event)
    }

    public func postUnicode(_ chunk: [UniChar], down: Bool) {
        // virtualKey: 0 is standard for pure-Unicode injection: it carries no
        // meaningful key code, so the attached string is the only content.
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { return }
        var mutableChunk = chunk
        event.keyboardSetUnicodeString(stringLength: mutableChunk.count, unicodeString: &mutableChunk)
        deliver(event)
    }
}

public enum KeyboardActions {
    /// Types arbitrary Unicode text (including Korean) by chunking the UTF-16
    /// buffer into small groups with a short delay between chunks -- posting an
    /// entire long string in one CGEvent is unreliable against Chromium-based
    /// rich text editors.
    ///
    /// This is a dead end on at least some systems, and is retained only so the
    /// claim stays testable elsewhere -- it backs `TextEntryMethod.unicode`,
    /// which is never selected by default. Measured against TextEdit, every
    /// combination of event source (`hidSystemState`, nil), tap
    /// (`cghidEventTap`, `cgSessionEventTap`, `postToPid`) and input source
    /// (Korean 2-Set, ABC) left the target's AXValue untouched, while plain key
    /// codes posted from the same binary landed reliably.
    ///
    /// Use `TextEntryEngine` instead: pasting carries any Unicode, and
    /// `typeASCII` produces genuine per-key events.
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

    /// Types printable ASCII by pressing physical key positions, the delivery
    /// path measured to actually work. What appears is whatever the *active
    /// input source* produces from those positions, so the caller must have
    /// selected an ASCII-capable source first -- see `InputSourceControlling`.
    ///
    /// Returns false without posting anything if any character is unmappable,
    /// matching `press`: half-typed text is worse than none.
    @discardableResult
    public static func typeASCII(
        _ text: String,
        using poster: KeyEventPosting,
        interKeyDelayMS: UInt32 = 8,
        sleeper: (UInt32) -> Void = { usleep($0 * 1000) }
    ) -> Bool {
        var strokes: [(key: CGKeyCode, shift: Bool)] = []
        strokes.reserveCapacity(text.count)
        for character in text {
            guard let stroke = KeyCodeMap.asciiKeyStroke(for: character) else { return false }
            strokes.append(stroke)
        }

        for (index, stroke) in strokes.enumerated() {
            // Shift rides as a flag on the same keystroke rather than as a
            // separate key-down, the same shape as the modifiers in `press`.
            let flags: CGEventFlags = stroke.shift ? .maskShift : []
            poster.post(keyCode: stroke.key, down: true, flags: flags)
            poster.post(keyCode: stroke.key, down: false, flags: flags)
            if index < strokes.count - 1 {
                sleeper(interKeyDelayMS)
            }
        }
        return true
    }

    /// Returns false without posting anything when the key name (or any modifier
    /// name) is unknown, so callers can report the failure instead of silently
    /// doing nothing.
    @discardableResult
    public static func press(
        _ keyName: String,
        modifiers: [String] = [],
        using poster: KeyEventPosting
    ) -> Bool {
        guard let keyCode = KeyCodeMap.keyCode(forName: keyName) else { return false }
        var flags: CGEventFlags = []
        for modifier in modifiers {
            guard let flag = KeyCodeMap.modifierFlags[modifier.lowercased()] else { return false }
            flags.insert(flag)
        }
        poster.post(keyCode: keyCode, down: true, flags: flags)
        poster.post(keyCode: keyCode, down: false, flags: flags)
        return true
    }
}
