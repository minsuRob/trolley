import XCTest
@testable import TrolleyKit

final class SSELineParserTests: XCTestCase {
    /// The blank line is the dispatch, not the newline after `data:`. Getting
    /// this wrong is silent: every field arrives and no frame ever does.
    func testDispatchesOnBlankLine() {
        var parser = SSELineParser()
        XCTAssertNil(parser.feed("event: token"))
        XCTAssertNil(parser.feed("data: {\"text\":\"hi\"}"))
        XCTAssertEqual(
            parser.feed(""),
            SSEFrame(event: "token", data: "{\"text\":\"hi\"}")
        )
    }

    func testCommentLineIsIgnored() {
        var parser = SSELineParser()
        // What this server sends every 30 seconds while a job waits its turn.
        XCTAssertNil(parser.feed(": keepalive"))
        XCTAssertNil(parser.feed(""))
    }

    func testBlankLineWithoutDataDispatchesNothing() {
        var parser = SSELineParser()
        XCTAssertNil(parser.feed("event: done"))
        XCTAssertNil(parser.feed(""))
    }

    func testEventDefaultsToMessage() {
        var parser = SSELineParser()
        XCTAssertNil(parser.feed("data: bare"))
        XCTAssertEqual(parser.feed(""), SSEFrame(event: "message", data: "bare"))
    }

    func testStripsOnlyOneLeadingSpaceAndTrailingCR() {
        var parser = SSELineParser()
        XCTAssertNil(parser.feed("event: token\r"))
        XCTAssertNil(parser.feed("data:  two spaces\r"))
        XCTAssertEqual(parser.feed("\r"), SSEFrame(event: "token", data: " two spaces"))
    }

    func testMultipleDataLinesJoinWithNewline() {
        var parser = SSELineParser()
        XCTAssertNil(parser.feed("data: one"))
        XCTAssertNil(parser.feed("data: two"))
        XCTAssertEqual(parser.feed(""), SSEFrame(event: "message", data: "one\ntwo"))
    }

    func testStateResetsBetweenFrames() {
        var parser = SSELineParser()
        _ = parser.feed("event: start")
        _ = parser.feed("data: a")
        _ = parser.feed("")
        _ = parser.feed("data: b")
        // Without a reset this would still claim to be a `start`.
        XCTAssertEqual(parser.feed(""), SSEFrame(event: "message", data: "b"))
    }
}

final class LocalLLMSettingsTests: XCTestCase {
    func testAssumesHTTPSWhenNoSchemeGiven() {
        XCTAssertEqual(
            LocalLLMSettings.normalize("host.tailnet.ts.net:8443")?.absoluteString,
            "https://host.tailnet.ts.net:8443"
        )
    }

    func testKeepsAnExplicitScheme() {
        XCTAssertEqual(
            LocalLLMSettings.normalize("http://192.168.0.10:8842")?.absoluteString,
            "http://192.168.0.10:8842"
        )
    }

    func testDropsTrailingSlashes() {
        XCTAssertEqual(
            LocalLLMSettings.normalize("https://example.ts.net:8443///")?.absoluteString,
            "https://example.ts.net:8443"
        )
    }

    func testRejectsEmptyAndHostlessInput() {
        XCTAssertNil(LocalLLMSettings.normalize("   "))
        XCTAssertNil(LocalLLMSettings.normalize("https://"))
    }

    /// The shipped default has to survive its own normalizer, or the setup row
    /// would report a broken address nobody typed.
    func testFallbackNormalizesToItself() {
        XCTAssertEqual(
            LocalLLMSettings.normalize(LocalLLMSettings.fallbackBaseURL)?.absoluteString,
            LocalLLMSettings.fallbackBaseURL
        )
    }
}

final class LocalLLMSessionStatusTests: XCTestCase {
    func testQueuedBehindNobodyReadsAsSending() {
        XCTAssertEqual(
            LocalLLMSession.statusLine(for: .queued(position: 0), backend: nil),
            "보내는 중…"
        )
    }

    func testQueuedBehindOthersNamesTheWait() {
        XCTAssertEqual(
            LocalLLMSession.statusLine(for: .queued(position: 2), backend: nil),
            "대기 중 — 앞에 2건"
        )
    }

    func testGeneratingNamesTheBackendWhenKnown() {
        XCTAssertEqual(
            LocalLLMSession.statusLine(for: .generating, backend: "local-diffusiongemma"),
            "생성 중 — local-diffusiongemma"
        )
        XCTAssertEqual(LocalLLMSession.statusLine(for: .generating, backend: nil), "생성 중…")
    }

    func testIdleSaysNothing() {
        XCTAssertEqual(LocalLLMSession.statusLine(for: .idle, backend: nil), "")
    }

    /// The panel is one line tall here; a multi-line traceback would push the
    /// prompt box off the bottom of the screen.
    func testFailureIsFlattenedAndClipped() {
        let message = String(repeating: "가", count: 200) + "\n두 번째 줄"
        let line = LocalLLMSession.statusLine(for: .failed(message), backend: nil)
        XCTAssertTrue(line.hasPrefix("실패 — "))
        XCTAssertFalse(line.contains("\n"))
        XCTAssertTrue(line.hasSuffix("…"))
        XCTAssertLessThan(line.count, 130)
    }
}

final class LocalLLMDraftTests: XCTestCase {
    /// The first canvases are entirely placeholder, and printing them fills the
    /// panel with a wall that says nothing.
    func testAnAllMaskCanvasCondensesToNothing() {
        let canvas = Array(repeating: "[Mask]", count: 200).joined(separator: " ")
        XCTAssertEqual(LocalLLMSession.condenseDraft(canvas), "")
    }

    func testKeepsTheWordsThatHaveBeenUnmasked() {
        let canvas = "[Mask] 태양 [Mask] [Mask] 빛이 <eos><eos><eos>"
        XCTAssertEqual(LocalLLMSession.condenseDraft(canvas), "태양 빛이")
    }

    func testCollapsesTheGapsTheRemovalsLeave() {
        XCTAssertEqual(LocalLLMSession.condenseDraft("a   [Mask]    b"), "a b")
    }

    func testTextWithoutPlaceholdersSurvivesIntact() {
        XCTAssertEqual(LocalLLMSession.condenseDraft("하늘은 파랗다"), "하늘은 파랗다")
    }
}

/// `/api/status` serves more than the dot needs; "자세히" now spends the rest.
/// Parsing is a pure function precisely so these two cases are reachable.
final class LocalLLMStatusParsingTests: XCTestCase {
    func testReadsEveryHeadroomFieldTheServerSends() {
        let status = LocalLLMClient.Status(json: [
            "model": "mlx-community/diffusiongemma-26B-A4B-it-4bit",
            "default_backend": "local-diffusiongemma",
            "local_loaded": true,
            "busy": false,
            "waiting": 2,
            "max_context": 96_000,
            "hard_context_limit": 120_000,
            "max_queue_depth": 8,
            "last_peak_gb": 24.6,
            "total_jobs": 38,
            "remote_active": 1,
            "remote_limit": 4
        ])
        XCTAssertEqual(status.model, "mlx-community/diffusiongemma-26B-A4B-it-4bit")
        XCTAssertEqual(status.waiting, 2)
        XCTAssertEqual(status.maxContext, 96_000)
        XCTAssertEqual(status.hardContextLimit, 120_000)
        XCTAssertEqual(status.maxQueueDepth, 8)
        XCTAssertEqual(status.lastPeakGB, 24.6)
        XCTAssertEqual(status.totalJobs, 38)
        XCTAssertEqual(status.remoteActive, 1)
        XCTAssertEqual(status.remoteLimit, 4)
    }

    /// A server older than this client, and a server that has not generated
    /// anything yet, look the same here: the field is simply absent. Neither may
    /// turn into a zero -- the setup window prints these numbers at people.
    func testMissingFieldsStayMissingRatherThanBecomingZero() {
        let status = LocalLLMClient.Status(json: [
            "model": "x", "local_loaded": true, "busy": false, "waiting": 0
        ])
        XCTAssertEqual(status.model, "x")
        XCTAssertTrue(status.localLoaded)
        XCTAssertNil(status.maxContext)
        XCTAssertNil(status.hardContextLimit)
        XCTAssertNil(status.maxQueueDepth)
        XCTAssertNil(status.lastPeakGB)
        XCTAssertNil(status.totalJobs)
        XCTAssertNil(status.remoteActive)
        XCTAssertNil(status.remoteLimit)
    }

    /// The server rounds the peak, so an exactly-integral GB arrives as a bare
    /// number. Reading it as Int-only would drop the row on those runs.
    func testAnIntegralPeakIsStillRead() {
        let status = LocalLLMClient.Status(json: ["last_peak_gb": 24])
        XCTAssertEqual(status.lastPeakGB, 24)
    }
}
