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
    /// The single biggest lever on how many characters a question carries, and now a
    /// three-position one rather than a switch.
    public var detail: Detail
    public var sort: Sort

    /// The boolean `detail` replaced, kept for reading.
    ///
    /// Computed, so it stays out of the synthesized `Codable` and `Equatable` -- the
    /// encoder writes the key by hand instead (see `encode(to:)`), and two filters that
    /// differ only between `.titles` and `.metadata` must not compare equal.
    public var includeSummary: Bool { detail == .full }

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

    /// How much of a page each line carries.
    ///
    /// The three levels are ~5x apart on the real vault: the 84 pages that are 진행중
    /// or 대기 render to ~2,800 characters at `.titles` and ~9,600 at `.full`. That
    /// span is the difference between a list that fits the budget whole and one that
    /// gets cut -- which is why this is an axis and not a preference.
    public enum Detail: String, Codable, CaseIterable {
        /// `- [[제목]] · 상태`
        case titles
        /// `- [[제목]] · 상태 · 분류 · 우선순위 · 영역 · 담당 · 갱신일`
        case metadata
        /// …` · 요약`
        case full

        public var title: String {
            switch self {
            case .titles: return "제목만"
            case .metadata: return "메타데이터"
            case .full: return "메타+요약"
            }
        }
    }

    /// Everything still open, as titles.
    ///
    /// The previous default -- 진행중 at `.full` -- measured 9,564 characters against a
    /// 9,000 budget on the real vault, so it was silently dropping rows for everyone
    /// who never opened the options window. `.titles` brings the same list to ~2,600
    /// and leaves room for 대기 as well.
    ///
    /// 대기 is in because a question about "what is open" means work that is blocked
    /// too, and 보류 and 완료 are out because they are the two states nobody is asked
    /// about. Both are one checkbox away.
    ///
    /// `maxCount` rises with the detail drop: at `.titles` the character budget stops
    /// being the binding limit and the count becomes it, and 진행중+대기 is 84 pages
    /// today -- already past the old cap of 80.
    ///
    /// Note that `WikiSettings` removes a stored value equal to this one, so changing
    /// this changes behaviour for everyone who merely accepted the old default. That is
    /// deliberate here: the old default was over budget.
    public static let `default` = WikiFilter(
        types: [], statuses: ["진행중", "대기"], categories: [], areas: [], priorities: [],
        assignees: [], folders: Set(WikiIndex.indexableFolders), titleContains: "",
        staleDays: nil, maxCount: 150, detail: .titles, sort: .board
    )

    public init(
        types: Set<String> = [], statuses: Set<String> = [], categories: Set<String> = [],
        areas: Set<String> = [], priorities: Set<String> = [], assignees: Set<String> = [],
        folders: Set<String> = [], titleContains: String = "", staleDays: Int? = nil,
        // `.full` rather than `.default`'s `.titles`: this initializer's job is to build
        // an explicit filter, and the widest line is the least surprising thing for an
        // unspecified argument to mean.
        maxCount: Int = 40, detail: Detail = .full, sort: Sort = .board
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
        self.detail = detail
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
            "n=\(maxCount)", "detail=\(detail.rawValue)", "sort=\(sort.rawValue)"
        ].joined(separator: "|")
    }

    // MARK: - Codable

    /// Hand-rolled in both directions, for two different reasons.
    ///
    /// Decoding: the synthesized initializer requires every key, and a filter saved by
    /// an older build has `includeSummary` and no `detail`. That throws, `WikiSettings`
    /// swallows it with `try?`, and the person's entire saved filter silently reverts to
    /// the default. So every axis is `decodeIfPresent` with a fallback -- which also
    /// means the *next* axis added here will not repeat this migration.
    ///
    /// Encoding: `includeSummary` is still written, even though nothing in this build
    /// reads it. An app rolled back by `trolley update` reads the same defaults domain
    /// with the old synthesized decoder, which throws on a missing key.
    private enum CodingKeys: String, CodingKey {
        case types, statuses, categories, areas, priorities, assignees, folders
        case titleContains, staleDays, maxCount, detail, includeSummary, sort
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func set(_ key: CodingKeys) throws -> Set<String> {
            try container.decodeIfPresent(Set<String>.self, forKey: key) ?? []
        }
        types = try set(.types)
        statuses = try set(.statuses)
        categories = try set(.categories)
        areas = try set(.areas)
        priorities = try set(.priorities)
        assignees = try set(.assignees)
        // Not `[]`: an empty folder set means "no constraint", so defaulting a *missing*
        // key to it would quietly widen an old filter into `members/` and `logs/`.
        folders = try container.decodeIfPresent(Set<String>.self, forKey: .folders)
            ?? Set(WikiIndex.indexableFolders)
        titleContains = try container.decodeIfPresent(String.self, forKey: .titleContains) ?? ""
        staleDays = try container.decodeIfPresent(Int.self, forKey: .staleDays)
        maxCount = try container.decodeIfPresent(Int.self, forKey: .maxCount) ?? Self.default.maxCount
        sort = try container.decodeIfPresent(Sort.self, forKey: .sort) ?? .board

        if let stored = try container.decodeIfPresent(Detail.self, forKey: .detail) {
            detail = stored
        } else if let legacy = try container.decodeIfPresent(Bool.self, forKey: .includeSummary) {
            // The only two states the boolean could express, so the only two it may mean.
            detail = legacy ? .full : .metadata
        } else {
            detail = .full
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(types, forKey: .types)
        try container.encode(statuses, forKey: .statuses)
        try container.encode(categories, forKey: .categories)
        try container.encode(areas, forKey: .areas)
        try container.encode(priorities, forKey: .priorities)
        try container.encode(assignees, forKey: .assignees)
        try container.encode(folders, forKey: .folders)
        try container.encode(titleContains, forKey: .titleContains)
        try container.encodeIfPresent(staleDays, forKey: .staleDays)
        try container.encode(maxCount, forKey: .maxCount)
        try container.encode(detail, forKey: .detail)
        try container.encode(detail == .full, forKey: .includeSummary)
        try container.encode(sort, forKey: .sort)
    }
}
