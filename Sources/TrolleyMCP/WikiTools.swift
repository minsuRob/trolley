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

    public init(
        index: WikiIndex = .shared,
        rootURL: @escaping () -> URL? = { WikiSettings.rootURL }
    ) {
        self.index = index
        self.rootURL = rootURL
    }

    /// The folders a call may reach into when it names none itself: all of them.
    ///
    /// `members/` and `logs/` included, because nobody is standing between the question
    /// and the vault here -- "지난주 회의 뭐였지" is a `logs/` question, and a default that
    /// cannot see the folder answers it by saying the page does not exist. This used to
    /// narrow to the options window's stored folder set unless the mode was 자동; the
    /// stored filter is now what the wiki *window* starts its list from, which is a
    /// person's view and not a limit on what may be asked for.
    ///
    /// `_private` is not on the list and cannot be asked for: `walkTargets` only ever
    /// intersects with what `WikiIndex` offers.
    var defaultFolders: [String] { WikiIndex.indexableFolders + WikiIndex.optionalFolders }

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

    /// The two lines the local model is told about, when it is told about these at all.
    ///
    /// Here rather than in `TrolleyToolRunner` because the runner that offers them is no
    /// longer the one that drives the screen: the wiki window builds its own catalog out
    /// of exactly this, and a second copy of the parameter names is a second thing to get
    /// wrong. Parameter names have to be the schemas' own -- `ToolSummary.signature`
    /// renders them straight into the prompt as the call signature, so a name that is not
    /// in the schema is an instruction to make a call `WikiTools` rejects, with no way for
    /// the model to find that out.
    public static let summaries: [ToolCallContract.ToolSummary] = [
        .init(name: "wiki_search",
              parameters: [
                  "titleContains", "status", "type", "category", "area",
                  "priority", "assignee", "folder", "sort", "detail", "limit"
              ],
              summary: "위키에서 문서를 찾는다. 조건은 필요한 것만 골라 쓰고, 그냥 부르면 전체 목록"),
        .init(name: "wiki_read", parameters: ["title"],
              summary: "위키 문서 한 건의 본문을 읽는다. 제목은 [[ ]] 없이 그대로 넣는다")
    ]

    // MARK: - Dispatch

    /// How wide an unfiltered call may go before the count is what stops it.
    ///
    /// 150 rather than `limit`'s 40 because the two calls are different questions. A
    /// filtered search is looking for something and 40 hits is already a failed filter;
    /// an unfiltered one is asking what exists.
    ///
    /// No longer the thing that keeps the answer deliverable -- `resultBudget` is. A
    /// count cannot do that job: this was set when the vault held ~110 open pages that
    /// rendered to ~2,800 characters, and at 241 pages the same 150 titles render to
    /// 5,151 -- past the limit the result is cut at, with no count that would have known.
    public static let mapLimit = 150

    /// How much of one search result actually reaches the model.
    ///
    /// `ToolCallContract.resultMessage` truncates a tool result at 4,000 characters, and
    /// what it truncates is this object's JSON. That cut lands *inside* `pages`: the
    /// array ends unterminated, `total` -- which sorts after it -- never arrives, and
    /// `matched` does, so the model is handed a number that describes a list it did not
    /// receive. Measured on the real vault: 150 titles claimed, ~115 delivered, and the
    /// header telling it not to guess about anything not on the list.
    ///
    /// So the tool fits its own answer instead of being cut to fit. Below the transport
    /// limit by enough to carry the other fields, and `note` says what was left out --
    /// a model that knows the list is partial asks a narrower question, where one that
    /// believes it is complete answers "그런 문서 없습니다".
    static let resultBudget = 3_400

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
        let rendered = kept.map { WikiDigestRenderer.line(for: $0, detail: detail) }
        let fitted = Self.fit(rendered, budget: Self.resultBudget)

        var result: [String: JSONValue] = [:]
        result["matched"] = JSONValue.int(fitted.count)
        result["total"] = JSONValue.int(kept.count + dropped)
        result["filter"] = JSONValue.string(WikiDigestRenderer.describe(filter))
        result["detail"] = JSONValue.string(detail.rawValue)
        result["pages"] = JSONValue.array(fitted.map(JSONValue.string))
        if fitted.count < kept.count + dropped {
            result["note"] = JSONValue.string(Self.note(
                shown: fitted.count, total: kept.count + dropped, detail: detail
            ))
        }
        return .object(result)
    }

    /// As many lines as fit, in the order the sort put them.
    ///
    /// A prefix rather than a sample: the sort is the answer to "what matters first", so
    /// dropping from the tail keeps the useful end and makes what is missing describable
    /// in one sentence.
    static func fit(_ lines: [String], budget: Int) -> [String] {
        var kept: [String] = []
        var spent = 0
        for line in lines {
            // The JSON this ends up in wraps every line in quotes and a comma. Counting
            // the wrapper is what keeps the budget honest about the bytes on the wire
            // rather than the characters we happened to render.
            let cost = line.count + 3
            guard spent + cost <= budget else { break }
            spent += cost
            kept.append(line)
        }
        // Never nothing: an empty list reads as "no such pages", which is a different
        // and much worse answer than "here is one, and there are more".
        if kept.isEmpty, let first = lines.first { kept = [first] }
        return kept
    }

    /// Written at the model, not at a person: it is the only party that can act on it.
    static func note(shown: Int, total: Int, detail: WikiFilter.Detail) -> String {
        var text = "\(total)건 중 \(shown)건만 실었다. 나머지는 잘린 것이 아니라 아직 보내지 않은 것이다."
        text += " 조건을 좁혀서 다시 불러라 — folder, status, area, assignee, titleContains."
        if detail != .titles {
            text += " detail=titles 로 부르면 같은 한도에 더 많이 들어간다."
        }
        return text
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
