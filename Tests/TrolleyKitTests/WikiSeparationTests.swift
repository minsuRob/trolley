import XCTest
@testable import TrolleyKit

/// What is left of `WikiInjectionTests`, which tested a wiki that rode in front of every
/// question: the decision table, the already-sent record, the refresh cap. None of that
/// exists any more -- the vault is read in its own window, in its own conversation -- so
/// what is worth defending is the separation itself.
final class WikiSeparationTests: XCTestCase {
    // MARK: - Is there a wiki

    /// The only gate left. A folder that reads like the vault is one the wiki window can
    /// open; there is no switch in front of it to get out of step with the disk.
    func testAFolderWithTheVaultsLayoutReads() throws {
        let fixture = try WikiFixture()
        try fixture.write("context/tasks/할 일.md", "---\n유형: 기능\n---\n")
        try withRoot(fixture.root.path) {
            XCTAssertTrue(WikiSettings.rootIsReadable)
        }
    }

    /// The default path is prefilled into every install, so "a readable folder exists
    /// there" cannot be the test -- it would open somebody else's `~/Desktop/...` folder
    /// as though it were this team's wiki.
    func testAFolderWithoutTheLayoutDoesNot() throws {
        let folder = try emptyFolder()
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("docs"), withIntermediateDirectories: true
        )
        try withRoot(folder.path) {
            XCTAssertFalse(WikiSettings.rootIsReadable)
        }
    }

    /// A folder swapped for another must not be answered for by the old one's verdict:
    /// the probe is memoised for two seconds, which is longer than picking a folder takes.
    func testChangingTheRootReprobes() throws {
        let fixture = try WikiFixture()
        try fixture.write("context/concepts/개념.md", "---\n유형: 개념\n---\n")
        let empty = try emptyFolder()
        try withRoot(empty.path) {
            XCTAssertFalse(WikiSettings.rootIsReadable)
            WikiSettings.rootPath = fixture.root.path
            XCTAssertTrue(WikiSettings.rootIsReadable)
        }
    }

    /// An older bundle put back by `trolley update` reads `trolley.wiki.enabled`, and a
    /// `false` left there from before the switch was retired would turn its wiki off for
    /// a reason nobody could see from this build.
    func testRetiredKeysAreCleared() throws {
        let empty = try emptyFolder()
        try withRoot(empty.path) {
            let defaults = UserDefaults.standard
            for key in WikiSettings.retiredKeys { defaults.set("잔재", forKey: key) }
            WikiSettings.forgetRetiredSettings()
            for key in WikiSettings.retiredKeys {
                XCTAssertNil(defaults.object(forKey: key), key)
            }
        }
    }

    // MARK: - Helpers

    /// Points `rootKey` at a folder this test made, then puts the domain back.
    ///
    /// Not optional, ever. `rootIsReadable` reads the disk, and the path it reads with no
    /// `rootKey` set is the real vault -- so a test that left it unset would pass or fail
    /// on whether the machine running it happens to have that checkout.
    private func withRoot(_ path: String, _ body: () -> Void) throws {
        let defaults = UserDefaults.standard
        let keys = [WikiSettings.rootKey] + WikiSettings.retiredKeys
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        keys.forEach { defaults.removeObject(forKey: $0) }
        defaults.set(path, forKey: WikiSettings.rootKey)
        // Written straight to the domain rather than through `rootPath`, which is what
        // usually clears the memoised probe -- so clear it here, both ways.
        WikiSettings.invalidateRootProbe()
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
            WikiSettings.invalidateRootProbe()
        }
        body()
    }

    private func emptyFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wiki-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

/// Two prompts, two threads. The whole point of the wiki having a window is that reading
/// the vault cannot end up in front of a question about Chrome, and the server replays a
/// whole conversation as the prompt -- so one shared thread would undo the separation no
/// matter what either surface put on the wire.
final class ConversationSlotTests: XCTestCase {
    func testTheTwoSlotsAreDifferentThreads() {
        withSlots {
            LocalLLMSettings.setConversationID("main-1", for: .main)
            LocalLLMSettings.setConversationID("wiki-1", for: .wiki)
            XCTAssertEqual(LocalLLMSettings.conversationID(.main), "main-1")
            XCTAssertEqual(LocalLLMSettings.conversationID(.wiki), "wiki-1")
        }
    }

    /// Starting a new thread in one window must not drop the other's.
    func testClearingOneLeavesTheOther() {
        withSlots {
            LocalLLMSettings.setConversationID("main-1", for: .main)
            LocalLLMSettings.setConversationID("wiki-1", for: .wiki)
            LocalLLMSettings.setConversationID(nil, for: .wiki)
            XCTAssertNil(LocalLLMSettings.conversationID(.wiki))
            XCTAssertEqual(LocalLLMSettings.conversationID(.main), "main-1")
        }
    }

    /// The bare property is the widget's thread. `trolley ask` and `trolley prompt` both
    /// mean that one, and a slot they cannot name must not silently become a third.
    func testTheBarePropertyIsTheMainSlot() {
        withSlots {
            LocalLLMSettings.conversationID = "main-2"
            XCTAssertEqual(LocalLLMSettings.conversationID(.main), "main-2")
            XCTAssertNil(LocalLLMSettings.conversationID(.wiki))
        }
    }

    /// A different server has different conversation ids -- for every slot, not just the
    /// one the address field happens to be thinking about.
    func testChangingTheAddressForgetsEveryThread() {
        withSlots {
            let saved = UserDefaults.standard.object(forKey: LocalLLMSettings.baseURLKey)
            defer {
                if let saved { UserDefaults.standard.set(saved, forKey: LocalLLMSettings.baseURLKey) }
                else { UserDefaults.standard.removeObject(forKey: LocalLLMSettings.baseURLKey) }
            }
            LocalLLMSettings.setConversationID("main-1", for: .main)
            LocalLLMSettings.setConversationID("wiki-1", for: .wiki)
            LocalLLMSettings.baseURLString = "https://elsewhere.example:8443"
            XCTAssertNil(LocalLLMSettings.conversationID(.main))
            XCTAssertNil(LocalLLMSettings.conversationID(.wiki))
        }
    }

    private func withSlots(_ body: () -> Void) {
        let defaults = UserDefaults.standard
        let keys = [LocalLLMSettings.conversationKey, LocalLLMSettings.wikiConversationKey]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        keys.forEach { defaults.removeObject(forKey: $0) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        body()
    }
}

final class LocalLLMWireTests: XCTestCase {
    /// With nothing to add, what goes on the wire is exactly what was typed -- not a
    /// trimmed, wrapped, or otherwise "helpfully" adjusted version of it.
    func testNoContextLeavesThePromptUntouched() {
        XCTAssertEqual(LocalLLMSession.wire(prompt: "안녕"), "안녕")
        XCTAssertEqual(LocalLLMSession.wire(prompt: "  여백 유지  "), "  여백 유지  ")
        // An empty string is not context. Joining it would put a bare separator in front
        // of the question, which reads as a section the model has to account for.
        XCTAssertEqual(LocalLLMSession.wire(prompt: "안녕", context: ""), "안녕")
    }

    /// The server takes one `content` string with no system-prompt field, so position
    /// is the only way to say which part is reference material and which is the ask.
    func testQuestionComesLastAfterASeparator() {
        let wire = LocalLLMSession.wire(prompt: "이 문서 요약해줘", context: "# 문서 본문")
        XCTAssertTrue(wire.hasPrefix("# 문서 본문"))
        XCTAssertTrue(wire.hasSuffix("이 문서 요약해줘"))
        XCTAssertTrue(wire.contains("\n\n---\n\n"))
    }

    /// A question that happens to contain the separator must not be mistaken for the
    /// boundary: the split is by construction, never by parsing.
    func testAQuestionContainingTheSeparatorIsStillWholeAtTheEnd() {
        let tricky = "이 표에서\n\n---\n\n아래 줄이 뭐야?"
        XCTAssertTrue(LocalLLMSession.wire(prompt: tricky, context: "본문").hasSuffix(tricky))
    }

    /// The contract is the rule for the whole exchange; the context is material the
    /// question draws on. A model that reads the document before it has been told what a
    /// tool call looks like has to hold the document while it learns.
    func testTheToolContractComesAheadOfTheContext() {
        let wire = LocalLLMSession.wire(prompt: "질문", context: "문서 본문", tools: FakeCatalog())
        let contract = wire.range(of: "wiki_search")
        let context = wire.range(of: "문서 본문")
        XCTAssertNotNil(contract)
        XCTAssertNotNil(context)
        if let contract, let context {
            XCTAssertTrue(contract.lowerBound < context.lowerBound, wire)
        }
    }
}

/// Just enough of a runner to render a catalog; nothing here runs a tool.
private final class FakeCatalog: LocalLLMToolRunning {
    var toolCatalog: [ToolCallContract.ToolSummary] {
        [.init(name: "wiki_search", parameters: ["status"], summary: "위키에서 문서를 찾는다")]
    }
    var runningAppSummaries: [String] { [] }
    func run(
        name: String,
        arguments: [String: ToolCallContract.JSONArgument],
        completion: @escaping (String) -> Void
    ) {
        completion("{}")
    }
}
