import Foundation
import TrolleyKit

/// The wiki, as two tools for an agent.
///
/// Split from `TrolleyTools` because it shares nothing with the rest of the surface:
/// every other tool needs Accessibility trust and a running app, and these need
/// neither. They are registered only when a wiki root is configured -- the same
/// conditional treatment the wiki tools get, and for the same reason: a tool that is
/// listed but cannot work is worse than one that is absent, because the model spends
/// a call finding out.
///
/// Read-only. `TrolleyKit`'s `Wiki` module exposes no write API at all, so there is no
/// path from here to a file the vault considers its own.
public struct WikiTools {
    let index: WikiIndex
    let rootURL: () -> URL?
    let storedFilter: () -> WikiFilter
    let mode: () -> WikiSettings.Mode

    public init(
        index: WikiIndex = .shared,
        rootURL: @escaping () -> URL? = { WikiSettings.rootURL },
        storedFilter: @escaping () -> WikiFilter = { WikiSettings.filter },
        mode: @escaping () -> WikiSettings.Mode = { WikiSettings.mode }
    ) {
        self.index = index
        self.rootURL = rootURL
        self.storedFilter = storedFilter
        self.mode = mode
    }

    /// The folders a call may reach into when it names none itself.
    ///
    /// `.auto` opens `members/` and `logs/` as well, because in that mode the person is
    /// no longer standing between the question and the vault -- "지난주 회의 뭐였지" is a
    /// `logs/` question, and a default that cannot see the folder answers it by saying
    /// the page does not exist. `_private` is in neither list and cannot be
    /// asked for: `walkTargets` only ever intersects with what `WikiIndex` offers.
    var defaultFolders: [String] {
        switch mode() {
        case .auto:
            return WikiIndex.indexableFolders + WikiIndex.optionalFolders
        case .manual, .off:
            let stored = storedFilter().folders
            guard !stored.isEmpty else { return WikiIndex.indexableFolders }
            return (WikiIndex.indexableFolders + WikiIndex.optionalFolders).filter { candidate in
                stored.contains { $0 == candidate || candidate.hasPrefix($0 + "/") }
            }
        }
    }

    /// Bodies are capped rather than streamed whole. The largest page in the vault is
    /// ~7KB, so this is generous, but an agent reading five pages should not be able to
    /// spend a context window without noticing.
    public static let defaultReadLimit = 8_000

    static var definitions: [ToolDefinition] {
        [
            ToolDefinition(
                name: "wiki_search",
                description:
                    "Search the team's llmwiki (a local Obsidian vault of Korean markdown pages) by its "
                    + "frontmatter. Returns one line per page: title, 상태 (status), 분류 (category), "
                    + "우선순위 (priority), 영역 (area), 담당 (assignee), 갱신일 (updated), 요약 (summary). "
                    + "Bodies are NOT included -- call wiki_read with a title to get one. Titles come back "
                    + "wrapped in [[...]], which is the vault's own link syntax and the exact string "
                    + "wiki_read expects. Every filter is optional and omitting one means no constraint on "
                    + "that field; several values for one filter match any of them. Calling it with no "
                    + "arguments at all is the cheap way in: that returns the whole board as titles, which "
                    + "is what to do first when you do not yet know what the vault holds.",
                inputSchema: Schema.object([
                    "type": Schema.stringArray("유형: 일감 (task), 개념 (concept), 데일리 (daily note), 회의, 사람."),
                    "status": Schema.stringArray("상태: 진행중 (in progress), 대기, 보류, 완료 (done)."),
                    "category": Schema.stringArray("분류: 버그, 기능, 인프라, 기획, UX."),
                    "area": Schema.stringArray("영역, e.g. web, be, mobile, agent, electron. A page may have several."),
                    "priority": Schema.stringArray("우선순위: 최우선, 중간, 하순위."),
                    "assignee": Schema.stringArray("담당, a GitHub handle. Pass 미지정 for unassigned pages."),
                    "folder": Schema.stringArray(
                        "Which folders to look in: context/tasks, context/concepts, members, logs. "
                        + "Omitting it searches the ones the wiki is configured to reach."
                    ),
                    "titleContains": Schema.string("Case-insensitive substring of the title or the summary."),
                    "sort": Schema.string(
                        "Order: board (상태·우선순위, the vault's own INDEX.md order), recent "
                        + "(most recently edited first), or stale (least recently updated first)."
                    ),
                    "limit": Schema.integer("Most pages to return.", default: 40),
                    "detail": Schema.string(
                        "How much of each page to return: titles (title and 상태 only), "
                        + "metadata (no 요약), or full. Defaults to full for a filtered search and "
                        + "to titles for an unfiltered one."
                    )
                ])
            ),
            ToolDefinition(
                name: "wiki_read",
                description:
                    "Read one llmwiki page in full, by the title wiki_search returned. Task pages are "
                    + "structured as 배경 (background), 현황 (current state), 타임라인 (dated log, ascending), "
                    + "관련 (links to other pages). This is the only tool that reads a page body, so prefer "
                    + "wiki_search when a summary would do.",
                inputSchema: Schema.object([
                    "title": Schema.string("The page title, with or without the surrounding [[ ]]."),
                    "maxCharacters": Schema.integer("Truncate the body at this length.", default: defaultReadLimit)
                ], required: ["title"])
            )
        ]
    }

    // MARK: - Dispatch

    /// How wide an unfiltered call may go before the count, rather than the character
    /// budget, is what stops it.
    ///
    /// 150 rather than `limit`'s 40 because the two calls are different questions. A
    /// filtered search is looking for something and 40 hits is already a failed filter;
    /// an unfiltered one is asking what exists, and at `.titles` the vault's ~110 open
    /// pages render to ~2,800 characters -- inside the 4,000 the tool result is truncated
    /// at, where the same list at `.full` is ~9,600 and comes back cut off mid-page.
    public static let mapLimit = 150

    /// The filter an unfiltered `wiki_search` runs: the whole board, as titles.
    ///
    /// Public because the options window previews it. Under 자동 there is no stored
    /// filter to show a person, and the honest thing to put in that box is the list
    /// trolley actually gets when it looks at the vault cold -- which is this, and has
    /// to stay this even when the numbers here change.
    public static func mapFilter(folders: Set<String> = []) -> WikiFilter {
        WikiFilter(folders: folders, maxCount: mapLimit, detail: .titles)
    }

    func search(_ args: Arguments) throws -> JSONValue {
        // Every axis starts empty rather than inherited from the stored filter: an agent
        // asking for 완료 pages must not silently get the widget's 진행중 filter applied on
        // top of its request. Before `.auto` this read `storedFilter()` and cleared each
        // axis in turn, which was the same thing said in eleven lines -- and it quietly
        // carried `folders` and `sort` across, the two axes it forgot to clear.
        var filter = WikiFilter()
        filter.types = Set(args.stringArray("type"))
        filter.statuses = Set(args.stringArray("status"))
        filter.categories = Set(args.stringArray("category"))
        filter.areas = Set(args.stringArray("area"))
        filter.priorities = Set(args.stringArray("priority"))
        filter.assignees = Set(args.stringArray("assignee").map { $0 == "미지정" ? "" : $0 })
        filter.titleContains = args.optionalString("titleContains") ?? ""
        filter.folders = Set(args.stringArray("folder"))
        filter.sort = WikiFilter.Sort(rawValue: args.optionalString("sort") ?? "") ?? .board

        // What the caller actually narrowed. A call that narrowed nothing is asking for
        // the map, not for a page, and gets the shape that fits in one tool result.
        let isMap = filter == WikiFilter(sort: filter.sort)
        let shape = isMap ? Self.mapFilter() : WikiFilter()
        filter.maxCount = max(1, args.int("limit", default: shape.maxCount))

        // An unrecognised spelling falls back to the widest line rather than erroring:
        // a wrong enum value should cost the agent a fatter answer, not a failed call.
        let detail = WikiFilter.Detail(rawValue: args.optionalString("detail") ?? "") ?? shape.detail

        // The walk follows the folder axis, so `folder: ["logs"]` reads `logs/` rather
        // than filtering a walk that never entered it. That was the old behaviour and it
        // made `members`/`logs` unreachable through this tool no matter what was asked.
        let snapshot = try snapshot(folders: walkTargets(for: filter))
        let (kept, dropped) = filter.apply(to: snapshot.pages)
        let lines: [JSONValue] = kept.map { page in
            JSONValue.string(WikiDigestRenderer.line(for: page, detail: detail))
        }
        var result: [String: JSONValue] = [:]
        result["matched"] = JSONValue.int(kept.count)
        result["total"] = JSONValue.int(kept.count + dropped)
        result["filter"] = JSONValue.string(WikiDigestRenderer.describe(filter))
        result["detail"] = JSONValue.string(detail.rawValue)
        result["pages"] = JSONValue.array(lines)
        return .object(result)
    }

    func read(_ args: Arguments) throws -> JSONValue {
        let requested = try args.string("title")
        // `[[제목]]` is how a title appears in wiki_search output and in the pages
        // themselves, so accept it back verbatim rather than making the model strip it.
        let title = requested
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))

        let snapshot = try snapshot(folders: WikiIndex.indexableFolders + WikiIndex.optionalFolders)
        // The lookup *is* the path check. A title that is not in the index yields
        // nothing to open, so `../../.ssh/id_rsa` is not a traversal attempt that gets
        // blocked -- it is simply a page that does not exist.
        guard let page = snapshot.pages.first(where: { $0.basename == title }) else {
            throw ToolError.wikiPageNotFound(title)
        }
        guard let body = try? String(contentsOfFile: page.path, encoding: .utf8) else {
            throw ToolError.wikiUnavailable("Could not read \(page.relativePath).")
        }

        let limit = max(200, args.int("maxCharacters", default: Self.defaultReadLimit))
        let truncated = body.count > limit
        return .object([
            "title": .string(page.basename),
            "path": .string(page.relativePath),
            "상태": .string(page.status),
            "담당": .string(page.assignee),
            "영역": .string(page.areas.joined(separator: "·")),
            "갱신일": .string(page.updated),
            "truncated": .bool(truncated),
            "body": .string(truncated ? String(body.prefix(limit)) + "\n\n…(잘림)" : body)
        ])
    }

    /// Only folders `WikiIndex` offers, and only ones the filter can match.
    ///
    /// The intersection is what keeps a made-up folder name from reaching the disk: a
    /// `folder: ["../.."]` matches nothing here and falls back to the configured set.
    private func walkTargets(for filter: WikiFilter) -> [String] {
        guard !filter.folders.isEmpty else { return defaultFolders }
        let chosen = (WikiIndex.indexableFolders + WikiIndex.optionalFolders).filter { candidate in
            filter.folders.contains { $0 == candidate || candidate.hasPrefix($0 + "/") }
        }
        return chosen.isEmpty ? defaultFolders : chosen
    }

    private func snapshot(folders: [String] = WikiIndex.indexableFolders) throws -> WikiSnapshot {
        guard let root = rootURL() else {
            throw ToolError.wikiUnavailable("No wiki folder is configured.")
        }
        do {
            return try index.snapshot(root: root, folders: folders)
        } catch WikiIndex.Failure.missing(let path) {
            throw ToolError.wikiUnavailable("The wiki folder is missing: \(path)")
        } catch WikiIndex.Failure.denied(let path) {
            throw ToolError.wikiUnavailable("The wiki folder cannot be read: \(path)")
        } catch {
            throw ToolError.wikiUnavailable("The wiki folder could not be read.")
        }
    }
}
