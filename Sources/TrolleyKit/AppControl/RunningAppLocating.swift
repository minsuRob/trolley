import Foundation

public struct RunningAppInfo {
    public let processIdentifier: pid_t
    public let isFinishedLaunching: Bool

    public init(processIdentifier: pid_t, isFinishedLaunching: Bool) {
        self.processIdentifier = processIdentifier
        self.isFinishedLaunching = isFinishedLaunching
    }
}

/// Seam over NSWorkspace so app-launch decision logic (already running / needs
/// launch / times out) is unit-testable without touching real running apps.
public protocol RunningAppLocating {
    func runningApplication(bundleID: String) -> RunningAppInfo?
    func applicationURL(bundleID: String) -> URL?
    func activate(bundleID: String) -> Bool
    func open(applicationAt url: URL) -> Bool
}
