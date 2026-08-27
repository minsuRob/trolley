import XCTest
@testable import TrolleyKit

final class WikiInjectionTests: XCTestCase {
    private func digest(_ hash: String, matched: Int = 5) -> WikiDigest {
        WikiDigest(text: "목록", hash: hash, matched: matched, total: matched, characters: 2)
    }

    private func sent(_ conversation: String, _ hash: String, count: Int = 1) -> WikiSettings.SentRecord {
        WikiSettings.SentRecord(conversationID: conversation, digestHash: hash, count: count)
    }

    private func decide(
        enabled: Bool = true,
        digest: WikiDigest? = nil,
        conversation: String? = "conv-1",
        sent: WikiSettings.SentRecord? = nil,
        cap: Int = 5
    ) -> WikiInjection.Decision {
        WikiInjection.decide(
            enabled: enabled,
            digest: digest ?? self.digest("aaa"),
            conversationID: conversation,
            sent: sent,
            cap: cap
        )
    }

    // MARK: - The mode

    /// The migration that matters: a build before `modeKey` stored only the boolean, and
    /// whatever it said has to keep meaning something after the upgrade rather than
    /// resetting the wiki to off for everyone who had it on.
    func testAnUpgradedWikiKeepsWorkingAndLandsOnAuto() {
        withCleanDefaults {
            UserDefaults.standard.set(true, forKey: WikiSettings.enabledKey)
            XCTAssertEqual(WikiSettings.mode, .auto)
            XCTAssertTrue(WikiSettings.isEnabled)

            UserDefaults.standard.set(false, forKey: WikiSettings.enabledKey)
            XCTAssertEqual(WikiSettings.mode, .off)
            XCTAssertFalse(WikiSettings.isEnabled)
        }
    }

    /// `trolley update` can put an older bundle back on the same defaults domain, and
    /// that build reads only the boolean. Writing both is what keeps a rollback from
    /// silently turning the wiki off.
    func testWritingTheModeAlsoWritesTheBooleanTheOldBuildReads() {
        withCleanDefaults {
            for mode in WikiSettings.Mode.allCases {
                WikiSettings.mode = mode
                XCTAssertEqual(
                    UserDefaults.standard.bool(forKey: WikiSettings.enabledKey),
                    mode != .off,
                    "\(mode.rawValue) 가 옛 빌드에 잘못 보인다"
                )
            }
        }
    }

    /// Only 직접 지정 ever sends a list, so leaving it means the record of what was sent
    /// is about a mode that is no longer in force.
    func testLeavingManualForgetsWhatWasSent() {
        withCleanDefaults {
            WikiSettings.mode = .manual
            WikiSettings.sent = sent("conv-1", "aaa")
            WikiSettings.mode = .auto
            XCTAssertNil(WikiSettings.sent)
        }
    }

    /// Runs a body against the two keys this file writes, then puts the domain back --
    /// these are process defaults, and a test that leaves them set is a test that
    /// changes what the next one reads.
    private func withCleanDefaults(_ body: () -> Void) {
        let defaults = UserDefaults.standard
        let keys = [WikiSettings.modeKey, WikiSettings.enabledKey,
                    WikiSettings.sentConversationKey, WikiSettings.sentHashKey,
                    WikiSettings.sentCountKey]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        keys.forEach { defaults.removeObject(forKey: $0) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        body()
    }

    // MARK: - The table

    /// A fresh conversation has been told nothing, whatever was sent to the last one.
    func testFreshConversationAlwaysGetsTheDigest() {
        XCTAssertEqual(decide(conversation: nil), .send(isRefresh: false))
        XCTAssertEqual(
            decide(conversation: nil, sent: sent("conv-old", "aaa", count: 99)),
            .send(isRefresh: false)
        )
    }

    func testNothingSentYetMeansSend() {
        XCTAssertEqual(decide(sent: nil), .send(isRefresh: false))
    }

    /// The whole point of the design: the same list is not re-sent turn after turn
    /// into a history the server re-prefills every time.
    func testSameContentInTheSameConversationIsNotResent() {
        XCTAssertEqual(decide(sent: sent("conv-1", "aaa")), .skipAlreadySent)
    }

    func testChangedContentIsResentAsARefresh() {
        XCTAssertEqual(decide(sent: sent("conv-1", "older")), .send(isRefresh: true))
    }

    /// A wiki edited repeatedly inside one long conversation would otherwise drip a
    /// fresh block into the history on every change.
    func testRefreshesStopAtTheCap() {
        XCTAssertEqual(decide(sent: sent("conv-1", "older", count: 4), cap: 5), .send(isRefresh: true))
        XCTAssertEqual(decide(sent: sent("conv-1", "older", count: 5), cap: 5), .skipCapReached)
        XCTAssertEqual(decide(sent: sent("conv-1", "older", count: 9), cap: 5), .skipCapReached)
    }

    /// The recovery path for a conversation the server forgot: `LocalLLMClient` starts
    /// a new one, its id differs from the recorded one, and the next turn re-sends.
    func testADifferentConversationIsTreatedAsUntold() {
        XCTAssertEqual(decide(sent: sent("conv-other", "aaa", count: 9)), .send(isRefresh: false))
    }

    // MARK: - Guards

    func testDisabledNeverSends() {
        XCTAssertEqual(decide(enabled: false, conversation: nil), .skipDisabled)
    }

    func testNoDigestNeverSends() {
        XCTAssertEqual(
            WikiInjection.decide(enabled: true, digest: nil, conversationID: nil, sent: nil),
            .skipNoRoot
        )
    }

    /// A header with no rows tells the model nothing and still costs a few hundred
    /// characters in every later turn.
    func testEmptyResultIsNotWorthSending() {
        XCTAssertEqual(decide(digest: digest("aaa", matched: 0), conversation: nil), .skipEmpty)
    }

    // MARK: - Preamble text

    func testPlainPreambleIsJustTheDigest() {
        let preamble = WikiPreamble(digest: digest("aaa"), isRefresh: false)
        XCTAssertEqual(preamble.text, "목록")
    }

    /// Without this line the conversation holds two lists and no statement about which
    /// one is current.
    func testRefreshPreambleSupersedesTheOlderList() {
        let preamble = WikiPreamble(digest: digest("aaa"), isRefresh: true)
        XCTAssertTrue(preamble.text.hasPrefix("이전에 보낸 위키 목록은 무시하고"))
        XCTAssertTrue(preamble.text.hasSuffix("목록"))
    }
}

final class LocalLLMWireTests: XCTestCase {
    private func preamble(_ text: String, isRefresh: Bool = false) -> WikiPreamble {
        WikiPreamble(
            digest: WikiDigest(text: text, hash: "h", matched: 1, total: 1, characters: text.count),
            isRefresh: isRefresh
        )
    }

    /// With the wiki off, or nothing to say, what goes on the wire is exactly what was
    /// typed -- not a trimmed, wrapped, or otherwise "helpfully" adjusted version of it.
    func testNoPreambleLeavesThePromptUntouched() {
        XCTAssertEqual(LocalLLMSession.wire(prompt: "안녕", preamble: nil), "안녕")
        XCTAssertEqual(LocalLLMSession.wire(prompt: "  여백 유지  ", preamble: nil), "  여백 유지  ")
    }

    /// The server takes one `content` string with no system-prompt field, so position
    /// is the only way to say which part is reference material and which is the ask.
    func testQuestionComesLastAfterASeparator() {
        let wire = LocalLLMSession.wire(prompt: "최우선 일감은?", preamble: preamble("[위키] 목록"))
        XCTAssertTrue(wire.hasPrefix("[위키] 목록"))
        XCTAssertTrue(wire.hasSuffix("최우선 일감은?"))
        XCTAssertTrue(wire.contains("\n\n---\n\n"))
    }

    func testRefreshSupersedesTheEarlierListAheadOfTheQuestion() {
        let wire = LocalLLMSession.wire(prompt: "질문", preamble: preamble("[위키] 새 목록", isRefresh: true))
        XCTAssertTrue(wire.hasPrefix("이전에 보낸 위키 목록은 무시하고"))
        XCTAssertTrue(wire.hasSuffix("질문"))
    }

    /// A question that happens to contain the separator must not be mistaken for the
    /// boundary: the split is by construction, never by parsing.
    func testAQuestionContainingTheSeparatorIsStillWholeAtTheEnd() {
        let tricky = "이 표에서\n\n---\n\n아래 줄이 뭐야?"
        XCTAssertTrue(LocalLLMSession.wire(prompt: tricky, preamble: preamble("목록")).hasSuffix(tricky))
    }
}

final class WikiCommitCountTests: XCTestCase {
    private func sent(_ conversation: String, count: Int) -> WikiSettings.SentRecord {
        WikiSettings.SentRecord(conversationID: conversation, digestHash: "h", count: count)
    }

    func testFirstSendIntoAConversationCountsAsOne() {
        XCTAssertEqual(WikiContext.nextCount(previous: nil, conversationID: "conv-1"), 1)
    }

    func testRefreshesAccumulateWithinOneConversation() {
        XCTAssertEqual(WikiContext.nextCount(previous: sent("conv-1", count: 1), conversationID: "conv-1"), 2)
        XCTAssertEqual(WikiContext.nextCount(previous: sent("conv-1", count: 4), conversationID: "conv-1"), 5)
    }

    /// The cap belongs to one conversation's history, not to the app's lifetime, so a
    /// new conversation starts over -- otherwise a long-running app would eventually
    /// stop attaching the wiki to anything.
    func testMovingToANewConversationRestartsTheCount() {
        XCTAssertEqual(WikiContext.nextCount(previous: sent("conv-old", count: 5), conversationID: "conv-new"), 1)
    }

    /// The counter and the cap agree: the value that `decide` refuses is the value
    /// this produces on the send before it.
    func testCountReachesTheCapExactlyWhenDecideStops() {
        var record = sent("conv-1", count: WikiSettings.refreshCap - 1)
        let digest = WikiDigest(text: "새 목록", hash: "new", matched: 1, total: 1, characters: 3)
        XCTAssertEqual(
            WikiInjection.decide(enabled: true, digest: digest, conversationID: "conv-1", sent: record),
            .send(isRefresh: true)
        )
        record = sent("conv-1", count: WikiContext.nextCount(previous: record, conversationID: "conv-1"))
        XCTAssertEqual(record.count, WikiSettings.refreshCap)
        XCTAssertEqual(
            WikiInjection.decide(enabled: true, digest: digest, conversationID: "conv-1", sent: record),
            .skipCapReached
        )
    }
}

/// The digest no longer rides every question.
///
/// It is not a preference -- it is what the server's replay makes of it. Every message
/// of a conversation is re-sent as the prompt on every turn, and the loop posts a
/// `[도구 결과]` turn per tool call, so a digest "sent once" is re-sent in full for the
/// life of the thread. The wiki stays reachable as a tool instead.
final class WikiIsNotInjectedByDefaultTests: XCTestCase {
    func testDefaultSessionSendsTheQuestionAlone() {
        var sent: [String] = []
        let session = LocalLLMSession(
            makeTurn: {
                { content, _, _, _ in
                    sent.append(content)
                    return NoopStoppable()
                }
            }
        )
        session.send("크롬 켜줘")
        XCTAssertEqual(sent, ["크롬 켜줘"])
    }

    /// The plumbing is intact, so turning it back on is one argument rather than a
    /// rewrite -- and the wire format stays covered either way.
    func testAPreambleStillRidesWhenOneIsSupplied() {
        var sent: [String] = []
        let session = LocalLLMSession(
            makeTurn: {
                { content, _, _, _ in
                    sent.append(content)
                    return NoopStoppable()
                }
            },
            makeWikiPreamble: { _ in
                WikiPreamble(
                    digest: WikiDigest(
                        text: "[위키] 목록", hash: "h", matched: 1, total: 1, characters: 8
                    ),
                    isRefresh: false
                )
            }
        )
        session.send("크롬 켜줘")
        XCTAssertEqual(sent.first?.contains("[위키] 목록"), true)
        XCTAssertEqual(sent.first?.hasSuffix("크롬 켜줘"), true)
    }
}

private final class NoopStoppable: LocalLLMStoppable {
    func cancel() {}
}
