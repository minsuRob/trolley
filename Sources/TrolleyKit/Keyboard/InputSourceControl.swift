import Carbon
import Foundation

/// Seam over the Text Input Sources API.
///
/// Typing by key code presses physical key *positions*, so what appears depends
/// entirely on the active input source: with the Korean 2-Set IME selected,
/// pressing the h and k positions produces "ㅘ". Anything typing ASCII this way
/// has to select an ASCII-capable source first, and put the user's back after.
public protocol InputSourceControlling {
    func currentInputSourceID() -> String?
    func currentIsASCIICapable() -> Bool
    /// Returns the id selected, or nil if no ASCII-capable source is available.
    @discardableResult func selectASCIICapableInputSource() -> String?
    @discardableResult func selectInputSource(id: String) -> Bool
}

/// Real Carbon TIS-backed implementation. Needs no special permission.
public struct TISInputSourceController: InputSourceControlling {
    public init() {}

    public func currentInputSourceID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return Self.identifier(of: source)
    }

    public func currentIsASCIICapable() -> Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable)
        else { return false }
        return Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue() as? Bool ?? false
    }

    public func selectASCIICapableInputSource() -> String? {
        guard let sources = TISCreateASCIICapableInputSourceList()?.takeRetainedValue() as? [TISInputSource],
              !sources.isEmpty
        else { return nil }

        // Prefer plain ABC, then a US layout, before falling back to whatever
        // ASCII-capable source exists.
        let preferred = sources.first { Self.identifier(of: $0)?.hasSuffix("keylayout.ABC") == true }
            ?? sources.first { Self.identifier(of: $0)?.contains("keylayout.US") == true }
            ?? sources[0]

        guard TISSelectInputSource(preferred) == noErr else { return nil }
        return Self.identifier(of: preferred)
    }

    public func selectInputSource(id: String) -> Bool {
        guard let sources = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource],
              let match = sources.first(where: { Self.identifier(of: $0) == id })
        else { return false }
        return TISSelectInputSource(match) == noErr
    }

    private static func identifier(of source: TISInputSource) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }
}
