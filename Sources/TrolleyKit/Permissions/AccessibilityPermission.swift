import ApplicationServices
import Foundation

public protocol TrustChecking {
    func isProcessTrusted() -> Bool
    func requestTrust(prompting: Bool) -> Bool
}

public struct SystemTrustChecker: TrustChecking {
    public init() {}

    public func isProcessTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    public func requestTrust(prompting: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: prompting] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}

public enum AccessibilityPermission {
    /// The absolute path of the currently running executable, since Accessibility
    /// trust in System Settings is granted per executable path.
    ///
    /// Asks dyld rather than reading `argv[0]`: invoked through PATH, argv[0] is
    /// the bare word "trolley" and resolving it against the working directory
    /// yields a path that does not exist. Users would then approve the wrong path
    /// and never become trusted. `realpath` on top, because TCC keys on the
    /// resolved file, not on any symlink pointing at it.
    public static func currentExecutablePath() -> String {
        var size = UInt32(PATH_MAX)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return "(unknown)" }

        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(buffer, &resolved) != nil {
            return String(cString: resolved)
        }
        return String(cString: buffer)
    }

    /// Returns true if trusted. If `prompt` is true and not yet trusted, this will
    /// trigger the system prompt (still requires the user to act in System Settings).
    public static func ensureTrusted(checker: TrustChecking, prompt: Bool) -> Bool {
        if checker.isProcessTrusted() {
            return true
        }
        return checker.requestTrust(prompting: prompt)
    }
}
