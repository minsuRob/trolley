import Darwin
@testable import TrolleyKit

/// In-memory fake `AXElementProviding` so AX-tree logic is testable without a
/// live UI.
final class MockAXElement: AXElementProviding {
    var pid: pid_t?
    var attributes: [String: AnyObject]
    var mockChildren: [MockAXElement]
    var pressActionResult = true
    var setAttributeResult = true
    var performedActions: [String] = []
    var setAttributes: [(String, AnyObject)] = []

    init(
        role: String? = nil,
        title: String? = nil,
        value: String? = nil,
        description: String? = nil,
        children: [MockAXElement] = []
    ) {
        var attrs: [String: AnyObject] = [:]
        if let role { attrs[AXAttr.role] = role as AnyObject }
        if let title { attrs[AXAttr.title] = title as AnyObject }
        if let value { attrs[AXAttr.value] = value as AnyObject }
        if let description { attrs[AXAttr.description] = description as AnyObject }
        self.attributes = attrs
        self.mockChildren = children
    }

    func copyAttribute(_ name: String) -> AnyObject? {
        attributes[name]
    }

    func copyAttributeNames() -> [String] {
        Array(attributes.keys)
    }

    func children() -> [AXElementProviding] {
        mockChildren
    }

    func performAction(_ name: String) -> Bool {
        performedActions.append(name)
        return pressActionResult
    }

    func setAttribute(_ name: String, value: AnyObject) -> Bool {
        setAttributes.append((name, value))
        return setAttributeResult
    }
}
