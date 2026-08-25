import ApplicationServices
import Foundation

/// How hard `children()` retries a truncated children array. The retry exists
/// purely for Chromium/Electron (see `children()`); against native AppKit apps
/// it is pure latency, and at ~40-80ms per node it dominates any full-tree walk.
public struct AXChildrenRetryPolicy {
    public var attempts: Int
    public var delayMicroseconds: UInt32

    public init(attempts: Int, delayMicroseconds: UInt32) {
        self.attempts = max(1, attempts)
        self.delayMicroseconds = delayMicroseconds
    }

    /// One query, no delay. Correct for native AppKit/Cocoa UI.
    public static let fast = AXChildrenRetryPolicy(attempts: 1, delayMicroseconds: 0)
    /// Retry until two consecutive queries agree. Needed for Chromium/Electron.
    public static let thorough = AXChildrenRetryPolicy(attempts: 10, delayMicroseconds: 40_000)
}

/// Real `AXUIElement`-backed implementation of `AXElementProviding`.
public final class SystemAXElement: AXElementProviding {
    private let axElement: AXUIElement
    public let pid: pid_t?
    /// Inherited by every element produced by `children()`, so a walk keeps one
    /// policy throughout.
    public var childrenRetryPolicy: AXChildrenRetryPolicy

    public var rawElement: AXUIElement { axElement }

    public init(
        axElement: AXUIElement,
        pid: pid_t? = nil,
        childrenRetryPolicy: AXChildrenRetryPolicy = .thorough
    ) {
        self.axElement = axElement
        self.pid = pid
        self.childrenRetryPolicy = childrenRetryPolicy
    }

    public static func application(
        pid: pid_t,
        childrenRetryPolicy: AXChildrenRetryPolicy = .thorough
    ) -> SystemAXElement {
        SystemAXElement(
            axElement: AXUIElementCreateApplication(pid),
            pid: pid,
            childrenRetryPolicy: childrenRetryPolicy
        )
    }

    public func copyAttribute(_ name: String) -> AnyObject? {
        var value: AnyObject?
        let error = AXUIElementCopyAttributeValue(axElement, name as CFString, &value)
        guard error == .success else { return nil }
        return value
    }

    public func copyAttributeNames() -> [String] {
        var names: CFArray?
        let error = AXUIElementCopyAttributeNames(axElement, &names)
        guard error == .success, let names else { return [] }
        return (names as? [String]) ?? []
    }

    public func children() -> [AXElementProviding] {
        // Chromium/Electron's out-of-process accessibility bridge is known to
        // return a transiently truncated children array on some individual
        // queries (observed live against Notion: a node reporting N children
        // occasionally yields fewer on a given call). Retry a few times and
        // keep the widest result rather than trusting a single query.
        let policy = childrenRetryPolicy
        var best: [AXUIElement] = []
        var stableStreak = 0
        for attempt in 0..<policy.attempts {
            guard let raw = copyAttribute(AXAttr.children) as? [AXUIElement] else { continue }
            if raw.count > best.count {
                best = raw
                stableStreak = 0
            } else if raw.count == best.count {
                stableStreak += 1
            }
            // Stop early once two consecutive queries agree on the widest count seen.
            if stableStreak >= 2 { break }
            if attempt < policy.attempts - 1, policy.delayMicroseconds > 0 {
                usleep(policy.delayMicroseconds)
            }
        }
        return best.map {
            SystemAXElement(axElement: $0, pid: pid, childrenRetryPolicy: policy)
        }
    }

    public func performAction(_ name: String) -> Bool {
        AXUIElementPerformAction(axElement, name as CFString) == .success
    }

    public func setAttribute(_ name: String, value: AnyObject) -> Bool {
        AXUIElementSetAttributeValue(axElement, name as CFString, value) == .success
    }

    public func isAlive() -> Bool {
        var value: AnyObject?
        let error = AXUIElementCopyAttributeValue(axElement, AXAttr.role as CFString, &value)
        switch error {
        case .invalidUIElement, .cannotComplete:
            // The view is gone, or its app stopped responding to AX entirely.
            return false
        default:
            // .noValue / .attributeUnsupported still mean the element exists.
            return true
        }
    }
}
