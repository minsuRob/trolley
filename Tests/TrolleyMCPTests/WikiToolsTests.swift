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
            storedFilter: { WikiFilter() }
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

    func testSearchWithNoArgumentsReturnsEverything() throws {
        let result = try tools.search(args([:]))
        XCTAssertEqual(strings(result, "pages").count, 2)
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
            storedFilter: { WikiFilter.default }   // 상태=진행중
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
        XCTAssertEqual(object["total"], .int(2))
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
