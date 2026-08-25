import CoreGraphics
import Foundation
import TrolleyKit

/// Turns an AX subtree into compact JSON for an LLM to read.
///
/// The output goes straight into a model's context, so this is much more
/// aggressive than `AXTreeDumper`: uninteresting wrapper nodes are collapsed,
/// long values are truncated, and the node budget is small. Truncation is always
/// reported -- a silently clipped tree reads as "that's everything", which is
/// how a model concludes an element doesn't exist when it simply wasn't walked.
public struct TreeSnapshotter {
    public struct Options {
        public var maxDepth: Int
        public var maxNodes: Int
        public var interestingOnly: Bool
        public var textContains: String?
        public var role: String?
        public var valueLimit: Int

        public init(
            maxDepth: Int = 20,
            maxNodes: Int = 800,
            interestingOnly: Bool = true,
            textContains: String? = nil,
            role: String? = nil,
            valueLimit: Int = 120
        ) {
            self.maxDepth = maxDepth
            self.maxNodes = maxNodes
            self.interestingOnly = interestingOnly
            self.textContains = textContains
            self.role = role
            self.valueLimit = valueLimit
        }
    }

    public struct Result {
        public let tree: [JSONValue]
        public let nodeCount: Int
        public let truncated: Bool
    }

    /// Roles worth showing even when they carry no text of their own: things you
    /// can act on, plus top-level windows as landmarks.
    ///
    /// Deliberately excludes structural containers (AXRow, AXCell, AXTable,
    /// AXGroup, AXToolbar…). A text-bearing one is kept by the text check
    /// anyway; an empty one is pure nesting, and against a Finder window those
    /// alone consumed the entire node budget before any labelled content
    /// appeared. Roles that only matter when labelled (AXStaticText, AXImage)
    /// are likewise left to the text check.
    static let interestingRoles: Set<String> = [
        "AXButton", "AXTextField", "AXTextArea", "AXSearchField", "AXLink",
        "AXMenuItem", "AXMenuButton", "AXCheckBox", "AXRadioButton",
        "AXPopUpButton", "AXComboBox", "AXSlider", "AXIncrementor",
        "AXDisclosureTriangle", "AXWindow", "AXSheet"
    ]

    let registry: ElementRegistry
    let options: Options

    public init(registry: ElementRegistry, options: Options = Options()) {
        self.registry = registry
        self.options = options
    }

    public func snapshot(root: AXElementProviding) -> Result {
        var emitted = 0
        var truncated = false
        var visited = Set<ObjectIdentifier>()

        // Pre-order so the budget is spent near the root, where the useful
        // landmarks are, rather than deep inside the first subtree.
        func build(_ element: AXElementProviding, depth: Int, isRoot: Bool) -> [JSONValue] {
            let identity = element.identity()
            guard !visited.contains(identity) else { return [] }
            visited.insert(identity)

            let childNodes: () -> [JSONValue] = {
                guard depth < options.maxDepth else { return [] }
                return element.children().flatMap { build($0, depth: depth + 1, isRoot: false) }
            }

            // The app element itself is always kept as the container.
            guard isRoot || shouldEmit(element) else {
                return childNodes()
            }

            guard emitted < options.maxNodes else {
                truncated = true
                return []
            }
            emitted += 1

            var node = describe(element)
            node["id"] = .string(registry.register(element))
            let children = childNodes()
            if !children.isEmpty {
                node["children"] = .array(children)
            }
            return [.object(node)]
        }

        let tree = build(root, depth: 0, isRoot: true)
        return Result(tree: tree, nodeCount: emitted, truncated: truncated)
    }

    /// An explicit text/role filter overrides `interestingOnly` -- when the
    /// caller says what they're looking for, that is the more specific request.
    func shouldEmit(_ element: AXElementProviding) -> Bool {
        if let role = options.role,
           element.stringAttribute(AXAttr.role) != role {
            return false
        }
        if let text = options.textContains, !text.isEmpty {
            return [AXAttr.value, AXAttr.title, AXAttr.description].contains { attribute in
                element.stringAttribute(attribute)?.localizedCaseInsensitiveContains(text) == true
            }
        }
        if options.role != nil {
            return true
        }
        guard options.interestingOnly else { return true }

        if let role = element.stringAttribute(AXAttr.role), Self.interestingRoles.contains(role) {
            return true
        }
        return [AXAttr.title, AXAttr.value, AXAttr.description].contains { attribute in
            let text = element.stringAttribute(attribute)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return !(text ?? "").isEmpty
        }
    }

    func describe(_ element: AXElementProviding) -> [String: JSONValue] {
        var node: [String: JSONValue] = [
            "role": .string(element.stringAttribute(AXAttr.role) ?? "?")
        ]
        if let title = nonEmpty(element.stringAttribute(AXAttr.title)) {
            node["title"] = .string(truncate(title, into: &node, flag: "titleTruncated"))
        }
        if let value = nonEmpty(element.stringAttribute(AXAttr.value)) {
            node["value"] = .string(truncate(value, into: &node, flag: "valueTruncated"))
        }
        if let description = nonEmpty(element.stringAttribute(AXAttr.description)) {
            node["description"] = .string(truncate(description, into: &node, flag: "descriptionTruncated"))
        }
        if let frame = frame(of: element) {
            node["frame"] = frame
        }
        return node
    }

    private func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    private func truncate(_ text: String, into node: inout [String: JSONValue], flag: String) -> String {
        guard text.count > options.valueLimit else { return text }
        node[flag] = .bool(true)
        return String(text.prefix(options.valueLimit)) + "…"
    }

    private func frame(of element: AXElementProviding) -> JSONValue? {
        guard let position = element.pointAttribute(AXAttr.position),
              let size = element.sizeAttribute(AXAttr.size) else { return nil }
        return .array([
            .int(Int(position.x)), .int(Int(position.y)),
            .int(Int(size.width)), .int(Int(size.height))
        ])
    }
}
