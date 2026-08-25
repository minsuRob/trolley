import ApplicationServices
import CoreGraphics
import Foundation

/// Abstraction over a single accessibility element (real `AXUIElement` or a test
/// fake). All AX-tree logic (matching, walking, action orchestration) is written
/// against this protocol so it can be unit tested without a live UI.
public protocol AXElementProviding: AnyObject {
    var pid: pid_t? { get }

    func copyAttribute(_ name: String) -> AnyObject?
    func copyAttributeNames() -> [String]
    func children() -> [AXElementProviding]
    func performAction(_ name: String) -> Bool
    func setAttribute(_ name: String, value: AnyObject) -> Bool

    /// Stable identity for cycle detection / dedup, independent of attribute values.
    func identity() -> ObjectIdentifier

    /// Whether the underlying UI element still exists. A cached reference goes
    /// stale as soon as the app tears down that view, so anything holding
    /// elements across calls (the MCP element registry) must be able to tell.
    func isAlive() -> Bool
}

public extension AXElementProviding {
    func identity() -> ObjectIdentifier {
        ObjectIdentifier(self)
    }

    /// Fakes are always alive; only `SystemAXElement` can actually go stale.
    func isAlive() -> Bool {
        true
    }

    func stringAttribute(_ name: String) -> String? {
        copyAttribute(name) as? String
    }

    func boolAttribute(_ name: String) -> Bool? {
        (copyAttribute(name) as? NSNumber)?.boolValue
    }

    func pointAttribute(_ name: String) -> CGPoint? {
        guard let value = copyAttribute(name) else { return nil }
        var point = CGPoint.zero
        // AXValue-boxed CGPoint arrives as an AXValue CFTypeRef, not a plain object.
        if CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() {
            let axValue = value as! AXValue
            if AXValueGetType(axValue) == .cgPoint {
                AXValueGetValue(axValue, .cgPoint, &point)
                return point
            }
        }
        return nil
    }

    func sizeAttribute(_ name: String) -> CGSize? {
        guard let value = copyAttribute(name) else { return nil }
        var size = CGSize.zero
        if CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() {
            let axValue = value as! AXValue
            if AXValueGetType(axValue) == .cgSize {
                AXValueGetValue(axValue, .cgSize, &size)
                return size
            }
        }
        return nil
    }
}
