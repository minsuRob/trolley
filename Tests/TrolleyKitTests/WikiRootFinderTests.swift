import XCTest
@testable import TrolleyKit

final class WikiRootFinderTests: XCTestCase {
    func testFindReturnsFirstCandidateThatLooksLikeAWiki() {
        let found = WikiRootFinder.find(
            search: { ["/not/a/wiki", "/real/wiki", "/also/not"] },
            isWikiRoot: { $0.path == "/real/wiki" }
        )
        XCTAssertEqual(found?.path, "/real/wiki")
    }

    func testFindSkipsCandidatesThatArentWikiRoots() {
        let found = WikiRootFinder.find(
            search: { ["/decoy/one", "/decoy/two"] },
            isWikiRoot: { _ in false }
        )
        XCTAssertNil(found)
    }

    func testFindReturnsNilWhenSearchIsEmpty() {
        let found = WikiRootFinder.find(search: { [] }, isWikiRoot: { _ in true })
        XCTAssertNil(found)
    }

    func testFindIgnoresEmptyLinesFromSearchOutput() {
        let found = WikiRootFinder.find(
            search: { ["", "/real/wiki"] },
            isWikiRoot: { $0.path == "/real/wiki" }
        )
        XCTAssertEqual(found?.path, "/real/wiki")
    }

    /// End to end with the real validation `WikiSettings.isWikiRoot` does, against a
    /// throwaway fixture rather than the vault a person is actually editing.
    func testFindUsesWikiSettingsValidationByDefault() throws {
        let fixture = try WikiFixture()
        try fixture.task("일감")

        let found = WikiRootFinder.find(search: { [fixture.root.path] })
        XCTAssertEqual(found?.path, fixture.root.path)
    }

    func testFindWithDefaultValidationRejectsAFolderWithNoWikiLayout() throws {
        let fixture = try WikiFixture()

        let found = WikiRootFinder.find(search: { [fixture.root.path] })
        XCTAssertNil(found)
    }
}
