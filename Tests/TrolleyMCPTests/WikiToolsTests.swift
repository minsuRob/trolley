import XCTest
@testable import TrolleyKit
@testable import TrolleyMCP

/// A small wiki on disk. Never the real one -- those files are edited daily by people,
/// and a test that reads them fails on somebody else's commit.
private final class ToolFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wiki-tools-\(UUID().uuidString)")
        try write("context/tasks/첫 일감.md", """
            ---
            유형: 일감
            상태: 진행중
            분류: 버그
            영역:
              - web
              - be
            우선순위: 최우선
            담당: minsuRob
            생성일: 2026-07-01
            갱신일: 2026-07-09
            요약: "첫 일감의 요약"
            ---

            # 첫 일감

            ## 배경
            본문이 여기 있다.

            ## 현황
            """ + String(repeating: "길게 이어지는 본문. ", count: 40))
        try write("context/tasks/끝난 일감.md", """
            ---
            유형: 일감
            상태: 완료
            분류: 기능
            영역: mobile
            우선순위: 중간
            담당: songjein
            생성일: 2026-07-02
            갱신일: 2026-07-10
            요약: "끝난 일감의 요약"
            ---

            # 끝난 일감
            """)
        try write("logs/2026-07-05 회의.md", """
            ---
            유형: 회의
            상태: 완료
            생성일: 2026-07-05
            갱신일: 2026-07-05
            요약: "스프린트 회고"
            ---

            # 회의록
            """)
        try write("_private/비밀.md", """
            ---
            유형: 일감
            상태: 진행중
            요약: "읽히면 안 되는 것"
            ---

            # 비밀
            """)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    private func write(_ path: String, _ contents: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}

final class WikiToolsTests: XCTestCase {
    private var fixture: ToolFixture!
    private var tools: WikiTools!

    override func setUpWithError() throws {
        fixture = try ToolFixture()
        // A fresh index per test, so what is asserted is the tool's own behaviour.
        //
        // Nothing to pin any more: `WikiTools` used to take the stored filter and the
        // mode, both of which read the *test process's* defaults by default, and a test
        // that forgot to name them passed or failed on what the machine had stored. It
        // now takes a root and nothing else.
        tools = WikiTools(index: WikiIndex(), rootURL: { [root = fixture.root] in root })
    }

    override func tearDown() {
        tools = nil
        fixture = nil
    }

    private func args(_ dictionary: [String: JSONValue]) -> Arguments {
        Arguments(.object(dictionary))
    }

    private func strings(_ result: JSONValue, _ key: String) -> [String] {
        guard case .object(let object) = result, case .array(let items)? = object[key] else { return [] }
        return items.compactMap(\.stringValue)
    }

    // MARK: - Registration

    func testBothToolsAreDefined() {
        XCTAssertEqual(WikiTools.definitions.map(\.name), ["wiki_search", "wiki_read"])
    }

    /// The local model has no tool-calling API, so `ToolCallContract` says the catalog in
    /// prose and `ToolSummary.signature` renders these parameter names straight into the
    /// prompt as the call signature. When they drift from the schema the model is being
    /// told to make a call that `WikiTools` rejects, with no way to find that out -- which
    /// is exactly what `wiki_read(path)` against a schema taking `title` was doing.
    func testCatalogParameterNamesExistInTheSchemas() throws {
        let provider = TrolleyTools(
            trustChecker: FakeTrustChecker(),
            locator: FakeAppLocator(),
            makeKeyPoster: { _ in FakeKeyPoster() },
            makeRoot: { _, _ in FakeElement() },
            activateApp: { _ in true },
            listRunningApps: { [] },
            wiki: tools
        )
        let catalog = TrolleyToolRunner(tools: provider).toolCatalog
        for definition in WikiTools.definitions {
            let summary = try XCTUnwrap(
                catalog.first { $0.name == definition.name },
                "\(definition.name) 이 카탈로그에 없다"
            )
            guard case .object(let schema) = definition.inputSchema,
                  case .object(let properties)? = schema["properties"] else {
                return XCTFail("\(definition.name) 스키마 모양이 다르다")
            }
            for parameter in summary.parameters {
                XCTAssertNotNil(
                    properties[parameter],
                    "\(definition.name)(\(parameter)) — 스키마에 없는 인자를 모델에게 알려주고 있다"
                )
            }
        }
    }

    /// A listed tool that cannot work costs the model a call to find that out, so the
    /// pair is absent rather than broken when no wiki is injected.
    func testToolsAreAbsentWhenNoWikiIsInjected() {
        let provider = TrolleyTools(
            trustChecker: FakeTrustChecker(),
            locator: FakeAppLocator(),
            makeKeyPoster: { _ in FakeKeyPoster() },
            makeRoot: { _, _ in FakeElement() },
            activateApp: { _ in true },
            listRunningApps: { [] },
            wiki: nil
        )
        XCTAssertFalse(provider.tools.contains { $0.name.hasPrefix("wiki_") })
    }

    func testToolsAppearWhenAWikiIsInjected() {
        let provider = TrolleyTools(
            trustChecker: FakeTrustChecker(),
            locator: FakeAppLocator(),
            makeKeyPoster: { _ in FakeKeyPoster() },
            makeRoot: { _, _ in FakeElement() },
            activateApp: { _ in true },
            listRunningApps: { [] },
            wiki: tools
        )
        XCTAssertTrue(provider.tools.contains { $0.name == "wiki_search" })
        XCTAssertTrue(provider.tools.contains { $0.name == "wiki_read" })
    }

    // MARK: - wiki_search

    /// Three: the two tasks and the meeting note under `logs/`, which 자동 reaches.
    func testSearchWithNoArgumentsReturnsEverything() throws {
        let result = try tools.search(args([:]))
        XCTAssertEqual(strings(result, "pages").count, 3)
    }

    func testSearchFiltersByStatus() throws {
        let result = try tools.search(args(["status": .array([.string("진행중")])]))
        let pages = strings(result, "pages")
        XCTAssertEqual(pages.count, 1)
        XCTAssertTrue(pages[0].contains("[[첫 일감]]"))
    }

    func testSearchMatchesAnyOfAPagesAreas() throws {
        XCTAssertEqual(strings(try tools.search(args(["area": .array([.string("be")])])), "pages").count, 1)
        XCTAssertEqual(strings(try tools.search(args(["area": .array([.string("없는영역")])])), "pages").count, 0)
    }

    /// An agent asking for 완료 pages must not get the options window's 진행중 filter
    /// applied on top of its request. Structural now -- the tool cannot see that filter
    /// at all -- and asserted anyway, because "cannot see it" is the property that matters
    /// and it is one constructor argument away from being untrue again.
    func testSearchDoesNotInheritTheStoredFilter() throws {
        let narrow = WikiTools(index: WikiIndex(), rootURL: { [root = fixture.root] in root })
        let pages = strings(try narrow.search(args(["status": .array([.string("완료")])])), "pages")
        // Both 완료 pages, and one of them is in `logs/`. That page used to be reachable
        // only under 자동 -- the stored folder set narrowed the *walk*, so a call that
        // asked for nothing but a status got whatever folders somebody picked last week.
        XCTAssertEqual(pages.count, 2, "\(pages)")
        XCTAssertTrue(pages.contains { $0.contains("[[끝난 일감]]") }, "\(pages)")
        XCTAssertTrue(pages.contains { $0.contains("[[2026-07-05 회의]]") }, "\(pages)")
    }

    func testSearchReportsWhatItTruncated() throws {
        let result = try tools.search(args(["limit": .int(1)]))
        guard case .object(let object) = result else { return XCTFail("객체가 아니다") }
        XCTAssertEqual(object["matched"], .int(1))
        XCTAssertEqual(object["total"], .int(3))
    }

    /// The call the model makes when it does not yet know what the vault holds.
    ///
    /// Its shape is different from a filtered search's on purpose: `.full` at 40 pages
    /// is ~5,000 characters and `ToolCallContract.resultMessage` truncates the result at
    /// 4,000, so a first look would come back cut off partway down the list -- the one
    /// case where returning *more* pages is what makes the answer fit.
    func testUnfilteredSearchReturnsTheWholeBoardAsTitles() throws {
        let result = try tools.search(args([:]))
        guard case .object(let object) = result else { return XCTFail("객체가 아니다") }
        XCTAssertEqual(object["detail"], .string("titles"))
        // 요약 is what `.full` adds, and no line may carry it here.
        XCTAssertFalse(strings(result, "pages").contains { $0.contains("첫 일감의 요약") })
    }

    /// A search that narrowed something is looking for a page, not for the map, and
    /// wants everything known about the few it found.
    func testFilteredSearchKeepsTheFullLine() throws {
        let result = try tools.search(args(["status": .array([.string("진행중")])]))
        guard case .object(let object) = result else { return XCTFail("객체가 아니다") }
        XCTAssertEqual(object["detail"], .string("full"))
        XCTAssertTrue(strings(result, "pages").contains { $0.contains("첫 일감의 요약") })
    }

    /// The folder axis has to move the *walk*, not just filter its result. It used to
    /// filter only: `wiki_search` always walked `context/**`, so no argument could
    /// reach a page under `logs/` or `members/` and the model was told it did not exist.
    func testFolderAxisReachesLogsAndMembers() throws {
        let pages = strings(try tools.search(args(["folder": .array([.string("logs")])])), "pages")
        XCTAssertEqual(pages.count, 1)
        XCTAssertTrue(pages[0].contains("[[2026-07-05 회의]]"), pages[0])
    }

    /// 자동 means the person is not standing between the question and the vault, so the
    /// optional folders are in reach without being asked for by name.
    func testAutoModeSeesTheOptionalFoldersByDefault() throws {
        XCTAssertTrue(strings(try tools.search(args([:])), "pages").contains { $0.contains("2026-07-05 회의") })
    }

    /// `sort` was one of the two axes the old implementation inherited from the stored
    /// filter and never let the caller set.
    func testSortIsTheCallersToChoose() throws {
        let pages = strings(try tools.search(args([
            "type": .array([.string("일감")]), "sort": .string("recent")
        ])), "pages")
        XCTAssertEqual(pages.count, 2)
        XCTAssertTrue(pages[0].contains("[[끝난 일감]]"), pages.description)
    }

    /// The vault's own rules exclude `_private` from every index and search.
    func testSearchNeverReachesPrivatePages() throws {
        let pages = strings(try tools.search(args([:])), "pages")
        XCTAssertFalse(pages.contains { $0.contains("비밀") })
    }

    // MARK: - wiki_read

    func testReadReturnsTheBody() throws {
        let result = try tools.read(args(["title": .string("첫 일감")]))
        guard case .object(let object) = result else { return XCTFail("객체가 아니다") }
        XCTAssertEqual(object["title"], .string("첫 일감"))
        XCTAssertTrue(object["body"]?.stringValue?.contains("본문이 여기 있다") == true)
        XCTAssertEqual(object["truncated"], .bool(false))
    }

    /// Titles come back from `wiki_search` wrapped in `[[…]]`, so they have to be
    /// accepted back in that form rather than the model being made to strip them.
    func testReadAcceptsATitleStillWrappedInBrackets() throws {
        let result = try tools.read(args(["title": .string("[[첫 일감]]")]))
        guard case .object(let object) = result else { return XCTFail("객체가 아니다") }
        XCTAssertEqual(object["title"], .string("첫 일감"))
    }

    func testReadTruncatesAndSaysSo() throws {
        let result = try tools.read(args(["title": .string("첫 일감"), "maxCharacters": .int(200)]))
        guard case .object(let object) = result else { return XCTFail("객체가 아니다") }
        XCTAssertEqual(object["truncated"], .bool(true))
        XCTAssertTrue(object["body"]?.stringValue?.hasSuffix("…(잘림)") == true)
    }

    /// Not a blocked traversal -- there is nothing to block. The title is looked up in
    /// the index and only the matching record's own path is ever opened, so a string
    /// like this is simply a page that does not exist.
    func testReadCannotEscapeTheWiki() {
        for attempt in ["../../../../etc/passwd", "/etc/passwd", "context/tasks/첫 일감"] {
            XCTAssertThrowsError(try tools.read(args(["title": .string(attempt)]))) { error in
                XCTAssertEqual((error as? ToolError)?.code, .wikiPageNotFound, "허용됨: \(attempt)")
            }
        }
    }

    func testReadCannotReachAPrivatePage() {
        XCTAssertThrowsError(try tools.read(args(["title": .string("비밀")]))) { error in
            XCTAssertEqual((error as? ToolError)?.code, .wikiPageNotFound)
        }
    }

    func testUnknownTitleHintsAtSearchingFirst() {
        XCTAssertThrowsError(try tools.read(args(["title": .string("없는 페이지")]))) { error in
            XCTAssertTrue((error as? ToolError)?.hint?.contains("wiki_search") == true)
        }
    }

    // MARK: - Fitting one tool result

    /// The defect this budget exists for. A tool result is truncated at 4,000 characters
    /// by `ToolCallContract.resultMessage`, and what gets truncated is this object's
    /// JSON -- the cut lands inside `pages`, `total` sorts after it and never arrives,
    /// and `matched` does, so the model is handed a count for a list it did not receive.
    func testAListTooLongToSendIsShortenedRatherThanCut() {
        let lines = (0..<400).map { "- [[문서 \($0)]] · 진행중" }
        let fitted = WikiTools.fit(lines, budget: WikiTools.resultBudget)
        XCTAssertLessThan(fitted.count, lines.count)
        // The wrapper counts too: every line lands in JSON inside quotes and a comma.
        let spent = fitted.reduce(0) { $0 + $1.count + 3 }
        XCTAssertLessThanOrEqual(spent, WikiTools.resultBudget)
        // A prefix, not a sample -- the sort already answered "what matters first".
        XCTAssertEqual(Array(lines.prefix(fitted.count)), fitted)
    }

    /// An empty list reads as "no such pages", which is a different and much worse
    /// answer than "here is one, and there are more".
    func testOneLineTooLongForTheBudgetStillComesBack() {
        let huge = String(repeating: "가", count: WikiTools.resultBudget * 2)
        XCTAssertEqual(WikiTools.fit([huge], budget: WikiTools.resultBudget), [huge])
    }

    /// What the model can act on. Being handed a short list is fine; being handed one
    /// with no way to know it is short is what produced "그런 문서 없습니다".
    func testTheNoteSaysWhatIsMissingAndHowToAskAgain() {
        let note = WikiTools.note(shown: 115, total: 241, detail: .titles)
        XCTAssertTrue(note.contains("241"), note)
        XCTAssertTrue(note.contains("115"), note)
        XCTAssertTrue(note.contains("folder"), note)
        // Only worth saying when there is a cheaper shape to ask for.
        XCTAssertFalse(note.contains("detail=titles"), note)
        XCTAssertTrue(WikiTools.note(shown: 1, total: 2, detail: .full).contains("detail=titles"))
    }

    /// `total` is the count the note is about, so it has to survive a shortened list --
    /// and `matched` has to describe what was actually sent, not what matched.
    func testAShortenedResultReportsBothCountsAndSaysSo() throws {
        let result = try tools.search(args(["limit": .int(1)]))
        guard case .object(let object) = result else { return XCTFail("객체가 아니다") }
        XCTAssertEqual(object["matched"], .int(1))
        XCTAssertEqual(object["total"], .int(3))
        XCTAssertNotNil(object["note"])
    }

    /// Nothing left out, nothing to say. A note on a complete list would teach the model
    /// to narrow a search that already answered the question.
    func testACompleteResultCarriesNoNote() throws {
        guard case .object(let object) = try tools.search(args([:])) else {
            return XCTFail("객체가 아니다")
        }
        XCTAssertEqual(object["matched"], object["total"])
        XCTAssertNil(object["note"])
    }

    // MARK: - No wiki

    func testMissingRootIsReportedAsUnavailable() {
        let orphan = WikiTools(index: WikiIndex(), rootURL: { nil })
        XCTAssertThrowsError(try orphan.search(args([:]))) { error in
            XCTAssertEqual((error as? ToolError)?.code, .wikiUnavailable)
        }
    }
}

/// The runner the wiki window's prompt talks through.
final class WikiToolRunnerTests: XCTestCase {
    /// The separation, asserted. A model asked about a wiki page has no business being
    /// told it can press ⌘T -- and the catalog is read from the top, which is why the
    /// screen tools used to have to be *worked around* by prepending the wiki pair.
    func testTheCatalogIsTheTwoWikiToolsAndNothingElse() {
        let names = WikiToolRunner().toolCatalog.map(\.name)
        XCTAssertEqual(names, ["wiki_search", "wiki_read"])
    }

    /// The contract prints these as "지금 실행 중인 앱". Naming this Mac's apps to a model
    /// that cannot touch any of them invites it to answer a wiki question about Chrome.
    func testItNamesNoRunningApps() {
        XCTAssertTrue(WikiToolRunner().runningAppSummaries.isEmpty)
    }

    /// The names in the catalog have to be the ones dispatch answers to: a summary is
    /// rendered into the prompt as the call signature, so a name only one side knows is
    /// an instruction to make a call that always fails.
    func testEveryAdvertisedToolIsOneItRuns() throws {
        let fixture = try ToolFixture()
        let runner = WikiToolRunner(
            wiki: WikiTools(index: WikiIndex(), rootURL: { [root = fixture.root] in root })
        )
        for name in runner.toolCatalog.map(\.name) {
            let done = expectation(description: name)
            // `wiki_read` without a title is a failed *call*, not an unknown tool -- what
            // is being asserted is that dispatch recognises the name at all.
            runner.run(name: name, arguments: [:]) { result in
                XCTAssertFalse(result.contains("Unknown tool"), "\(name): \(result)")
                done.fulfill()
            }
            wait(for: [done], timeout: 5)
        }
    }
}
