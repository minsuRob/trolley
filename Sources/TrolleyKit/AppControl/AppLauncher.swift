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
        return app.activate(options: [.activateIgnoringOtherApps])
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

    public init(
        pollIntervalSeconds: TimeInterval = 0.25,
        sleeper: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
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
