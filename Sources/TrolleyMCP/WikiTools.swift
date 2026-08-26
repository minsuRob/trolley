import Foundation
import TrolleyKit

/// The wiki, as two tools for an agent.
///
/// Split from `TrolleyTools` because it shares nothing with the rest of the surface:
/// every other tool needs Accessibility trust and a running app, and these need
/// neither. They are registered only when a wiki root is configured -- the same
/// conditional treatment `take_prompt` gets, and for the same reason: a tool that is
/// listed but cannot work is worse than one that is absent, because the model spends
/// a call finding out.
///
/// Read-only. `TrolleyKit`'s `Wiki` module exposes no write API at all, so there is no
/// path from here to a file the vault considers its own.
public struct WikiTools {
    let index: WikiIndex
    let rootURL: () -> URL?
    let storedFilter: () -> WikiFilter

    public init(
        index: WikiIndex = .shared,
        rootURL: @escaping () -> URL? = { WikiSettings.rootURL },
        storedFilter: @escaping () -> WikiFilter = { WikiSettings.filter }
    ) {
        self.index = index
        self.rootURL = rootURL
        self.storedFilter = storedFilter
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
                    + "that field; several values for one filter match any of them.",
                inputSchema: Schema.object([
                    "type": Schema.stringArray("유형: 일감 (task), 개념 (concept), 데일리 (daily note), 회의, 사람."),
                    "status": Schema.stringArray("상태: 진행중 (in progress), 대기, 보류, 완료 (done)."),
                    "category": Schema.stringArray("분류: 버그, 기능, 인프라, 기획, UX."),
                    "area": Schema.stringArray("영역, e.g. web, be, mobile, agent, electron. A page may have several."),
                    "priority": Schema.stringArray("우선순위: 최우선, 중간, 하순위."),
                    "assignee": Schema.stringArray("담당, a GitHub handle. Pass 미지정 for unassigned pages."),
                    "titleContains": Schema.string("Case-insensitive substring of the title or the summary."),
                    "limit": Schema.integer("Most pages to return.", default: 40)
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

    func search(_ args: Arguments) throws -> JSONValue {
        let snapshot = try snapshot()
        var filter = storedFilter()
        // Every axis the caller did not mention is cleared rather than inherited: an
        // agent asking for 완료 pages should not silently get the widget's 진행중
        // filter applied on top of its request.
        filter.types = Set(args.stringArray("type"))
        filter.statuses = Set(args.stringArray("status"))
        filter.categories = Set(args.stringArray("category"))
        filter.areas = Set(args.stringArray("area"))
        filter.priorities = Set(args.stringArray("priority"))
        filter.assignees = Set(args.stringArray("assignee").map { $0 == "미지정" ? "" : $0 })
        filter.titleContains = args.optionalString("titleContains") ?? ""
        filter.maxCount = max(1, args.int("limit", default: 40))

        let (kept, dropped) = filter.apply(to: snapshot.pages)
        let lines: [JSONValue] = kept.map { page in
            JSONValue.string(WikiDigestRenderer.line(for: page, includeSummary: true))
        }
        var result: [String: JSONValue] = [:]
        result["matched"] = JSONValue.int(kept.count)
        result["total"] = JSONValue.int(kept.count + dropped)
        result["filter"] = JSONValue.string(WikiDigestRenderer.describe(filter))
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
