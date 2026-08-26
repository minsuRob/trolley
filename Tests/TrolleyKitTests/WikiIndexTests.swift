import XCTest
@testable import TrolleyKit

/// A throwaway wiki on disk.
///
/// Never the real one: `~/Desktop/workspace/MAKi/markhub-llm-wiki` is edited daily by
/// people, and a test that reads it fails on somebody else's commit. Everything
/// hazardous about that tree is reproduced here instead, deliberately.
final class WikiFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wiki-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func write(_ relativePath: String, _ contents: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    func writeRaw(_ relativePath: String, _ bytes: [UInt8]) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(bytes).write(to: url)
    }

    func symlink(_ relativePath: String, to target: URL) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
    }

    func task(
        _ name: String, status: String = "진행중", assignee: String = "minsuRob",
        areas: String = "web", summary: String = "요약"
    ) throws {
        try write("context/tasks/\(name).md", """
            ---
            유형: 일감
            상태: \(status)
            분류: 기능
            영역: \(areas)
            우선순위: 중간
            담당: \(assignee)
            생성일: 2026-07-01
            갱신일: 2026-07-02
            요약: "\(summary)"
            출처: []
            ---

            # \(name)
            """)
    }
}

final class WikiIndexTests: XCTestCase {
    private var fixture: WikiFixture!
    private var cache: [String: (modified: Date, page: WikiPage?)] = [:]

    override func setUpWithError() throws {
        fixture = try WikiFixture()
        cache = [:]
    }

    override func tearDown() {
        fixture = nil
    }

    private func walk(_ folders: [String] = WikiIndex.indexableFolders) throws -> WikiSnapshot {
        try WikiIndex.walk(root: fixture.root, folders: folders, cache: &cache)
    }

    // MARK: - What gets indexed

    func testIndexesPagesWithFrontmatter() throws {
        try fixture.task("첫 일감")
        try fixture.task("둘째 일감")
        let snapshot = try walk()
        XCTAssertEqual(snapshot.pages.count, 2)
        XCTAssertEqual(Set(snapshot.pages.map(\.basename)), ["첫 일감", "둘째 일감"])
        XCTAssertEqual(snapshot.pages.first?.folder, "context/tasks")
    }

    /// The mechanism, not an error: 20 files in the real vault have no frontmatter and
    /// are more than half its bytes.
    func testFileWithoutFrontmatterIsCountedButNotIndexed() throws {
        try fixture.task("진짜 일감")
        try fixture.write("context/tasks/INDEX.md", "# INDEX\n\n| 상태 | 분류 |\n|---|---|\n")
        let snapshot = try walk()
        XCTAssertEqual(snapshot.scannedFiles, 2, "본 파일 수는 둘 다 세어야 한다")
        XCTAssertEqual(snapshot.pages.count, 1, "인덱싱은 프론트매터가 있는 것만")
        XCTAssertTrue(snapshot.skipped.isEmpty, "프론트매터가 없는 것은 실패가 아니다")
    }

    func testNonMarkdownFilesAreIgnored() throws {
        try fixture.task("일감")
        try fixture.write("context/tasks/notes.txt", "---\n유형: 일감\n---\n")
        let snapshot = try walk()
        XCTAssertEqual(snapshot.scannedFiles, 1)
    }

    // MARK: - Exclusions the vault's own rules demand

    /// `_private` is excluded in code rather than by a filter default. A rule that can
    /// be toggled is a rule that eventually gets toggled.
    func testPrivateFolderIsNeverWalked() throws {
        try fixture.task("공개")
        try fixture.write("context/tasks/_private/비밀.md", "---\n유형: 일감\n상태: 진행중\n---\n")
        let snapshot = try walk()
        XCTAssertEqual(snapshot.pages.map(\.basename), ["공개"])
    }

    func testFoldersOutsideTheRequestedListAreNotWalked() throws {
        try fixture.task("일감")
        try fixture.write("members/minsuRob/daily/2026-07-16.md", "---\n유형: 데일리\n날짜: 2026-07-16\n---\n")
        XCTAssertEqual(try walk().pages.count, 1, "members 는 기본 목록에 없다")
        XCTAssertEqual(
            try walk(WikiIndex.indexableFolders + ["members"]).pages.count, 2,
            "명시하면 걸어야 한다"
        )
    }

    func testMissingFolderIsSkippedRatherThanFatal() throws {
        try fixture.task("일감")
        // context/concepts does not exist in this fixture.
        XCTAssertEqual(try walk().pages.count, 1)
    }

    // MARK: - Hazards

    /// The real vault has `.agents/skills` pointing back into itself. Following links
    /// is how a walk of a finite tree becomes infinite.
    func testSymlinkIsNotFollowed() throws {
        try fixture.task("일감")
        try fixture.symlink("context/tasks/순환", to: fixture.root)
        let snapshot = try walk()
        XCTAssertEqual(snapshot.pages.map(\.basename), ["일감"])
        XCTAssertFalse(snapshot.timedOut, "순환을 따라갔다면 한도에 걸렸을 것이다")
    }

    func testSymlinkToARealPageIsAlsoSkipped() throws {
        try fixture.task("진짜")
        try fixture.symlink(
            "context/tasks/사본.md",
            to: fixture.root.appendingPathComponent("context/tasks/진짜.md")
        )
        XCTAssertEqual(try walk().pages.map(\.basename), ["진짜"])
    }

    /// Filenames in the real vault carry spaces, parentheses, middle dots, and one
    /// double dot. Everything here goes through URL, never a shell.
    func testAwkwardFilenamesSurvive() throws {
        try fixture.task("마크 타임라인 활동 bump (web · mobile)")
        try fixture.task("YC 지원서 v9 리뷰·질문 리스트 보충")
        try fixture.write("context/tasks/핵심요소..md", "---\n유형: 개념\n요약: \"이중 점\"\n---\n")
        let names = Set(try walk().pages.map(\.basename))
        XCTAssertTrue(names.contains("마크 타임라인 활동 bump (web · mobile)"))
        XCTAssertTrue(names.contains("YC 지원서 v9 리뷰·질문 리스트 보충"))
        XCTAssertTrue(names.contains("핵심요소."), "이중 점은 마지막 .md 만 벗겨야 한다")
    }

    /// One unreadable file must not take the index down with it, and must not vanish
    /// silently either -- `skipped` is what the setup row reports.
    func testUndecodableBytesDoNotAbortTheWalk() throws {
        try fixture.task("멀쩡한 일감")
        try fixture.writeRaw("context/tasks/깨진.md", [0xFF, 0xFE, 0xFF, 0xFE, 0x00, 0x41])
        let snapshot = try walk()
        XCTAssertTrue(snapshot.pages.contains { $0.basename == "멀쩡한 일감" })
        XCTAssertEqual(snapshot.scannedFiles, 2)
    }

    /// A page whose frontmatter is fine but whose body is enormous costs the
    /// frontmatter, not the file. This is the entire point of the feature.
    func testOnlyTheHeadOfAFileIsRead() throws {
        try fixture.write("context/tasks/거대.md", """
            ---
            유형: 일감
            상태: 진행중
            요약: "앞부분"
            ---

            """ + String(repeating: "본문이 아주 길다. ", count: 20_000))
        let page = try XCTUnwrap(try walk().pages.first)
        XCTAssertEqual(page.summary, "앞부분")

        let size = try FileManager.default
            .attributesOfItem(atPath: page.path)[.size] as? Int ?? 0
        XCTAssertGreaterThan(size, 200_000, "픽스처가 충분히 커야 시험이 성립한다")
        let head = try XCTUnwrap(WikiIndex.head(of: URL(fileURLWithPath: page.path), bytes: WikiIndex.maxBytesPerFile))
        XCTAssertLessThanOrEqual(head.utf8.count, WikiIndex.maxBytesPerFile)
    }

    // MARK: - Failures

    func testMissingRootThrowsMissing() {
        let gone = fixture.root.appendingPathComponent("없는-폴더")
        var scratch: [String: (modified: Date, page: WikiPage?)] = [:]
        XCTAssertThrowsError(try WikiIndex.walk(root: gone, folders: ["context/tasks"], cache: &scratch)) { error in
            XCTAssertEqual(error as? WikiIndex.Failure, .missing(gone.path))
        }
    }

    // MARK: - Cache

    /// Memoising "this file has no frontmatter" is what makes the 21KB `INDEX.md` cost
    /// one read for the life of the process instead of one per walk.
    func testUnchangedFilesAreServedFromCacheIncludingTheOnesWithNoFrontmatter() throws {
        try fixture.task("일감")
        try fixture.write("context/tasks/INDEX.md", "# INDEX\n")
        _ = try walk()
        XCTAssertEqual(cache.count, 2)
        XCTAssertNotNil(cache.values.first { $0.page == nil }, "프론트매터 없음도 기억해야 한다")

        // Delete the bodies out from under the cache: a second walk that still returns
        // the pages proves it did not re-read them.
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("context/tasks/일감.md"))
        let second = try WikiIndex.walk(root: fixture.root, folders: WikiIndex.indexableFolders, cache: &cache)
        XCTAssertEqual(second.pages.count, 0, "사라진 파일은 순회에서 아예 안 보인다")
    }

    func testEditedFileIsReparsed() throws {
        try fixture.task("일감", status: "진행중")
        XCTAssertEqual(try walk().pages.first?.status, "진행중")

        // mtime has one-second granularity on some filesystems, so move it explicitly
        // rather than racing it.
        let url = fixture.root.appendingPathComponent("context/tasks/일감.md")
        try fixture.task("일감", status: "완료")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: url.path
        )
        XCTAssertEqual(try walk().pages.first?.status, "완료")
    }
}
