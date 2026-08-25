import AppKit
import Foundation

public enum AppLauncherError: Error, CustomStringConvertible {
    case applicationNotFound(bundleID: String)
    case launchTimedOut(bundleID: String)
    case activateFailed(bundleID: String)

    public var description: String {
        switch self {
        case .applicationNotFound(let bundleID):
            return "No application found for bundle id \(bundleID)"
        case .launchTimedOut(let bundleID):
            return "Timed out waiting for \(bundleID) to launch"
        case .activateFailed(let bundleID):
            return "Failed to activate \(bundleID)"
        }
    }
}

/// Real NSWorkspace-backed `RunningAppLocating` implementation.
public struct WorkspaceAppLocator: RunningAppLocating {
    public init() {}

    public func runningApplication(bundleID: String) -> RunningAppInfo? {
        guard let app = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == bundleID }) else { return nil }
        return RunningAppInfo(
            processIdentifier: app.processIdentifier,
            isFinishedLaunching: app.isFinishedLaunching
        )
    }

    public func applicationURL(bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    public func activate(bundleID: String) -> Bool {
        guard let app = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == bundleID }) else { return false }
        // ignoringOtherApps is deprecated and has no effect from macOS 14.
        return app.activate()
    }

    public func open(applicationAt url: URL) -> Bool {
        NSWorkspace.shared.openApplication(
            at: url,
            configuration: NSWorkspace.OpenConfiguration(),
            completionHandler: nil
        )
        return true
    }
}

public struct AppLauncher {
    public var pollIntervalSeconds: TimeInterval
    public var sleeper: (TimeInterval) -> Void

    /// Waits by running the run loop rather than blocking the thread.
    ///
    /// `NSRunningApplication`'s properties are KVO-backed and only refresh while
    /// the run loop turns. Measured in a CLI process: polling behind
    /// `Thread.sleep`, `isFinishedLaunching` stayed false for all 32 polls over
    /// 8s even though the app was up and frontmost; pumping the run loop, it
    /// went true on the 2nd poll (0.26s). Blocking here doesn't just waste
    /// time -- it makes the launch look like it failed.
    public static func pumpRunLoop(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    public init(
        pollIntervalSeconds: TimeInterval = 0.25,
        sleeper: @escaping (TimeInterval) -> Void = AppLauncher.pumpRunLoop
    ) {
        self.pollIntervalSeconds = pollIntervalSeconds
        self.sleeper = sleeper
    }

    /// Decision logic: already running -> activate; not running -> resolve app URL,
    /// open it, then poll (bounded) until it appears and finishes launching.
    public func launchOrActivate(
        bundleID: String,
        locator: RunningAppLocating,
        timeout: TimeInterval = 15
    ) throws -> pid_t {
        if let running = locator.runningApplication(bundleID: bundleID) {
            _ = locator.activate(bundleID: bundleID)
            return running.processIdentifier
        }

        guard let url = locator.applicationURL(bundleID: bundleID) else {
            throw AppLauncherError.applicationNotFound(bundleID: bundleID)
        }

        guard locator.open(applicationAt: url) else {
            throw AppLauncherError.activateFailed(bundleID: bundleID)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let running = locator.runningApplication(bundleID: bundleID),
               running.isFinishedLaunching {
                return running.processIdentifier
            }
            sleeper(pollIntervalSeconds)
        }

        throw AppLauncherError.launchTimedOut(bundleID: bundleID)
    }
}
