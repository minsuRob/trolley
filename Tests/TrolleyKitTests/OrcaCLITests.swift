import XCTest
@testable import TrolleyKit

final class OrcaCLITests: XCTestCase {
    /// A real `orca terminal list --json` response, trimmed to two terminals --
    /// one live, one orphaned (`"title": null`). Live against a real orca
    /// instance, every `list` call that had run long enough to accumulate a
    /// detached pty made `parseTerminals` return nil (a non-optional `String`
    /// title failed the whole array's decode on the null), so "Claude 호출"
    /// with orca checked always reported "창 목록을 읽지 못했습니다" even with
    /// idle Claude Code panes sitting right there.
    static let listJSON = """
    {
      "id": "x", "ok": true,
      "result": {
        "terminals": [
          {
            "handle": "term_live", "title": "✳ Claude Code", "orphaned": false,
            "connected": true, "writable": true
          },
          {
            "handle": "term_orphan", "title": null, "orphaned": true,
            "connected": true, "writable": true
          }
        ],
        "totalCount": 2, "truncated": false
      }
    }
    """

    func testAnOrphanedTerminalWithANullTitleDoesNotFailTheWholeList() {
        let terminals = OrcaCLI.parseTerminals(Self.listJSON)
        XCTAssertEqual(terminals?.count, 2)
    }

    func testOrphanedTerminalsAreFlaggedAndTitleFallsBackToEmpty() {
        let terminals = OrcaCLI.parseTerminals(Self.listJSON)
        let orphan = terminals?.first { $0.handle == "term_orphan" }
        XCTAssertEqual(orphan?.orphaned, true)
        XCTAssertEqual(orphan?.title, "")
    }

    func testALiveTerminalDecodesNormally() {
        let terminals = OrcaCLI.parseTerminals(Self.listJSON)
        let live = terminals?.first { $0.handle == "term_live" }
        XCTAssertEqual(live?.orphaned, false)
        XCTAssertEqual(live?.title, "✳ Claude Code")
    }

    func testTailParsesFromARealReadResponse() {
        let json = """
        {"id": "x", "ok": true, "result": {"terminal": {"tail": ["a", "b", "❯"]}}}
        """
        XCTAssertEqual(OrcaCLI.parseTail(json), ["a", "b", "❯"])
    }
}
