import Foundation

public struct ElementQuery {
    public var textContains: String
    public var attributesToSearch: [String]
    public var roleFilter: String?

    public init(
        textContains: String,
        attributesToSearch: [String] = [AXAttr.value, AXAttr.title, AXAttr.description],
        roleFilter: String? = nil
    ) {
        self.textContains = textContains
        self.attributesToSearch = attributesToSearch
        self.roleFilter = roleFilter
    }
}

public enum ElementMatcher {
    public static func matches(_ element: AXElementProviding, query: ElementQuery) -> Bool {
        if let roleFilter = query.roleFilter {
            guard element.stringAttribute(AXAttr.role) == roleFilter else { return false }
            // A role on its own is a complete query -- "the text area", with no
            // text to search for, is exactly how you address an empty field.
            if query.textContains.isEmpty { return true }
        }

        // Neither a role nor any text would match every node in the tree, which
        // is never what a caller means.
        guard !query.textContains.isEmpty else { return false }

        for attribute in query.attributesToSearch {
            if let text = element.stringAttribute(attribute),
               text.localizedCaseInsensitiveContains(query.textContains) {
                return true
            }
        }
        return false
    }

    /// Prefers the most specific (fewest-descendant) matches first, since a
    /// container that merely contains the target text as a substring of some
    /// aggregated value is usually a worse target than the leaf that owns it.
    public static func rankByLeafiness(_ candidates: [AXElementProviding]) -> [AXElementProviding] {
        candidates.sorted { lhs, rhs in
            lhs.children().count < rhs.children().count
        }
    }
}
