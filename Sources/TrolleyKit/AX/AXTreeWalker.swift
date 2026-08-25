import Foundation

public struct AXTraversalLimits {
    public var maxDepth: Int
    public var maxNodes: Int

    public init(maxDepth: Int = 20, maxNodes: Int = 5000) {
        self.maxDepth = maxDepth
        self.maxNodes = maxNodes
    }
}

public struct AXMatch {
    public let element: AXElementProviding
    public let parent: AXElementProviding?
    public let depth: Int
}

public struct AXTreeWalker {
    public init() {}

    /// Depth-first walk with an explicit depth cap, a node-count cap (some AX
    /// trees are very wide rather than deep), and a visited-identity guard since
    /// third-party apps don't guarantee an acyclic children graph.
    public func walk(
        root: AXElementProviding,
        limits: AXTraversalLimits,
        visit: (_ element: AXElementProviding, _ depth: Int, _ parent: AXElementProviding?) -> Void
    ) {
        var visited = Set<ObjectIdentifier>()
        var visitedCount = 0

        func recurse(_ element: AXElementProviding, depth: Int, parent: AXElementProviding?) {
            guard visitedCount < limits.maxNodes else { return }
            let id = element.identity()
            guard !visited.contains(id) else { return }
            visited.insert(id)
            visitedCount += 1

            visit(element, depth, parent)

            guard depth < limits.maxDepth else { return }
            for child in element.children() {
                guard visitedCount < limits.maxNodes else { return }
                recurse(child, depth: depth + 1, parent: element)
            }
        }

        recurse(root, depth: 0, parent: nil)
    }

    public func findAll(
        root: AXElementProviding,
        query: ElementQuery,
        limits: AXTraversalLimits
    ) -> [AXMatch] {
        var results: [AXMatch] = []
        walk(root: root, limits: limits) { element, depth, parent in
            if ElementMatcher.matches(element, query: query) {
                results.append(AXMatch(element: element, parent: parent, depth: depth))
            }
        }
        return results
    }
}
