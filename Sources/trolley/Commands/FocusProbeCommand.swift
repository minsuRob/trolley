import ApplicationServices
import ArgumentParser
import Foundation
import TrolleyKit

/// Temporary diagnostic: inspect the system-wide focused UI element instead of
/// walking the full AX tree, to see if Chromium keeps focus tracking in sync
/// even when the full tree isn't built for this observing process.
struct FocusProbeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "focus-probe")

    func run() throws {
        let checker = SystemTrustChecker()
        guard AccessibilityPermission.ensureTrusted(checker: checker, prompt: true) else {
            print("not trusted")
            throw ExitCode.failure
        }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedApp: AnyObject?
        let err1 = AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedApp)
        print("focusedApp err=\(err1.rawValue)")
        guard err1 == .success, let appElement = focusedApp else { return }
        let appAX = appElement as! AXUIElement

        var role: AnyObject?
        _ = AXUIElementCopyAttributeValue(appAX, kAXRoleAttribute as CFString, &role)
        print("focusedApp role=\(role as? String ?? "?")")

        var focusedUI: AnyObject?
        let err2 = AXUIElementCopyAttributeValue(appAX, kAXFocusedUIElementAttribute as CFString, &focusedUI)
        print("focusedUI err=\(err2.rawValue)")
        guard err2 == .success, let uiElement = focusedUI else { return }
        let uiAX = uiElement as! AXUIElement

        func attr(_ name: String) -> String {
            var v: AnyObject?
            let e = AXUIElementCopyAttributeValue(uiAX, name as CFString, &v)
            if e == .success, let s = v as? String { return s }
            if e == .success, let v { return "\(v)" }
            return "(err \(e.rawValue))"
        }
        print("role: \(attr(kAXRoleAttribute as String))")
        print("title: \(attr(kAXTitleAttribute as String))")
        print("value: \(attr(kAXValueAttribute as String))")
        print("desc: \(attr(kAXDescriptionAttribute as String))")

        var parentVal: AnyObject?
        let e4 = AXUIElementCopyAttributeValue(uiAX, kAXParentAttribute as CFString, &parentVal)
        print("parent err=\(e4.rawValue)")
        guard e4 == .success, let parentEl = parentVal else { return }
        let parentAX = parentEl as! AXUIElement
        var pChildren: AnyObject?
        let e5 = AXUIElementCopyAttributeValue(parentAX, kAXChildrenAttribute as CFString, &pChildren)
        if e5 == .success, let arr = pChildren as? [AXUIElement] {
            print("parent children count: \(arr.count)")
            for (i, child) in arr.enumerated() {
                var v: AnyObject?
                _ = AXUIElementCopyAttributeValue(child, kAXValueAttribute as CFString, &v)
                var r: AnyObject?
                _ = AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &r)
                print("  [\(i)] role=\(r as? String ?? "?") value=\(v as? String ?? "?")")
            }
        }
    }
}
