import CoreGraphics
import XCTest
@testable import TrolleyKit

/// One ordered log shared by the clipboard and keyboard fakes, so tests can
/// assert that the paste happened *between* the clipboard write and restore.
final class EventLog {
    enum Event: Equatable {
        case snapshot
        case write(String)
        case restore
        case key(CGKeyCode, CGEventFlags.RawValue)
        case unicode(String)
        case selectASCII
        case selectSource(String)
    }

    var events: [Event] = []
}

final class FakeClipboard: ClipboardAccessing {
    let log: EventLog
    var changeCount = 1
    var writeSucceeds = true
    var restoreSucceeds = true
    var snapshotTruncated = false

    init(log: EventLog) {
        self.log = log
    }

    /// Simulates another app taking the pasteboard. Must be called *after* the
    /// engine has recorded its own change count -- i.e. from the sleeper --
    /// otherwise the engine never sees a difference.
    func stealByAnotherApp() {
        changeCount += 1
    }

    func snapshot() -> ClipboardSnapshot {
        log.events.append(.snapshot)
        return ClipboardSnapshot(
            items: snapshotTruncated ? [] : [["public.utf8-plain-text": Data("previous".utf8)]],
            truncated: snapshotTruncated
        )
    }

    func writePlainText(_ text: String) -> Bool {
        log.events.append(.write(text))
        guard writeSucceeds else { return false }
        changeCount += 1
        return true
    }

    func restore(_ snapshot: ClipboardSnapshot) -> Bool {
        log.events.append(.restore)
        return restoreSucceeds
    }
}

final class FakeInputSource: InputSourceControlling {
    let log: EventLog
    var current: String? = "com.apple.inputmethod.Korean.2SetKorean"
    var asciiCapable = false
    var asciiSelectionSucceeds = true
    var selectSucceeds = true
    /// Every selection made, in order.
    var selections: [String] = []

    init(log: EventLog) {
        self.log = log
    }

    func currentInputSourceID() -> String? { current }
    func currentIsASCIICapable() -> Bool { asciiCapable }

    func selectASCIICapableInputSource() -> String? {
        guard asciiSelectionSucceeds else { return nil }
        log.events.append(.selectASCII)
        selections.append("com.apple.keylayout.ABC")
        current = "com.apple.keylayout.ABC"
        return "com.apple.keylayout.ABC"
    }

    func selectInputSource(id: String) -> Bool {
        log.events.append(.selectSource(id))
        selections.append(id)
        guard selectSucceeds else { return false }
        current = id
        return true
    }
}

final class LoggingKeyPoster: KeyEventPosting {
    let log: EventLog

    init(log: EventLog) {
        self.log = log
    }

    func post(keyCode: CGKeyCode, down: Bool, flags: CGEventFlags) {
        guard down else { return }
        log.events.append(.key(keyCode, flags.rawValue))
    }

    func postUnicode(_ chunk: [UniChar], down: Bool) {
        guard down else { return }
        log.events.append(.unicode(String(utf16CodeUnits: chunk, count: chunk.count)))
    }
}

final class TextEntryEngineTests: XCTestCase {
    private var log = EventLog()
    private var clipboard: FakeClipboard!
    private var inputSource: FakeInputSource!
    private var posterTargets: [pid_t?] = []
    private var slept: [TimeInterval] = []
    private var secureInput = false
    /// Lets a test change the world mid-operation, the way another app would.
    private var onSleep: (() -> Void)?

    override func setUp() {
        super.setUp()
        log = EventLog()
        clipboard = FakeClipboard(log: log)
        inputSource = FakeInputSource(log: log)
        posterTargets = []
        slept = []
        secureInput = false
        onSleep = nil
    }

    private func makeEngine() -> TextEntryEngine {
        TextEntryEngine(
            makePoster: { [weak self] target in
                self?.posterTargets.append(target)
                return LoggingKeyPoster(log: self?.log ?? EventLog())
            },
            clipboard: clipboard,
            inputSource: inputSource,
            sleeper: { [weak self] seconds in
                self?.slept.append(seconds)
                self?.onSleep?()
            },
            secureInputCheck: { [weak self] in self?.secureInput ?? false }
        )
    }

    private func field(value: String?) -> MockAXElement {
        let element = MockAXElement(role: "AXTextField")
        if let value { element.attributes[AXAttr.value] = value as AnyObject }
        return element
    }

    private var cmdV: EventLog.Event {
        .key(9, CGEventFlags.maskCommand.rawValue)
    }

    // MARK: - Paste

    func testPasteSnapshotsWritesPastesThenRestoresInThatOrder() throws {
        _ = try makeEngine().insert("안녕", method: .paste, element: nil, targetPid: nil)

        XCTAssertEqual(log.events, [.snapshot, .write("안녕"), cmdV, .restore])
    }

    /// Shortcut matching happens at the system tap, so cmd+V must not be
    /// redirected to a pid.
    func testPasteGoesThroughTheSystemTapNotThePid() throws {
        _ = try makeEngine().insert("hi", method: .paste, element: nil, targetPid: 42)

        XCTAssertEqual(posterTargets, [nil])
    }

    func testPasteWaitsBeforeRestoringSoTheTargetCanConsumeIt() throws {
        _ = try makeEngine().insert("hi", method: .paste, element: nil, targetPid: nil, pasteSettle: 0.7)

        XCTAssertTrue(slept.contains(0.7))
    }

    func testClipboardIsLeftAloneWhenAnotherAppTookItMeanwhile() throws {
        // The steal has to land while we're waiting for the paste to settle,
        // which is the real window another app would use.
        onSleep = { [weak self] in self?.clipboard.stealByAnotherApp() }

        let outcome = try makeEngine().insert("hi", method: .paste, element: nil, targetPid: nil)

        XCTAssertEqual(outcome.clipboardRestored, false)
        XCTAssertNotNil(outcome.clipboardNote)
        XCTAssertFalse(log.events.contains(.restore), "restoring would clobber the other app's clipboard")
    }

    func testOversizedClipboardIsReportedRatherThanPartiallyRestored() throws {
        clipboard.snapshotTruncated = true

        let outcome = try makeEngine().insert("hi", method: .paste, element: nil, targetPid: nil)

        XCTAssertEqual(outcome.clipboardRestored, false)
        XCTAssertNotNil(outcome.clipboardNote)
        XCTAssertFalse(log.events.contains(.restore))
    }

    func testClipboardWriteFailureThrowsBeforeAnyKeyIsPosted() {
        clipboard.writeSucceeds = false

        XCTAssertThrowsError(try makeEngine().insert("hi", method: .paste, element: nil, targetPid: nil)) { error in
            guard case TextEntryError.clipboardUnavailable = error else {
                return XCTFail("expected clipboardUnavailable, got \(error)")
            }
        }
        XCTAssertFalse(log.events.contains(cmdV))
    }

    // MARK: - Keys

    func testKeysRejectsNonASCIIWithoutTouchingAnythingGlobal() {
        XCTAssertThrowsError(try makeEngine().insert("안녕", method: .keys, element: nil, targetPid: nil)) { error in
            guard case TextEntryError.unsupportedCharacters(let characters, let method) = error else {
                return XCTFail("expected unsupportedCharacters, got \(error)")
            }
            XCTAssertEqual(method, .keys)
            XCTAssertEqual(characters, "녕안")
        }
        XCTAssertTrue(log.events.isEmpty, "validation must precede any global change or keystroke")
        XCTAssertTrue(inputSource.selections.isEmpty)
    }

    func testKeysSwitchesToASCIIAndPutsTheUsersSourceBack() throws {
        let outcome = try makeEngine().insert("hi", method: .keys, element: nil, targetPid: nil)

        XCTAssertEqual(inputSource.selections, [
            "com.apple.keylayout.ABC",
            "com.apple.inputmethod.Korean.2SetKorean"
        ])
        XCTAssertEqual(outcome.inputSourceRestored, true)
        XCTAssertEqual(inputSource.current, "com.apple.inputmethod.Korean.2SetKorean")
    }

    /// The restore must happen even when the text plainly did not arrive --
    /// leaving the user stuck in ASCII would be worse than the failed insert.
    func testKeysRestoresTheInputSourceEvenWhenTheTextDoesNotLand() throws {
        let element = field(value: "unchanged")

        let outcome = try makeEngine().insert("hi", method: .keys, element: element, targetPid: nil)

        XCTAssertEqual(outcome.verification, .provablyFailed)
        XCTAssertEqual(outcome.inputSourceRestored, true)
        XCTAssertEqual(inputSource.current, "com.apple.inputmethod.Korean.2SetKorean")
    }

    /// Measured in Chrome's omnibox: restoring the input source immediately
    /// after posting let the trailing keystrokes be re-interpreted by the
    /// restored IME, so "trolley keys test" arrived as "trolley keys tesㅅ".
    func testKeysLetsTheTargetDrainTheQueueBeforeRestoringTheInputSource() throws {
        _ = try makeEngine().insert("hello world", method: .keys, element: nil, targetPid: nil)

        let lastKeyIndex = try XCTUnwrap(log.events.lastIndex { if case .key = $0 { return true } else { return false } })
        let restoreIndex = try XCTUnwrap(log.events.firstIndex(of: .selectSource("com.apple.inputmethod.Korean.2SetKorean")))
        XCTAssertLessThan(lastKeyIndex, restoreIndex)
        XCTAssertTrue(
            slept.contains(TextEntryEngine.keyQueueSettle(forCharacterCount: 11)),
            "a settle proportional to the text must precede the restore"
        )
    }

    func testKeyQueueSettleHasAFloorAndGrowsWithLength() {
        XCTAssertEqual(TextEntryEngine.keyQueueSettle(forCharacterCount: 1), 0.3)
        XCTAssertGreaterThan(
            TextEntryEngine.keyQueueSettle(forCharacterCount: 200),
            TextEntryEngine.keyQueueSettle(forCharacterCount: 20)
        )
    }

    func testKeysDoesNotSwitchWhenTheSourceIsAlreadyASCII() throws {
        inputSource.asciiCapable = true

        let outcome = try makeEngine().insert("hi", method: .keys, element: nil, targetPid: nil)

        XCTAssertTrue(inputSource.selections.isEmpty, "switching would be a pointless global side effect")
        XCTAssertNil(outcome.inputSourceRestored)
    }

    func testKeysThrowsAndChangesNothingWhenNoASCIISourceExists() {
        inputSource.asciiSelectionSucceeds = false

        XCTAssertThrowsError(try makeEngine().insert("hi", method: .keys, element: nil, targetPid: nil)) { error in
            guard case TextEntryError.inputSourceUnavailable = error else {
                return XCTFail("expected inputSourceUnavailable, got \(error)")
            }
        }
        XCTAssertTrue(inputSource.selections.isEmpty)
        XCTAssertEqual(inputSource.current, "com.apple.inputmethod.Korean.2SetKorean")
    }

    func testKeysTypesShiftedCharactersWithTheShiftFlag() throws {
        inputSource.asciiCapable = true

        _ = try makeEngine().insert("Hi!", method: .keys, element: nil, targetPid: nil)

        XCTAssertEqual(log.events, [
            .key(4, CGEventFlags.maskShift.rawValue),   // H
            .key(34, 0),                                // i
            .key(18, CGEventFlags.maskShift.rawValue)   // !
        ])
    }

    func testKeysGoesThroughTheSystemTapNotThePid() throws {
        inputSource.asciiCapable = true

        _ = try makeEngine().insert("a", method: .keys, element: nil, targetPid: 42)

        XCTAssertEqual(posterTargets, [nil])
    }

    // MARK: - Verification

    func testConfirmedWhenTheValueGainsTheText() throws {
        let element = field(value: "")
        onSleep = { element.attributes[AXAttr.value] = "안녕하세요" as AnyObject }

        let outcome = try makeEngine().insert("안녕", method: .paste, element: element, targetPid: nil)

        XCTAssertEqual(outcome.verification, .confirmed)
        XCTAssertEqual(outcome.valueAfter, "안녕하세요")
    }

    func testProvablyFailedOnlyWhenTheValueIsUnchanged() throws {
        let outcome = try makeEngine().insert("hi", method: .paste, element: field(value: "same"), targetPid: nil)

        XCTAssertEqual(outcome.verification, .provablyFailed)
    }

    /// A field that reformats what it received is not proof of failure.
    func testChangedUnexpectedlyWhenTheValueMovedButLacksTheText() throws {
        let element = field(value: "before")
        // Reformatted on the way in, the way a phone-number field would.
        onSleep = { element.attributes[AXAttr.value] = "(555) 010" as AnyObject }

        let outcome = try makeEngine().insert("555010", method: .paste, element: element, targetPid: nil)

        XCTAssertEqual(outcome.verification, .changedUnexpectedly)
        XCTAssertEqual(outcome.valueBefore, "before")
        XCTAssertEqual(outcome.valueAfter, "(555) 010")
    }

    func testUnverifiableWithoutAnElement() throws {
        let outcome = try makeEngine().insert("hi", method: .paste, element: nil, targetPid: nil)

        XCTAssertEqual(outcome.verification, .unverifiable)
    }

    func testUnverifiableWhenTheElementReportsNoValue() throws {
        let outcome = try makeEngine().insert("hi", method: .paste, element: field(value: nil), targetPid: nil)

        XCTAssertEqual(outcome.verification, .unverifiable)
    }

    // MARK: - Secure input

    func testSecureInputIsReportedOnlyWhenTheTextDidNotArrive() throws {
        secureInput = true

        let failed = try makeEngine().insert("hi", method: .paste, element: field(value: "same"), targetPid: nil)
        XCTAssertTrue(failed.secureInputEnabled)

        let element = field(value: "")
        onSleep = { element.attributes[AXAttr.value] = "hi" as AnyObject }
        let confirmed = try makeEngine().insert("hi", method: .paste, element: element, targetPid: nil)
        XCTAssertFalse(confirmed.secureInputEnabled, "no need to explain a success")
    }

    // MARK: - Unicode

    func testUnicodeStillUsesTheLegacyInjectionAndTargetsThePid() throws {
        _ = try makeEngine().insert("hi", method: .unicode, element: nil, targetPid: 42)

        XCTAssertEqual(log.events, [.unicode("hi")])
        XCTAssertEqual(posterTargets, [42])
        XCTAssertTrue(log.events.allSatisfy { if case .write = $0 { return false } else { return true } },
                      "unicode must not touch the clipboard")
    }
}
