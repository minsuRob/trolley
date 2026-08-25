import CoreGraphics
import Darwin
import Foundation
import TrolleyKit
@testable import TrolleyMCP

/// In-memory `AXElementProviding` fake. TrolleyKitTests has its own copy; that
/// one is `@testable`-scoped to its module, and a shared test-support target
/// would be more machinery than two small doubles are worth.
final class FakeElement: AXElementProviding {
    var pid: pid_t?
    var attributes: [String: AnyObject] = [:]
    var fakeChildren: [FakeElement] = []
    var alive = true
    var pressResult = true
    var setAttributeResult = true
    /// Reports the write as successful but keeps the old value, the way Notion's
    /// rich-text editor responds to an AXValue write.
    var swallowsWrites = false
    var performedActions: [String] = []
    var setAttributes: [(String, AnyObject)] = []

    init(
        role: String? = nil,
        title: String? = nil,
        value: String? = nil,
        description: String? = nil,
        children: [FakeElement] = []
    ) {
        if let role { attributes[AXAttr.role] = role as AnyObject }
        if let title { attributes[AXAttr.title] = title as AnyObject }
        if let value { attributes[AXAttr.value] = value as AnyObject }
        if let description { attributes[AXAttr.description] = description as AnyObject }
        self.fakeChildren = children
    }

    func copyAttribute(_ name: String) -> AnyObject? { attributes[name] }
    func copyAttributeNames() -> [String] { Array(attributes.keys) }
    func children() -> [AXElementProviding] { fakeChildren }

    func performAction(_ name: String) -> Bool {
        performedActions.append(name)
        return pressResult
    }

    func setAttribute(_ name: String, value: AnyObject) -> Bool {
        setAttributes.append((name, value))
        if setAttributeResult && !swallowsWrites {
            attributes[name] = value
        }
        return setAttributeResult
    }

    func isAlive() -> Bool { alive }
}

final class FakeTrustChecker: TrustChecking {
    var trusted: Bool

    init(trusted: Bool = true) {
        self.trusted = trusted
    }

    func isProcessTrusted() -> Bool { trusted }
    func requestTrust(prompting: Bool) -> Bool { trusted }
}

final class FakeAppLocator: RunningAppLocating {
    var running: [String: RunningAppInfo] = [:]
    var urls: [String: URL] = [:]
    var activateResult = true
    var activated: [String] = []

    func runningApplication(bundleID: String) -> RunningAppInfo? { running[bundleID] }
    func applicationURL(bundleID: String) -> URL? { urls[bundleID] }

    func activate(bundleID: String) -> Bool {
        activated.append(bundleID)
        return activateResult
    }

    func open(applicationAt url: URL) -> Bool { true }
}

final class FakeKeyPoster: KeyEventPosting {
    var postedKeys: [(CGKeyCode, Bool, CGEventFlags)] = []
    var postedUnicode: [([UniChar], Bool)] = []

    func post(keyCode: CGKeyCode, down: Bool, flags: CGEventFlags) {
        postedKeys.append((keyCode, down, flags))
    }

    func postUnicode(_ chunk: [UniChar], down: Bool) {
        postedUnicode.append((chunk, down))
    }
}

final class FakeClipboard: ClipboardAccessing {
    enum Event: Equatable {
        case snapshot
        case write(String)
        case restore
    }

    var events: [Event] = []
    var changeCount = 1
    var writeSucceeds = true

    func snapshot() -> ClipboardSnapshot {
        events.append(.snapshot)
        return ClipboardSnapshot(items: [["public.utf8-plain-text": Data("previous".utf8)]], truncated: false)
    }

    func writePlainText(_ text: String) -> Bool {
        events.append(.write(text))
        guard writeSucceeds else { return false }
        changeCount += 1
        return true
    }

    func restore(_ snapshot: ClipboardSnapshot) -> Bool {
        events.append(.restore)
        return true
    }
}

final class FakeInputSource: InputSourceControlling {
    var current: String? = "com.apple.inputmethod.Korean.2SetKorean"
    var asciiCapable = false
    var asciiSelectionSucceeds = true
    var selections: [String] = []

    func currentInputSourceID() -> String? { current }
    func currentIsASCIICapable() -> Bool { asciiCapable }

    func selectASCIICapableInputSource() -> String? {
        guard asciiSelectionSucceeds else { return nil }
        selections.append("com.apple.keylayout.ABC")
        return "com.apple.keylayout.ABC"
    }

    func selectInputSource(id: String) -> Bool {
        selections.append(id)
        return true
    }
}

/// Records every tool call so protocol-level tests don't need real AX access.
final class StubToolProvider: ToolProviding {
    var tools: [ToolDefinition]
    var calls: [(name: String, arguments: JSONValue)] = []
    var handler: (String, JSONValue) throws -> JSONValue

    init(
        tools: [ToolDefinition] = [
            ToolDefinition(name: "echo", description: "echoes", inputSchema: Schema.object([:]))
        ],
        handler: @escaping (String, JSONValue) throws -> JSONValue = { name, _ in .string(name) }
    ) {
        self.tools = tools
        self.handler = handler
    }

    func call(name: String, arguments: JSONValue) throws -> JSONValue {
        calls.append((name, arguments))
        return try handler(name, arguments)
    }
}

extension JSONValue {
    /// Parses a JSON string for assertions.
    static func parse(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    /// Unwraps a `tools/call` result's single text content block.
    func toolPayload() throws -> JSONValue {
        guard let text = self["content"]?.arrayValue?.first?["text"]?.stringValue else {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "no text content"])
        }
        return try JSONValue.parse(text)
    }
}
