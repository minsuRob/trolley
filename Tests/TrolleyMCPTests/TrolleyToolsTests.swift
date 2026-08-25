import Foundation
import TrolleyKit
import XCTest
@testable import TrolleyMCP

final class TrolleyToolsTests: XCTestCase {
    private var trust = FakeTrustChecker()
    private var locator = FakeAppLocator()
    private var poster = FakeKeyPoster()
    private var root = FakeElement(role: "AXApplication")
    private var slept: [TimeInterval] = []
    private var mouseClicks: [CGPoint] = []
    private var activatedPids: [pid_t] = []
    private var activateSucceeds = true
    private var keyPosterTargets: [pid_t?] = []
    private var clipboard = FakeClipboard()
    private var inputSource = FakeInputSource()

    private func makeTools() -> TrolleyTools {
        TrolleyTools(
            trustChecker: trust,
            locator: locator,
            makeKeyPoster: { [weak self] targetPid in
                self?.keyPosterTargets.append(targetPid)
                return self?.poster ?? FakeKeyPoster()
            },
            mouseClicker: { [weak self] point in self?.mouseClicks.append(point) },
            makeRoot: { [weak self] _, _ in self?.root ?? FakeElement() },
            activateApp: { [weak self] pid in
                self?.activatedPids.append(pid)
                return self?.activateSucceeds ?? true
            },
            listRunningApps: {
                [AppSummary(name: "TextEdit", bundleID: "com.apple.TextEdit", pid: 42, isActive: true)]
            },
            clipboard: clipboard,
            inputSource: inputSource,
            executablePath: { "/tmp/trolley" },
            sleeper: { [weak self] seconds in self?.slept.append(seconds) }
        )
    }

    override func setUp() {
        super.setUp()
        trust = FakeTrustChecker()
        locator = FakeAppLocator()
        locator.running["com.apple.TextEdit"] = RunningAppInfo(processIdentifier: 42, isFinishedLaunching: true)
        poster = FakeKeyPoster()
        root = FakeElement(role: "AXApplication")
        slept = []
        mouseClicks = []
        activatedPids = []
        activateSucceeds = true
        keyPosterTargets = []
        clipboard = FakeClipboard()
        inputSource = FakeInputSource()
    }

    private func call(_ name: String, _ arguments: [String: JSONValue] = [:]) throws -> JSONValue {
        try makeTools().call(name: name, arguments: .object(arguments))
    }

    // MARK: - Permissions

    func testUntrustedToolsFailWithTheExecutablePath() {
        trust.trusted = false

        XCTAssertThrowsError(try call("snapshot", ["bundleId": .string("com.apple.TextEdit")])) { error in
            let toolError = error as? ToolError
            XCTAssertEqual(toolError?.code, .notTrusted)
            XCTAssertEqual(toolError?.hint?.contains("/tmp/trolley"), true)
        }
    }

    func testCheckPermissionsWorksWithoutTrustAndExplainsWhy() throws {
        trust.trusted = false

        let result = try call("check_permissions")

        XCTAssertEqual(result["trusted"]?.boolValue, false)
        XCTAssertEqual(result["executablePath"]?.stringValue, "/tmp/trolley")
        XCTAssertNotNil(result["instructions"])
    }

    // MARK: - Apps

    func testListAppsFiltersByName() throws {
        XCTAssertEqual(try call("list_apps")["apps"]?.arrayValue?.count, 1)
        XCTAssertEqual(try call("list_apps", ["nameContains": .string("textedit")])["apps"]?.arrayValue?.count, 1)
        XCTAssertEqual(try call("list_apps", ["nameContains": .string("safari")])["apps"]?.arrayValue?.count, 0)
    }

    func testToolsOnANonRunningAppSayToLaunchItFirst() {
        XCTAssertThrowsError(try call("snapshot", ["bundleId": .string("com.example.Missing")])) { error in
            let toolError = error as? ToolError
            XCTAssertEqual(toolError?.code, .appNotRunning)
            XCTAssertEqual(toolError?.hint?.contains("launch_app"), true)
        }
    }

    // MARK: - Snapshot

    func testSnapshotReturnsATreeWithIdsUsableByOtherTools() throws {
        root.fakeChildren = [FakeElement(role: "AXButton", title: "저장")]

        let result = try call("snapshot", ["bundleId": .string("com.apple.TextEdit")])

        XCTAssertEqual(result["pid"]?.intValue, 42)
        XCTAssertEqual(result["truncated"]?.boolValue, false)
        let button = try XCTUnwrap(result["tree"]?.arrayValue?.first?["children"]?.arrayValue?.first)
        XCTAssertEqual(button["title"]?.stringValue, "저장")
        XCTAssertNotNil(button["id"]?.stringValue)
    }

    /// An app that exposes nothing is the Chromium/Electron signature; saying so
    /// is the difference between the model retrying and it giving up.
    func testAnEmptyTreeSuggestsTheThoroughRetry() throws {
        let result = try call("snapshot", ["bundleId": .string("com.apple.TextEdit")])

        XCTAssertNotNil(result["emptyTreeHint"])
    }

    func testThoroughSnapshotSignalsManualAccessibilityExactlyOncePerApp() throws {
        let tools = makeTools()
        let args = JSONValue.object([
            "bundleId": .string("com.apple.TextEdit"),
            "thorough": .bool(true)
        ])

        _ = try tools.call(name: "snapshot", arguments: args)
        _ = try tools.call(name: "snapshot", arguments: args)

        let signals = root.setAttributes.filter { $0.0 == AXAttr.manualAccessibility }
        XCTAssertEqual(signals.count, 1, "re-sending the signal would re-pay the settle delay each call")
        XCTAssertEqual(slept, [1.5])
    }

    func testFastSnapshotDoesNotPayTheSettleDelay() throws {
        _ = try call("snapshot", ["bundleId": .string("com.apple.TextEdit")])

        XCTAssertTrue(slept.isEmpty)
    }

    // MARK: - Finding

    func testFindElementsRanksTheLeafiestMatchFirst() throws {
        let leaf = FakeElement(role: "AXStaticText", value: "저장")
        let container = FakeElement(role: "AXGroup", value: "저장하기", children: [leaf])
        root.fakeChildren = [container]

        let result = try call("find_elements", [
            "bundleId": .string("com.apple.TextEdit"),
            "text": .string("저장")
        ])

        let matches = try XCTUnwrap(result["matches"]?.arrayValue)
        XCTAssertEqual(result["totalMatches"]?.intValue, 2)
        XCTAssertEqual(matches[0]["role"]?.stringValue, "AXStaticText")
    }

    func testFindElementsRespectsTheLimit() throws {
        root.fakeChildren = (0..<5).map { FakeElement(role: "AXButton", title: "item \($0)") }

        let result = try call("find_elements", [
            "bundleId": .string("com.apple.TextEdit"),
            "text": .string("item"),
            "limit": .int(2)
        ])

        XCTAssertEqual(result["matches"]?.arrayValue?.count, 2)
        XCTAssertEqual(result["totalMatches"]?.intValue, 5)
    }

    func testMissingElementPointsAtSnapshot() {
        XCTAssertThrowsError(try call("find_elements", [
            "bundleId": .string("com.apple.TextEdit"),
            "text": .string("nothing")
        ])) { error in
            XCTAssertEqual((error as? ToolError)?.code, .elementNotFound)
        }
    }

    // MARK: - Acting

    func testClickByElementIdReportsTheAXPressPath() throws {
        let button = FakeElement(role: "AXButton", title: "OK")
        root.fakeChildren = [button]
        let tools = makeTools()

        let snapshot = try tools.call(name: "snapshot", arguments: .object(["bundleId": .string("com.apple.TextEdit")]))
        let id = try XCTUnwrap(snapshot["tree"]?.arrayValue?.first?["children"]?.arrayValue?.first?["id"]?.stringValue)

        let result = try tools.call(name: "click", arguments: .object(["elementId": .string(id)]))

        XCTAssertEqual(result["clicked"]?.boolValue, true)
        XCTAssertEqual(result["method"]?.stringValue, "AXPress")
        XCTAssertEqual(button.performedActions, [AXAction.press])
    }

    func testClickRequiresAUsableTarget() {
        XCTAssertThrowsError(try call("click")) { error in
            XCTAssertEqual((error as? ToolError)?.code, .invalidArgument)
        }
    }

    func testClickOnAStaleElementSaysToRequery() throws {
        let button = FakeElement(role: "AXButton", title: "OK")
        root.fakeChildren = [button]
        let tools = makeTools()
        let snapshot = try tools.call(name: "snapshot", arguments: .object(["bundleId": .string("com.apple.TextEdit")]))
        let id = try XCTUnwrap(snapshot["tree"]?.arrayValue?.first?["children"]?.arrayValue?.first?["id"]?.stringValue)

        button.alive = false

        XCTAssertThrowsError(try tools.call(name: "click", arguments: .object(["elementId": .string(id)]))) { error in
            XCTAssertEqual((error as? ToolError)?.code, .elementStale)
        }
    }

    private func idOfFirstMatch(_ tools: TrolleyTools, text: String) throws -> String {
        let found = try tools.call(name: "find_elements", arguments: .object([
            "bundleId": .string("com.apple.TextEdit"),
            "text": .string(text)
        ]))
        return try XCTUnwrap(found["matches"]?.arrayValue?.first?["id"]?.stringValue)
    }

    func testTypeTextFocusesTheTargetThenPastesWithoutWritingAXValue() throws {
        let field = FakeElement(role: "AXTextField", title: "본문")
        root.fakeChildren = [field]
        let tools = makeTools()
        let id = try idOfFirstMatch(tools, text: "본문")

        let result = try tools.call(name: "type_text", arguments: .object([
            "text": .string("안녕하세요"),
            "elementId": .string(id)
        ]))

        XCTAssertEqual(result["focusedElementId"]?.stringValue, id)
        XCTAssertEqual(result["method"]?.stringValue, "paste")
        XCTAssertEqual(clipboard.events, [.snapshot, .write("안녕하세요"), .restore])
        XCTAssertTrue(
            poster.postedKeys.contains { $0.0 == 9 && $0.2.contains(.maskCommand) },
            "expected cmd+V"
        )
        XCTAssertEqual(field.setAttributes.map(\.0), [AXAttr.focused])
        XCTAssertTrue(
            field.setAttributes.allSatisfy { $0.0 != AXAttr.value },
            "type_text must not fall back to AXValue writes"
        )
    }

    /// Synthesized keystrokes go to the frontmost app, not to the AX-focused
    /// element. Measured against TextEdit: focusing by elementId alone typed the
    /// text into the terminal that was in front instead, while still reporting
    /// success.
    func testTypeTextFrontsTheElementsOwnAppBeforeTyping() throws {
        let field = FakeElement(role: "AXTextField", title: "본문")
        field.pid = 42
        root.fakeChildren = [field]
        let tools = makeTools()
        let id = try idOfFirstMatch(tools, text: "본문")

        _ = try tools.call(name: "type_text", arguments: .object([
            "text": .string("안녕"),
            "elementId": .string(id)
        ]))

        XCTAssertEqual(activatedPids, [42], "the owning app must be fronted before any keystroke is posted")
    }

    /// cmd+V is matched at the system tap, so the paste must not be redirected
    /// to a pid. (An earlier version targeted the pid on the theory that it got
    /// Unicode injection past the input method; measurement showed nothing does.)
    func testTypeTextPastesThroughTheSystemTapNotThePid() throws {
        let field = FakeElement(role: "AXTextField", title: "본문")
        field.pid = 42
        root.fakeChildren = [field]
        let tools = makeTools()
        let id = try idOfFirstMatch(tools, text: "본문")
        keyPosterTargets = []

        _ = try tools.call(name: "type_text", arguments: .object([
            "text": .string("안녕"),
            "elementId": .string(id)
        ]))

        XCTAssertFalse(keyPosterTargets.contains(42))
        XCTAssertTrue(keyPosterTargets.allSatisfy { $0 == nil })
    }

    /// Shortcuts are matched on physical key position by the system tap, so
    /// press_key must not be redirected to a pid.
    func testPressKeyUsesTheSystemTap() throws {
        _ = try call("press_key", ["key": .string("n"), "modifiers": .array([.string("cmd")])])

        XCTAssertEqual(keyPosterTargets, [nil])
    }

    func testTypeTextFailsRatherThanTypingIntoTheWrongAppWhenActivationFails() throws {
        let field = FakeElement(role: "AXTextField", title: "본문")
        field.pid = 42
        root.fakeChildren = [field]
        let tools = makeTools()
        let id = try idOfFirstMatch(tools, text: "본문")
        activateSucceeds = false

        XCTAssertThrowsError(try tools.call(name: "type_text", arguments: .object([
            "text": .string("안녕"),
            "elementId": .string(id)
        ])))
        XCTAssertTrue(poster.postedKeys.isEmpty, "no keystrokes may be posted if the app could not be fronted")
        XCTAssertTrue(clipboard.events.isEmpty, "the clipboard must not even be touched")
    }

    func testTypeTextWithNoTargetWarnsThatItWentToTheFrontmostApp() throws {
        let result = try call("type_text", ["text": .string("안녕")])

        XCTAssertNotNil(result["warning"])
    }

    /// "typed: n" only says what was sent; the readback is the honest part.
    func testTypeTextReportsWhetherTheTextIsVisibleAfterwards() throws {
        let field = FakeElement(role: "AXTextField", title: "본문")
        field.pid = 42
        field.swallowsWrites = true
        root.fakeChildren = [field]
        let tools = makeTools()
        let id = try idOfFirstMatch(tools, text: "본문")

        let result = try tools.call(name: "type_text", arguments: .object([
            "text": .string("안녕"),
            "elementId": .string(id)
        ]))

        XCTAssertEqual(result["containsTypedText"]?.boolValue, false)
        XCTAssertNotNil(result["note"])
    }

    func testTypeTextActivatesTheAppAndSettlesFirst() throws {
        _ = try call("type_text", [
            "text": .string("hi"),
            "bundleId": .string("com.apple.TextEdit")
        ])

        XCTAssertEqual(locator.activated, ["com.apple.TextEdit"])
        XCTAssertEqual(slept.first, 0.4, "activation must settle before anything is sent")
        XCTAssertTrue(slept.contains(0.3), "the paste must settle before the clipboard is restored")
    }

    // MARK: - Text entry methods

    func testUnknownMethodIsRejectedWithTheValidList() {
        XCTAssertThrowsError(try call("type_text", [
            "text": .string("hi"),
            "method": .string("telepathy")
        ])) { error in
            let toolError = error as? ToolError
            XCTAssertEqual(toolError?.code, .invalidArgument)
            XCTAssertEqual(toolError?.hint?.contains("paste"), true)
        }
        XCTAssertTrue(clipboard.events.isEmpty)
        XCTAssertTrue(poster.postedKeys.isEmpty)
    }

    func testKeysMethodTypesByKeyCodeAndNeverTouchesTheClipboard() throws {
        inputSource.asciiCapable = true

        let result = try call("type_text", [
            "text": .string("hi"),
            "bundleId": .string("com.apple.TextEdit"),
            "method": .string("keys")
        ])

        XCTAssertEqual(result["method"]?.stringValue, "keys")
        XCTAssertEqual(poster.postedKeys.filter(\.1).map(\.0), [4, 34])
        XCTAssertTrue(clipboard.events.isEmpty)
    }

    /// Korean cannot be produced from key positions, and the error has to say so
    /// before anything global changes.
    func testKeysMethodRejectsNonASCIIAndPointsAtPaste() {
        XCTAssertThrowsError(try call("type_text", [
            "text": .string("안녕"),
            "bundleId": .string("com.apple.TextEdit"),
            "method": .string("keys")
        ])) { error in
            let toolError = error as? ToolError
            XCTAssertEqual(toolError?.code, .unsupportedText)
            XCTAssertEqual(toolError?.hint?.contains("paste"), true)
        }
        XCTAssertTrue(poster.postedKeys.isEmpty)
        XCTAssertTrue(inputSource.selections.isEmpty, "the input source must not change for a rejected request")
    }

    func testKeysMethodPutsTheUsersInputSourceBack() throws {
        let result = try call("type_text", [
            "text": .string("hi"),
            "bundleId": .string("com.apple.TextEdit"),
            "method": .string("keys")
        ])

        XCTAssertEqual(inputSource.selections, [
            "com.apple.keylayout.ABC",
            "com.apple.inputmethod.Korean.2SetKorean"
        ])
        XCTAssertEqual(result["inputSourceRestored"]?.boolValue, true)
    }

    func testMissingASCIILayoutIsExplained() {
        inputSource.asciiSelectionSucceeds = false

        XCTAssertThrowsError(try call("type_text", [
            "text": .string("hi"),
            "bundleId": .string("com.apple.TextEdit"),
            "method": .string("keys")
        ])) { error in
            XCTAssertEqual((error as? ToolError)?.code, .inputSourceFailed)
        }
    }

    func testClipboardFailureIsReportedAndNothingIsPasted() {
        clipboard.writeSucceeds = false

        XCTAssertThrowsError(try call("type_text", [
            "text": .string("hi"),
            "bundleId": .string("com.apple.TextEdit")
        ])) { error in
            XCTAssertEqual((error as? ToolError)?.code, .clipboardFailed)
        }
        XCTAssertTrue(poster.postedKeys.isEmpty)
    }

    func testUnicodeMethodIsStillAvailableForDiagnosis() throws {
        let result = try call("type_text", [
            "text": .string("hi"),
            "bundleId": .string("com.apple.TextEdit"),
            "method": .string("unicode")
        ])

        XCTAssertEqual(result["method"]?.stringValue, "unicode")
        XCTAssertFalse(poster.postedUnicode.isEmpty)
        XCTAssertTrue(clipboard.events.isEmpty)
    }

    /// An unverifiable insert must not be retried by any means -- that is the
    /// whole reason there is no fallback chain.
    func testUnverifiableInsertIsNotRetried() throws {
        let field = FakeElement(role: "AXTextField", title: "본문")
        field.pid = 42
        field.attributes.removeValue(forKey: AXAttr.value)
        root.fakeChildren = [field]
        let tools = makeTools()
        let id = try idOfFirstMatch(tools, text: "본문")

        let result = try tools.call(name: "type_text", arguments: .object([
            "text": .string("안녕"),
            "elementId": .string(id)
        ]))

        XCTAssertEqual(result["verification"]?.stringValue, "unverifiable")
        XCTAssertEqual(clipboard.events.filter { $0 == .write("안녕") }.count, 1)
        XCTAssertEqual(poster.postedKeys.filter { $0.0 == 9 && $0.1 }.count, 1, "exactly one paste")
        XCTAssertTrue(field.setAttributes.allSatisfy { $0.0 != AXAttr.value })
    }

    /// The CLI silently posted nothing here and still reported success.
    func testUnknownKeyIsRejectedBeforeAnythingIsPosted() {
        XCTAssertThrowsError(try call("press_key", ["key": .string("f13")])) { error in
            XCTAssertEqual((error as? ToolError)?.code, .unknownKey)
        }
        XCTAssertTrue(poster.postedKeys.isEmpty)
    }

    func testUnknownModifierIsRejectedRatherThanSendingABareKey() {
        XCTAssertThrowsError(try call("press_key", [
            "key": .string("a"),
            "modifiers": .array([.string("hyper")])
        ])) { error in
            XCTAssertEqual((error as? ToolError)?.code, .unknownKey)
        }
        XCTAssertTrue(poster.postedKeys.isEmpty, "sending an unmodified key would perform the wrong action")
    }

    func testValidKeyIsPosted() throws {
        let result = try call("press_key", ["key": .string("return")])

        XCTAssertEqual(result["pressed"]?.stringValue, "return")
        XCTAssertEqual(poster.postedKeys.map(\.0), [36, 36])
    }

    func testSetAXValueReportsASilentNoOp() throws {
        let field = FakeElement(role: "AXTextField", value: "before")
        field.setAttributeResult = false
        root.fakeChildren = [field]
        let tools = makeTools()
        let found = try tools.call(name: "find_elements", arguments: .object([
            "bundleId": .string("com.apple.TextEdit"),
            "text": .string("before")
        ]))
        let id = try XCTUnwrap(found["matches"]?.arrayValue?.first?["id"]?.stringValue)

        let result = try tools.call(name: "set_ax_value", arguments: .object([
            "elementId": .string(id),
            "value": .string("after")
        ]))

        XCTAssertEqual(result["accepted"]?.boolValue, false)
        XCTAssertEqual(result["matchesRequestedValue"]?.boolValue, false)
        XCTAssertEqual(result["readback"]?.stringValue, "before")
    }

    /// The failure mode that motivated the readback: the write reports success
    /// and changes nothing, so "accepted" alone would be a lie.
    func testSetAXValueWarnsWhenTheWriteSucceedsButNothingChanged() throws {
        let field = FakeElement(role: "AXTextField", value: "before")
        field.swallowsWrites = true
        root.fakeChildren = [field]
        let tools = makeTools()
        let found = try tools.call(name: "find_elements", arguments: .object([
            "bundleId": .string("com.apple.TextEdit"),
            "text": .string("before")
        ]))
        let id = try XCTUnwrap(found["matches"]?.arrayValue?.first?["id"]?.stringValue)

        let result = try tools.call(name: "set_ax_value", arguments: .object([
            "elementId": .string(id),
            "value": .string("after")
        ]))

        XCTAssertEqual(result["accepted"]?.boolValue, true)
        XCTAssertEqual(result["matchesRequestedValue"]?.boolValue, false)
        XCTAssertEqual(result["readback"]?.stringValue, "before")
        XCTAssertNotNil(result["warning"])
    }

    /// Clearing a field is a normal request; treating "" as "argument missing"
    /// made it impossible to express.
    func testSetAXValueAcceptsAnEmptyStringToClearAField() throws {
        let field = FakeElement(role: "AXTextField", value: "before")
        root.fakeChildren = [field]
        let tools = makeTools()
        let id = try idOfFirstMatch(tools, text: "before")

        let result = try tools.call(name: "set_ax_value", arguments: .object([
            "elementId": .string(id),
            "value": .string("")
        ]))

        XCTAssertEqual(result["matchesRequestedValue"]?.boolValue, true)
        XCTAssertEqual(result["readback"]?.stringValue, "")
    }

    func testSetAXValueStillRequiresTheValueArgument() throws {
        let field = FakeElement(role: "AXTextField", value: "before")
        root.fakeChildren = [field]
        let tools = makeTools()
        let id = try idOfFirstMatch(tools, text: "before")

        XCTAssertThrowsError(try tools.call(name: "set_ax_value", arguments: .object([
            "elementId": .string(id)
        ]))) { error in
            XCTAssertEqual((error as? ToolError)?.code, .invalidArgument)
        }
    }

    func testSetAXValueReportsAWriteThatActuallyLanded() throws {
        let field = FakeElement(role: "AXTextField", value: "before")
        root.fakeChildren = [field]
        let tools = makeTools()
        let found = try tools.call(name: "find_elements", arguments: .object([
            "bundleId": .string("com.apple.TextEdit"),
            "text": .string("before")
        ]))
        let id = try XCTUnwrap(found["matches"]?.arrayValue?.first?["id"]?.stringValue)

        let result = try tools.call(name: "set_ax_value", arguments: .object([
            "elementId": .string(id),
            "value": .string("after")
        ]))

        XCTAssertEqual(result["matchesRequestedValue"]?.boolValue, true)
        XCTAssertEqual(result["readback"]?.stringValue, "after")
        XCTAssertNil(result["warning"])
    }

    // MARK: - Waiting

    func testWaitForElementReturnsAsSoonAsItAppears() throws {
        root.fakeChildren = [FakeElement(role: "AXButton", title: "Ready")]

        let result = try call("wait_for_element", [
            "bundleId": .string("com.apple.TextEdit"),
            "text": .string("Ready")
        ])

        XCTAssertEqual(result["attempts"]?.intValue, 1)
        XCTAssertTrue(slept.isEmpty, "a present element should cost no delay at all")
        XCTAssertNotNil(result["id"]?.stringValue)
    }

    func testWaitForElementTimesOutWithADiagnosticHint() {
        XCTAssertThrowsError(try call("wait_for_element", [
            "bundleId": .string("com.apple.TextEdit"),
            "text": .string("never"),
            "timeoutSeconds": .double(0)
        ])) { error in
            let toolError = error as? ToolError
            XCTAssertEqual(toolError?.code, .timeout)
            XCTAssertEqual(toolError?.hint?.contains("thorough"), true)
        }
    }

    // MARK: - Dispatch

    func testUnknownToolIsRejected() {
        XCTAssertThrowsError(try call("teleport")) { error in
            XCTAssertEqual((error as? ToolError)?.code, .invalidArgument)
        }
    }

    func testEveryDeclaredToolIsDispatchable() {
        let tools = makeTools()
        for tool in tools.tools {
            // Missing required arguments must surface as INVALID_ARGUMENT, never
            // as "unknown tool" -- that would mean a declared tool has no handler.
            do {
                _ = try tools.call(name: tool.name, arguments: .object([:]))
            } catch let error as ToolError {
                XCTAssertNotEqual(
                    error.message, "Unknown tool \"\(tool.name)\".",
                    "\(tool.name) is advertised in tools/list but has no dispatch case"
                )
            } catch {
                XCTFail("\(tool.name) threw a non-ToolError: \(error)")
            }
        }
    }
}
