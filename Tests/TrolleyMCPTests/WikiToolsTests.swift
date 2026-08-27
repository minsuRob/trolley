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
        // A fresh index per test, and a filter that constrains nothing, so what is
        // asserted is the tool's own behaviour rather than a stored setting.
        tools = WikiTools(
            index: WikiIndex(),
            rootURL: { [root = fixture.root] in root },
            storedFilter: { WikiFilter() },
            // Named rather than left to `WikiSettings.mode`: that reads the *test
            // process's* defaults, so what these assert would depend on whatever the
            // machine happened to have stored.
            mode: { .auto }
        )
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

    /// An agent asking for 완료 pages must not silently get the widget's 진행중 filter
    /// applied on top of its own request.
    func testSearchDoesNotInheritTheStoredFilter() throws {
        let narrow = WikiTools(
            index: WikiIndex(),
            rootURL: { [root = fixture.root] in root },
            storedFilter: { WikiFilter.default },   // 상태=진행중
            // Pinned for the reason `setUpWithError` pins it, and this is the case that
            // proved the reason: left to `WikiSettings.mode` it read the test process's
            // defaults, where a wiki checkout on the machine is now enough to resolve to
            // `.auto` -- which widens the default folders and puts a second page in the
            // result. 직접 지정 is the mode where a stored filter is in force at all, so
            // it is also the only one this test has anything to say about.
            mode: { .manual }
        )
        let result = try narrow.search(args(["status": .array([.string("완료")])]))
        let pages = strings(result, "pages")
        XCTAssertEqual(pages.count, 1)
        XCTAssertTrue(pages[0].contains("[[끝난 일감]]"))
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

    /// 직접 지정 keeps the stored folder choice as the default, because in that mode it
    /// is a choice somebody actually made.
    func testManualModeStaysInTheConfiguredFolders() throws {
        let manual = WikiTools(
            index: WikiIndex(),
            rootURL: { [root = fixture.root] in root },
            storedFilter: { WikiFilter(folders: ["context/tasks"]) },
            mode: { .manual }
        )
        let pages = strings(try manual.search(args([:])), "pages")
        XCTAssertFalse(pages.contains { $0.contains("2026-07-05 회의") }, pages.description)
        XCTAssertEqual(pages.count, 2)
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

    // MARK: - No wiki

    func testMissingRootIsReportedAsUnavailable() {
        let orphan = WikiTools(index: WikiIndex(), rootURL: { nil }, storedFilter: { WikiFilter() })
        XCTAssertThrowsError(try orphan.search(args([:]))) { error in
            XCTAssertEqual((error as? ToolError)?.code, .wikiUnavailable)
        }
    }
}
