import Foundation

public enum NotionScenarioError: Error, CustomStringConvertible {
    case treeNeverPopulated
    case headingNotFound(String)

    public var description: String {
        switch self {
        case .treeNeverPopulated:
            return "Notion's accessibility tree never populated (Electron lazy-load timeout)"
        case .headingNotFound(let heading):
            return "Could not find a block containing \"\(heading)\""
        }
    }
}

public struct NotionHeadingBodyScenario {
    public var bundleID: String
    public let heading: String
    public let body: String
    public var createIfMissing: Bool
    public var dryRun: Bool

    public init(
        bundleID: String = "notion.id",
        heading: String,
        body: String,
        createIfMissing: Bool = false,
        dryRun: Bool = false
    ) {
        self.bundleID = bundleID
        self.heading = heading
        self.body = body
        self.createIfMissing = createIfMissing
        self.dryRun = dryRun
    }

    public func run(
        launcher: AppLauncher,
        locator: RunningAppLocating,
        keyPoster: KeyEventPosting,
        makeRoot: (pid_t) -> AXElementProviding,
        log: (String) -> Void = { print($0) }
    ) throws -> ActionResult {
        let pid = try launcher.launchOrActivate(bundleID: bundleID, locator: locator)
        log("activated \(bundleID) pid=\(pid)")

        let root = try waitForPopulatedTree(pid: pid, makeRoot: makeRoot, log: log)
        // Best effort: Chromium/Electron apps often need this to fully populate
        // their AX tree; ignore failure since older builds may not honor it.
        _ = root.setAttribute(AXAttr.manualAccessibility, value: true as CFBoolean)

        let walker = AXTreeWalker()
        let limits = AXTraversalLimits()
        let executor = ActionExecutor(root: root, walker: walker, keyPoster: keyPoster, limits: limits)

        var matches = walker.findAll(root: root, query: ElementQuery(textContains: heading), limits: limits)
        var ranked = ElementMatcher.rankByLeafiness(matches.map(\.element))

        if ranked.isEmpty {
            guard createIfMissing else {
                throw NotionScenarioError.headingNotFound(heading)
            }
            log("heading not found, creating it (--create-if-missing)")
            try createHeadingBlock(executor: executor, log: log)
            matches = walker.findAll(root: root, query: ElementQuery(textContains: heading), limits: limits)
            ranked = ElementMatcher.rankByLeafiness(matches.map(\.element))
            guard !ranked.isEmpty else {
                throw NotionScenarioError.headingNotFound(heading)
            }
        }

        guard let bestMatch = matches.first(where: { $0.element === ranked[0] }) else {
            throw NotionScenarioError.headingNotFound(heading)
        }

        if dryRun {
            log("dry-run: matched heading element (role=\(bestMatch.element.stringAttribute(AXAttr.role) ?? "?"))")
            log("dry-run: would type \"\(body)\" into the block below \"\(heading)\"")
            return .elementFound(matches)
        }

        try typeBodyBelow(match: bestMatch, executor: executor, log: log)
        return .ok
    }

    // MARK: - Steps

    private func waitForPopulatedTree(
        pid: pid_t,
        makeRoot: (pid_t) -> AXElementProviding,
        log: (String) -> Void,
        timeout: TimeInterval = 10,
        pollInterval: TimeInterval = 0.25
    ) throws -> AXElementProviding {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let root = makeRoot(pid)
            if !root.children().isEmpty {
                return root
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        log("warning: tree still empty after \(timeout)s, proceeding anyway")
        throw NotionScenarioError.treeNeverPopulated
    }

    private func createHeadingBlock(executor: ActionExecutor, log: (String) -> Void) throws {
        KeyboardActions.type(heading, using: executor.keyPoster)
        KeyboardActions.press("return", using: executor.keyPoster)
    }

    private func typeBodyBelow(match: AXMatch, executor: ActionExecutor, log: (String) -> Void) throws {
        // Primary path: if the matched heading has a parent with a sibling right
        // after it, treat that sibling as the pre-existing "block below".
        if let parent = match.parent {
            let siblings = parent.children()
            if let index = siblings.firstIndex(where: { $0 === match.element }),
               index + 1 < siblings.count {
                log("primary path: focusing existing sibling block below heading")
                executor.perform(.focus(siblings[index + 1]))
                executor.perform(.type(body))
                return
            }
        }

        // Fallback: focus the heading itself, move to end of line, press Return
        // to create a new block below it (Notion's editor convention), then type.
        log("fallback path: focus heading -> end -> return -> type")
        executor.perform(.focus(match.element))
        executor.perform(.key(name: "end", modifiers: []))
        executor.perform(.key(name: "return", modifiers: []))
        executor.perform(.type(body))
    }
}
