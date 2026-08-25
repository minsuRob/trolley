import Carbon
import CoreGraphics
import Foundation

/// How text gets into a field.
public enum TextEntryMethod: String, CaseIterable {
    /// Clipboard plus cmd+V. Carries any Unicode and works in Chromium/Electron.
    case paste
    /// Real per-key events. ASCII only, and it needs an ASCII-capable input
    /// source, so it temporarily switches the user's. Use for fields that
    /// respond to keystrokes but ignore a paste (search-as-you-type).
    case keys
    /// CGEvent Unicode injection. Measured not to be delivered at all on some
    /// systems; kept for diagnosing others, never a default.
    case unicode
}

/// What we can honestly say about whether the text arrived.
public enum TextEntryVerification: String {
    case confirmed
    /// The element's value is unchanged, so nothing happened. The only state
    /// from which failure is certain.
    case provablyFailed
    /// No element, or it doesn't report a value -- common for rich-text and
    /// Chromium-backed views. Not success; unknown.
    case unverifiable
    /// The value changed but doesn't contain the text: an input method may be
    /// mid-composition, or the field reformatted what it received.
    case changedUnexpectedly
}

public struct TextEntryOutcome {
    public let method: TextEntryMethod
    public let verification: TextEntryVerification
    public let valueBefore: String?
    public let valueAfter: String?
    /// nil unless `paste` ran.
    public let clipboardRestored: Bool?
    public let clipboardNote: String?
    /// nil unless `keys` had to switch the input source.
    public let inputSourceRestored: Bool?
    /// Only consulted when the text did not verifiably arrive.
    public let secureInputEnabled: Bool
}

public enum TextEntryError: Error {
    case unsupportedCharacters(String, method: TextEntryMethod)
    case clipboardUnavailable
    case inputSourceUnavailable
    case keyPostFailed(String)
}

/// Puts text into a focused field using only mechanisms that actually deliver,
/// and reports honestly when it can't tell whether they did.
///
/// There is deliberately no fallback chain. A second attempt is only safe when
/// the first is *proven* not to have landed, and for the views most likely to
/// need one -- Chromium, rich text -- that proof is exactly what's unavailable,
/// so a chain would risk entering the text twice. One method runs; the result
/// says what is known.
public struct TextEntryEngine {
    private let makePoster: (pid_t?) -> KeyEventPosting
    private let clipboard: ClipboardAccessing
    private let inputSource: InputSourceControlling
    private let sleeper: (TimeInterval) -> Void
    private let secureInputCheck: () -> Bool

    public init(
        makePoster: @escaping (pid_t?) -> KeyEventPosting,
        clipboard: ClipboardAccessing,
        inputSource: InputSourceControlling,
        sleeper: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        secureInputCheck: @escaping () -> Bool = { IsSecureEventInputEnabled() }
    ) {
        self.makePoster = makePoster
        self.clipboard = clipboard
        self.inputSource = inputSource
        self.sleeper = sleeper
        self.secureInputCheck = secureInputCheck
    }

    public func insert(
        _ text: String,
        method: TextEntryMethod,
        element: AXElementProviding?,
        targetPid: pid_t?,
        pasteSettle: TimeInterval = 0.3,
        verifyTimeout: TimeInterval = 2.0,
        pollInterval: TimeInterval = 0.1
    ) throws -> TextEntryOutcome {
        let before = element?.stringAttribute(AXAttr.value)

        var clipboardRestored: Bool?
        var clipboardNote: String?
        var inputSourceRestored: Bool?
        var after: String?

        switch method {
        case .paste:
            let saved = clipboard.snapshot()
            guard clipboard.writePlainText(text) else {
                throw TextEntryError.clipboardUnavailable
            }
            let ours = clipboard.changeCount

            // cmd+V goes through the system tap, not to a pid: shortcut matching
            // happens at the tap, which is the path measured to work.
            guard KeyboardActions.press("v", modifiers: ["cmd"], using: makePoster(nil)) else {
                throw TextEntryError.keyPostFailed("could not post cmd+V")
            }

            // Wait for the paste to actually be consumed before taking the
            // clipboard back -- the target app does it on its own run loop, and
            // restoring early would swap the content out mid-paste. Where the
            // element reports a value, its change *is* the evidence; otherwise
            // fall back to a fixed settle.
            after = awaitValueChange(element, before: before, timeout: verifyTimeout, interval: pollInterval)
            if element == nil || after == before {
                sleeper(pasteSettle)
            }

            let result = restoreClipboard(saved, ours: ours)
            clipboardRestored = result.restored
            clipboardNote = result.note

        case .keys:
            // Validate before touching anything global, so a rejected request
            // leaves the machine exactly as it was.
            let unmapped = text.filter { KeyCodeMap.asciiKeyStroke(for: $0) == nil }
            guard unmapped.isEmpty else {
                throw TextEntryError.unsupportedCharacters(
                    String(Array(Set(unmapped)).sorted()),
                    method: .keys
                )
            }

            var previousSource: String?
            if !inputSource.currentIsASCIICapable() {
                // Capture before switching -- afterwards "current" is already ASCII.
                previousSource = inputSource.currentInputSourceID()
                guard inputSource.selectASCIICapableInputSource() != nil else {
                    throw TextEntryError.inputSourceUnavailable
                }
                sleeper(0.15)   // TIS selection reaches the frontmost app asynchronously.
            }

            let posted = KeyboardActions.typeASCII(text, using: makePoster(nil))

            // Let the app drain the key queue before putting the input source
            // back. Measured in Chrome's omnibox: restoring immediately left the
            // trailing keystrokes to be re-interpreted by the restored IME, so
            // "trolley keys test" arrived as "trolley keys tesㅅ". The queue
            // drains roughly in step with how long posting took, so scale with
            // the text. Verification deliberately happens *after* the restore --
            // polling for the first character to appear would release the source
            // while the rest were still queued.
            if posted {
                sleeper(Self.keyQueueSettle(forCharacterCount: text.count))
            }
            if let previousSource {
                inputSourceRestored = inputSource.selectInputSource(id: previousSource)
                sleeper(0.1)
            }
            guard posted else {
                throw TextEntryError.keyPostFailed("could not post key codes for the text")
            }
            after = awaitValueChange(element, before: before, timeout: verifyTimeout, interval: pollInterval)

        case .unicode:
            KeyboardActions.type(text, using: makePoster(targetPid))
            after = awaitValueChange(element, before: before, timeout: verifyTimeout, interval: pollInterval)
        }

        let verification = Self.verify(before: before, after: after, text: text, hadElement: element != nil)

        return TextEntryOutcome(
            method: method,
            verification: verification,
            valueBefore: before,
            valueAfter: after,
            clipboardRestored: clipboardRestored,
            clipboardNote: clipboardNote,
            inputSourceRestored: inputSourceRestored,
            // Cheap, and it turns a baffling silent failure into one sentence.
            secureInputEnabled: verification == .confirmed ? false : secureInputCheck()
        )
    }

    /// `after == before` is the failure test rather than "doesn't contain the
    /// text", because it is the only condition under which *nothing happened* is
    /// certain. A field that reformats what it received changed, and says so.
    static func verify(
        before: String?,
        after: String?,
        text: String,
        hadElement: Bool
    ) -> TextEntryVerification {
        guard hadElement, let before, let after else { return .unverifiable }
        if after.contains(text) { return .confirmed }
        if after == before { return .provablyFailed }
        return .changedUnexpectedly
    }

    // MARK: - Helpers

    /// Polls until the element's value moves, rather than guessing how long the
    /// app needs. Measured against TextEdit: a fixed 0.5s wait read the value
    /// *before* the paste was processed, so a successful insert reported as a
    /// definite failure -- and the next call then saw the previous call's text.
    private func awaitValueChange(
        _ element: AXElementProviding?,
        before: String?,
        timeout: TimeInterval,
        interval: TimeInterval
    ) -> String? {
        guard let element else { return nil }

        var waited: TimeInterval = 0
        while waited < timeout {
            let current = element.stringAttribute(AXAttr.value)
            if current != before { return current }
            sleeper(interval)
            waited += interval
        }
        return element.stringAttribute(AXAttr.value)
    }

    private func restoreClipboard(
        _ saved: ClipboardSnapshot,
        ours: Int
    ) -> (restored: Bool, note: String?) {
        if saved.truncated {
            return (false, "The previous clipboard was too large to copy, so it could not be put back.")
        }
        guard clipboard.changeCount == ours else {
            return (false, "Another app wrote to the clipboard first, so the previous contents were left alone.")
        }
        let restored = clipboard.restore(saved)
        return (restored, restored ? nil : "Could not put the previous clipboard contents back.")
    }

    /// How long to let the target drain a queue of synthesized keystrokes before
    /// the input source is switched back. Roughly tracks how long posting them
    /// took, with a floor for the app's own scheduling latency.
    static func keyQueueSettle(forCharacterCount count: Int) -> TimeInterval {
        max(0.3, 0.015 * Double(count))
    }
}
