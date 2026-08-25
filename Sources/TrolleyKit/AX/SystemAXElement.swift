import ApplicationServices
import Foundation

/// Real `AXUIElement`-backed implementation of `AXElementProviding`.
public final class SystemAXElement: AXElementProviding {
    private let axElement: AXUIElement
    public let pid: pid_t?

    public var rawElement: AXUIElement { axElement }

    public init(axElement: AXUIElement, pid: pid_t? = nil) {
        self.axElement = axElement
        self.pid = pid
    }

    public static func application(pid: pid_t) -> SystemAXElement {
        SystemAXElement(axElement: AXUIElementCreateApplication(pid), pid: pid)
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
        var best: [AXUIElement] = []
        var stableStreak = 0
        for attempt in 0..<10 {
            guard let raw = copyAttribute(AXAttr.children) as? [AXUIElement] else { continue }
            if raw.count > best.count {
                best = raw
                stableStreak = 0
            } else if raw.count == best.count {
                stableStreak += 1
            }
            // Stop early once two consecutive queries agree on the widest count seen.
            if stableStreak >= 2 { break }
            if attempt < 9 {
                usleep(40_000)
            }
        }
        return best.map { SystemAXElement(axElement: $0, pid: pid) }
    }

    public func performAction(_ name: String) -> Bool {
        AXUIElementPerformAction(axElement, name as CFString) == .success
    }

    public func setAttribute(_ name: String, value: AnyObject) -> Bool {
        AXUIElementSetAttributeValue(axElement, name as CFString, value) == .success
    }
}
