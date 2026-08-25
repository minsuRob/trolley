public struct AXTreeDumper {
    public init() {}

    public func dump(root: AXElementProviding, limits: AXTraversalLimits) -> String {
        var lines: [String] = []
        let walker = AXTreeWalker()
        walker.walk(root: root, limits: limits) { element, depth, _ in
            let indent = String(repeating: "  ", count: depth)
            let role = element.stringAttribute(AXAttr.role) ?? "?"
            let title = element.stringAttribute(AXAttr.title) ?? ""
            let value = truncate(element.stringAttribute(AXAttr.value) ?? "")
            let description = element.stringAttribute(AXAttr.description) ?? ""
            let childCount = element.children().count
            lines.append("\(indent)\(role) | title=\(title) | value=\(value) | desc=\(description) | children=\(childCount)")
        }
        return lines.joined(separator: "\n")
    }

    private func truncate(_ text: String, limit: Int = 80) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }
}
