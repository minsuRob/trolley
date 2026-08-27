import ArgumentParser
import Foundation
import TrolleyKit

/// Inspects the wiki the way the prompt box will, without a server and without a GUI.
///
/// Two jobs. It is how the root and the filters get configured from a terminal -- the
/// options window is the other way -- and it is how the parser is checked against the
/// wiki's own `INDEX.md`. That second one matters more than it sounds: the parser is a
/// deliberate copy of the vault's `reindex.py`, so `--json` disagreeing with `INDEX.md`
/// is the one signal that says the copy has drifted.
struct WikiCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wiki",
        abstract: "Inspect and configure the llmwiki digest that rides along with questions."
    )

    @Option(help: "Wiki folder for this call. With --save it becomes the stored path.")
    var root: String?

    @Flag(help: "Store --root as the wiki folder and exit.")
    var save = false

    @Flag(help: "Turn the wiki on, in 자동 mode. Same as --mode auto.")
    var enable = false

    @Flag(help: "Turn the wiki off, keeping the path and filters.")
    var disable = false

    @Option(help: "How the wiki is consulted: off | auto (trolley picks per question) | manual (this filter's digest rides along).")
    var mode: WikiSettings.Mode?

    @Flag(help: "Print the digest exactly as a question would carry it.")
    var preview = false

    @Flag(help: "Print the matching pages as JSON. Compare against the wiki's INDEX.md.")
    var json = false

    @Option(name: .customLong("type"), help: "유형 filter, repeatable.")
    var types: [String] = []

    @Option(name: .customLong("status"), help: "상태 filter, repeatable.")
    var statuses: [String] = []

    @Option(name: .customLong("category"), help: "분류 filter, repeatable.")
    var categories: [String] = []

    @Option(name: .customLong("area"), help: "영역 filter, repeatable. Matches any of a page's areas.")
    var areas: [String] = []

    @Option(name: .customLong("priority"), help: "우선순위 filter, repeatable.")
    var priorities: [String] = []

    @Option(name: .customLong("assignee"), help: "담당 filter, repeatable. Use 미지정 for unowned pages.")
    var assignees: [String] = []

    @Option(name: .customLong("folder"), help: "Folder filter, repeatable, e.g. context/tasks.")
    var folders: [String] = []

    @Option(help: "Substring of the title or summary.")
    var search: String?

    @Option(help: "Only pages whose last timeline entry is at least this many days old.")
    var stale: Int?

    @Option(help: "Most pages to list.")
    var limit: Int?

    @Option(help: "Character budget for the digest.")
    var budget: Int?

    @Option(help: "Line detail: titles | metadata | full.")
    var detail: WikiFilter.Detail?

    @Flag(help: "Titles and 상태 only. Same as --detail titles.")
    var titles = false

    @Flag(help: "Drop the 요약 column. The old name for --detail metadata.")
    var noSummary = false

    @Flag(help: "내 담당 · 진행중·대기 · 제목만. Uses the handle stored by --set-me.")
    var mine = false

    @Option(help: "Store the 담당 handle that 내 일감 means, and exit.")
    var setMe: String?

    @Flag(help: "Store the filter options given on this command line and exit.")
    var saveFilter = false

    func run() throws {
        if enable && disable {
            throw ValidationError("--enable 과 --disable 은 함께 쓸 수 없습니다.")
        }
        if mode != nil, enable || disable {
            throw ValidationError("--mode 와 --enable/--disable 은 함께 쓸 수 없습니다.")
        }

        if save {
            guard let root else { throw ValidationError("--save 는 --root 와 함께 씁니다.") }
            let expanded = NSString(string: root).expandingTildeInPath
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw CleanExit.message("폴더가 아닙니다: \(expanded)")
            }
            WikiSettings.rootPath = root
            WikiIndex.shared.invalidate()
            WikiContext.shared.invalidate()
            print("위키 폴더: \(WikiSettings.rootPath)")
            return
        }
        // `--mode` is the whole truth and `--enable/--disable` are the two shortcuts
        // people already have in their fingers, so they set the same value rather than
        // a parallel one that could disagree with it.
        if let mode {
            WikiSettings.mode = mode
            print("위키 참고: \(WikiSettings.mode.title)")
            return
        }
        if enable || disable {
            WikiSettings.mode = enable ? .auto : .off
            print("위키 참고: \(WikiSettings.mode.title)")
            return
        }
        if let setMe {
            WikiSettings.me = setMe
            print("내 담당: \(WikiSettings.me.isEmpty ? "(지움)" : WikiSettings.me)")
            return
        }
        // Better to stop than to quietly list everyone's work under the name 내 일감.
        if mine, WikiSettings.me.isEmpty {
            throw ValidationError("담당 핸들이 저장되어 있지 않습니다. --set-me <핸들> 로 먼저 지정하세요.")
        }

        let filter = resolvedFilter()
        if saveFilter {
            WikiSettings.filter = filter
            // A different filter is different content, so the next question has to
            // carry it even inside a conversation that already saw the old one.
            WikiSettings.clearSent()
            print("필터: \(WikiDigestRenderer.describe(filter))")
            return
        }

        let url = try resolvedRoot()
        let snapshot: WikiSnapshot
        do {
            snapshot = try WikiIndex.shared.snapshot(root: url, folders: resolvedFolders(filter), force: true)
        } catch let failure as WikiIndex.Failure {
            throw CleanExit.message(describe(failure))
        }

        let digest = WikiDigestRenderer.render(
            pages: snapshot.pages,
            filter: filter,
            rootName: url.lastPathComponent,
            budgetCharacters: budget ?? WikiSettings.budgetCharacters
        )

        if preview {
            print(digest.text)
            return
        }
        if json {
            try printJSON(filter.apply(to: snapshot.pages).kept)
            return
        }
        printStatus(url: url, snapshot: snapshot, filter: filter, digest: digest)
    }

    // MARK: - Resolving

    private func resolvedRoot() throws -> URL {
        let raw = root ?? WikiSettings.rootPath
        let expanded = NSString(string: raw).expandingTildeInPath
        guard !expanded.isEmpty else { throw CleanExit.message("위키 폴더가 설정되지 않았습니다.") }
        return URL(fileURLWithPath: expanded)
    }

    /// Command-line options override the stored filter one axis at a time, so
    /// `--status 완료` narrows the saved filter rather than replacing it wholesale.
    private func resolvedFilter() -> WikiFilter {
        var filter = WikiSettings.filter
        if !types.isEmpty { filter.types = Set(types) }
        if !statuses.isEmpty { filter.statuses = Set(statuses) }
        if !categories.isEmpty { filter.categories = Set(categories) }
        if !areas.isEmpty { filter.areas = Set(areas) }
        if !priorities.isEmpty { filter.priorities = Set(priorities) }
        // 미지정 is how a person says "the empty string" on a command line.
        if !assignees.isEmpty { filter.assignees = Set(assignees.map { $0 == "미지정" ? "" : $0 }) }
        if !folders.isEmpty { filter.folders = Set(folders) }
        if let search { filter.titleContains = search }
        if let stale { filter.staleDays = stale > 0 ? stale : nil }
        if let limit { filter.maxCount = limit }
        if let detail { filter.detail = detail }
        if titles { filter.detail = .titles }
        // Guarded, so `--titles --no-summary` does not promote titles back up to
        // metadata. The boolean this replaced could only ever say "not full".
        if noSummary, filter.detail == .full { filter.detail = .metadata }
        // Last, so it wins over the axes it sets.
        if mine {
            if !WikiSettings.me.isEmpty { filter.assignees = [WikiSettings.me] }
            filter.statuses = ["진행중", "대기"]
            filter.detail = .titles
        }
        return filter
    }

    /// Walk only what the filter can match. Folders the filter excludes are not worth
    /// the disk read, and `_private` is never in the list to begin with.
    private func resolvedFolders(_ filter: WikiFilter) -> [String] {
        let available = WikiIndex.indexableFolders + WikiIndex.optionalFolders
        guard !filter.folders.isEmpty else { return WikiIndex.indexableFolders }
        return available.filter(filter.folders.contains)
    }

    // MARK: - Output

    private func printStatus(url: URL, snapshot: WikiSnapshot, filter: WikiFilter, digest: WikiDigest) {
        print("경로     : \(WikiSettings.rootPath)")
        print("사용     : \(WikiSettings.mode.title)")
        print("필터     : \(WikiDigestRenderer.describe(filter))")
        print("정렬     : \(filter.sort.title) · 최대 \(filter.maxCount)건 · 상세 \(filter.detail.title)")
        print("스캔     : 파일 \(snapshot.scannedFiles)건 → 페이지 \(snapshot.pages.count)건" +
              (snapshot.skipped.isEmpty ? "" : " · 건너뜀 \(snapshot.skipped.count)건"))
        if snapshot.timedOut {
            print("경고     : 순회 한도에 걸려 일부만 읽었습니다.")
        }
        for path in snapshot.skipped.prefix(5) { print("  건너뜀 : \(path)") }

        let percent = Double(digest.characters) / Double(WikiSettings.budgetCharacters) * 100
        print("다이제스트: \(digest.matched)/\(digest.total)건 · \(digest.characters)자 · 예산의 \(Int(percent.rounded()))%")
        // The number that matters: what this costs the model. 96,000 is
        // context_guard.py's measured soft limit on the other side.
        let tokens = WikiDigestRenderer.approximateTokens(characters: digest.characters)
        print("            ≈ \(tokens) 토큰 · 96K 컨텍스트의 \(String(format: "%.1f", Double(tokens) / 960))%")
        if digest.wasTruncated {
            print("경고     : 예산 상한으로 \(digest.total - digest.matched)건이 빠졌습니다.")
        }
        if let sent = WikiSettings.sent {
            print("주입 기록: 대화 \(sent.conversationID.prefix(8))… · \(sent.count)회" +
                  (sent.digestHash == digest.hash ? " · 지금 내용과 동일(재주입 없음)" : " · 내용이 바뀜(다음 질문에 재주입)"))
        } else {
            print("주입 기록: 없음 (다음 질문에 주입됩니다)")
        }
    }

    private func printJSON(_ pages: [WikiPage]) throws {
        let rows = pages.map { page in
            [
                "basename": page.basename, "path": page.relativePath, "folder": page.folder,
                "유형": page.type, "상태": page.status, "분류": page.category,
                "우선순위": page.priority, "담당": page.assignee,
                "영역": page.areas.joined(separator: "·"),
                "생성일": page.created, "갱신일": page.updated, "요약": page.summary
            ]
        }
        let data = try JSONSerialization.data(
            withJSONObject: rows, options: [.prettyPrinted, .withoutEscapingSlashes]
        )
        print(String(decoding: data, as: UTF8.self))
    }

    private func describe(_ failure: WikiIndex.Failure) -> String {
        switch failure {
        case .noRoot:
            return "위키 폴더가 설정되지 않았습니다."
        case .missing(let path):
            return "폴더를 찾을 수 없습니다: \(path)"
        case .denied(let path):
            // The vault lives under ~/Desktop, which macOS gates even for an
            // unsandboxed app. Saying "not found" would send someone hunting for a
            // folder that is exactly where they left it.
            return "폴더에 접근할 수 없습니다: \(path)\n앱에서는 설정 창의 폴더 선택으로 다시 지정하면 권한이 붙습니다."
        }
    }
}

/// `RawRepresentable<String>` plus `CaseIterable` is all ArgumentParser needs -- it
/// gets the parsing and the value list in `--help` for free.
extension WikiFilter.Detail: ExpressibleByArgument {}
extension WikiSettings.Mode: ExpressibleByArgument {}
