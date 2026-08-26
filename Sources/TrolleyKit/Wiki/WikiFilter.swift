import Foundation

/// The last `- YYYY-MM-DD:` under `## 타임라인`.
///
/// The vault's own tooling (`tools/mcp/task-age.js`) treats this, not `갱신일`, as
/// the source of truth for how long a task has been sitting: `갱신일` gets bumped by
/// bookkeeping edits, while a timeline entry means someone actually did something.
/// It takes the *maximum* rather than the last line, because the section is
/// append-only by convention and not by enforcement.
public enum WikiTimeline {
    public static func lastDate(in body: String) -> String? {
        var latest: String?
        var inTimeline = false
        for rawLine in body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                // Dates under 배경/현황/관련 are prose, not progress.
                inTimeline = line.hasPrefix("## 타임라인")
                continue
            }
            guard inTimeline, line.hasPrefix("- ") else { continue }
            let rest = line.dropFirst(2)
            guard rest.count >= 11, rest[rest.index(rest.startIndex, offsetBy: 10)] == ":" else { continue }
            let candidate = String(rest.prefix(10))
            guard isISODate(candidate) else { continue }
            if latest == nil || candidate > latest! { latest = candidate }
        }
        return latest
    }

    static func isISODate(_ text: String) -> Bool {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2 else { return false }
        return parts.allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    /// Whole days between an ISO date and `today`. Nil for anything unparseable, so
    /// a malformed date reads as "no information" rather than "infinitely stale".
    public static func daysSince(_ isoDate: String, today: Date, calendar: Calendar = .current) -> Int? {
        guard isISODate(isoDate) else { return nil }
        var components = DateComponents()
        components.year = Int(isoDate.prefix(4))
        components.month = Int(isoDate.dropFirst(5).prefix(2))
        components.day = Int(isoDate.dropFirst(8).prefix(2))
        guard let then = calendar.date(from: components) else { return nil }
        return calendar.dateComponents([.day], from: then, to: today).day
    }
}

/// Which pages a question gets to see.
///
/// Every axis is a set, and **an empty set means "no constraint on this axis"**. The
/// alternative -- empty meaning "match nothing" -- turns the options window into a
/// trap, where clearing a filter to widen a search silently empties it instead.
public struct WikiFilter: Codable, Equatable {
    public var types: Set<String>        // 유형
    public var statuses: Set<String>     // 상태
    public var categories: Set<String>   // 분류
    public var areas: Set<String>        // 영역
    public var priorities: Set<String>   // 우선순위
    public var assignees: Set<String>    // 담당 -- "" selects 미지정
    public var folders: Set<String>
    public var titleContains: String
    /// Only pages whose last timeline entry is at least this old. Nil switches it off.
    public var staleDays: Int?
    public var maxCount: Int
    /// The single biggest lever on how many characters a question carries.
    public var includeSummary: Bool
    public var sort: Sort

    public enum Sort: String, Codable, CaseIterable {
        /// The vault's own ordering, matching `reindex.py`.
        case board
        case recent
        case stale

        public var title: String {
            switch self {
            case .board: return "상태·우선순위"
            case .recent: return "최근 갱신"
            case .stale: return "정체 순"
            }
        }
    }

    /// Everything still open, and all of it.
    ///
    /// Measured against the real vault: 65 of its 110 pages are 진행중, rendering to
    /// ~8,100 characters -- inside `WikiDigestRenderer.defaultBudget`, so the default
    /// view is complete rather than truncated. The cap of 80 sits above that with
    /// room for the wiki to grow before either limit bites.
    ///
    /// 완료 is excluded because it is 39 of the 110 pages and a question is almost
    /// always about what is still open. Widening to it is one checkbox away.
    public static let `default` = WikiFilter(
        types: [], statuses: ["진행중"], categories: [], areas: [], priorities: [],
        assignees: [], folders: Set(WikiIndex.indexableFolders), titleContains: "",
        staleDays: nil, maxCount: 80, includeSummary: true, sort: .board
    )

    public init(
        types: Set<String> = [], statuses: Set<String> = [], categories: Set<String> = [],
        areas: Set<String> = [], priorities: Set<String> = [], assignees: Set<String> = [],
        folders: Set<String> = [], titleContains: String = "", staleDays: Int? = nil,
        maxCount: Int = 40, includeSummary: Bool = true, sort: Sort = .board
    ) {
        self.types = types
        self.statuses = statuses
        self.categories = categories
        self.areas = areas
        self.priorities = priorities
        self.assignees = assignees
        self.folders = folders
        self.titleContains = titleContains
        self.staleDays = staleDays
        self.maxCount = maxCount
        self.includeSummary = includeSummary
        self.sort = sort
    }

    // MARK: - Matching

    /// An active axis excludes a page that has no value for it. Concept pages carry
    /// no 상태, so filtering by status drops them -- which is correct, and why 유형
    /// is the coarse gate that sits above the rest.
    public func matches(_ page: WikiPage) -> Bool {
        if !types.isEmpty, !types.contains(page.type) { return false }
        if !statuses.isEmpty, !statuses.contains(page.status) { return false }
        if !categories.isEmpty, !categories.contains(page.category) { return false }
        if !priorities.isEmpty, !priorities.contains(page.priority) { return false }
        if !assignees.isEmpty, !assignees.contains(page.assignee) { return false }
        // Prefix, not equality: a page's folder is its first two path components, so
        // `members/minsuRob` has to be matched by a filter that says `members`.
        if !folders.isEmpty,
           !folders.contains(where: { page.folder == $0 || page.folder.hasPrefix($0 + "/") }) {
            return false
        }
        // 영역 is a list; any overlap counts. A page with no areas cannot satisfy an
        // area constraint.
        if !areas.isEmpty, areas.isDisjoint(with: page.areas) { return false }
        if !titleContains.isEmpty,
           page.basename.range(of: titleContains, options: .caseInsensitive) == nil,
           page.summary.range(of: titleContains, options: .caseInsensitive) == nil {
            return false
        }
        return true
    }

    /// Filters, orders, then truncates. Returns how many were cut so the caller can
    /// say so out loud rather than hand over a silently short list.
    public func apply(to pages: [WikiPage], today: Date = Date()) -> (kept: [WikiPage], dropped: Int) {
        let matched = pages.filter(matches)
        let ordered = Self.order(matched, by: sort, today: today)
        guard maxCount > 0, ordered.count > maxCount else { return (ordered, 0) }
        return (Array(ordered.prefix(maxCount)), ordered.count - maxCount)
    }

    // MARK: - Ordering

    /// 진행중 first, then 대기, 보류, and 완료 last. Copied from `reindex.py`'s
    /// `STATUS_ORDER`, and unknown values sort after all known ones.
    static func statusRank(_ status: String) -> Int {
        switch status {
        case "진행중": return 0
        case "대기": return 1
        case "보류": return 2
        case "완료": return 3
        default: return 4
        }
    }

    /// `reindex.py`'s `PRIO_ORDER`. 중간 is the default in the vault, so an absent
    /// priority sorts with it rather than last.
    static func priorityRank(_ priority: String) -> Int {
        switch priority {
        case "최우선": return 0
        case "중간", "": return 1
        case "하순위": return 2
        default: return 3
        }
    }

    static func order(_ pages: [WikiPage], by sort: Sort, today: Date) -> [WikiPage] {
        switch sort {
        case .board:
            // Deliberately the same order the vault's own INDEX.md uses. Two tools
            // reading one wiki and listing it differently is how a person loses track
            // of which one they are looking at.
            return pages.sorted { a, b in
                // Assigned handles alphabetically, unassigned last.
                if a.assignee != b.assignee {
                    if a.assignee.isEmpty { return false }
                    if b.assignee.isEmpty { return true }
                    return a.assignee < b.assignee
                }
                let statusA = statusRank(a.status), statusB = statusRank(b.status)
                if statusA != statusB { return statusA < statusB }
                let prioA = priorityRank(a.priority), prioB = priorityRank(b.priority)
                if prioA != prioB { return prioA < prioB }
                if a.created != b.created { return a.created < b.created }
                return a.basename < b.basename
            }
        case .recent:
            return pages.sorted { a, b in
                if a.modified != b.modified { return a.modified > b.modified }
                return a.basename < b.basename
            }
        case .stale:
            // Oldest activity first. `갱신일` is the cheap stand-in here; the exact
            // timeline date costs a body read and is only paid for by `staleDays`.
            return pages.sorted { a, b in
                if a.updated != b.updated { return a.updated < b.updated }
                return a.basename < b.basename
            }
        }
    }

    // MARK: - Fingerprint

    /// Identifies this filter across launches.
    ///
    /// Built by hand from sorted arrays rather than from `Set.hashValue` or a plain
    /// `JSONEncoder` pass. Swift seeds `Hashable` per process and `Set` has no
    /// encoding order, so either shortcut would produce a different string every time
    /// the app starts -- and this value's whole job is to decide whether anything
    /// changed since last time. A fingerprint that always changes re-sends the wiki
    /// on every launch, which is the exact cost the design exists to avoid.
    public var fingerprint: String {
        func joined(_ label: String, _ values: Set<String>) -> String {
            // The empty string is a real selection -- it means 미지정, and 36 pages in
            // the vault are. Joined as-is it renders to nothing, which is exactly what
            // the *empty set* renders to, so "show me unowned work" and "no owner
            // filter at all" would share a fingerprint and a change between them would
            // go unnoticed. The sentinel keeps them apart.
            let items = values.sorted().map { $0.isEmpty ? "<미지정>" : $0 }
            return "\(label)=\(items.joined(separator: ","))"
        }
        return [
            joined("t", types), joined("s", statuses), joined("c", categories),
            joined("a", areas), joined("p", priorities), joined("o", assignees),
            joined("f", folders),
            "q=\(titleContains)",
            "d=\(staleDays.map(String.init) ?? "-")",
            "n=\(maxCount)", "sum=\(includeSummary)", "sort=\(sort.rawValue)"
        ].joined(separator: "|")
    }
}
