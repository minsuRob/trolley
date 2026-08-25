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
    public static func currentExecutablePath() -> String {
        guard let first = CommandLine.arguments.first else { return "(unknown)" }
        let url = URL(fileURLWithPath: first)
        return url.standardizedFileURL.path
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
