import Foundation

/// A digest that has been decided on, ready to ride in front of a question.
public struct WikiPreamble: Equatable {
    public let digest: WikiDigest
    /// The conversation already holds an older list, so this one has to say to stop
    /// using it. Without the line, the model is looking at two lists and no statement
    /// about which is current.
    public let isRefresh: Bool

    public init(digest: WikiDigest, isRefresh: Bool) {
        self.digest = digest
        self.isRefresh = isRefresh
    }

    public var text: String {
        guard isRefresh else { return digest.text }
        return "이전에 보낸 위키 목록은 무시하고, 아래 목록만 참고하세요.\n\n" + digest.text
    }
}

/// Whether this question carries the wiki.
///
/// Separated out and kept pure because it is the load-bearing decision of the whole
/// feature. The server persists conversation history and re-prefills all of it on
/// every turn, so a preamble attached per-question would cost N times the budget by
/// turn N -- 8KB of list repeated twenty times is most of the model's context spent
/// re-reading the same thing.
public enum WikiInjection {
    public enum Decision: Equatable {
        case send(isRefresh: Bool)
        case skipDisabled
        case skipNoRoot
        case skipEmpty
        case skipAlreadySent
        /// The wiki keeps changing inside one long conversation. Past this point the
        /// history is better served by starting over than by another block.
        case skipCapReached
    }

    /// - Parameter conversationID: nil means a fresh conversation is about to be
    ///   created, so nothing has been said in it yet.
    public static func decide(
        enabled: Bool,
        digest: WikiDigest?,
        conversationID: String?,
        sent: WikiSettings.SentRecord?,
        cap: Int = WikiSettings.refreshCap
    ) -> Decision {
        guard enabled else { return .skipDisabled }
        guard let digest else { return .skipNoRoot }
        // A header with no rows under it tells the model nothing and still costs a
        // few hundred characters in every later turn.
        guard !digest.isEmpty else { return .skipEmpty }

        guard let conversationID, !conversationID.isEmpty else { return .send(isRefresh: false) }
        guard let sent, sent.conversationID == conversationID else {
            // Either nothing has been sent, or it was sent into a different
            // conversation -- including the one the server has since forgotten, whose
            // id is replaced on the next send.
            return .send(isRefresh: false)
        }
        guard sent.digestHash != digest.hash else { return .skipAlreadySent }
        guard sent.count < cap else { return .skipCapReached }
        return .send(isRefresh: true)
    }
}

/// Reads the settings, walks the wiki, and answers the one question the prompt path
/// asks: is there a preamble for this send, and what is it.
///
/// Settings are read on every call rather than captured, matching the way
/// `LocalLLMSession` re-reads `makeClient` -- so changing a filter takes effect on the
/// next question instead of the next launch.
public final class WikiContext {
    public static let shared = WikiContext()

    private let lock = NSLock()
    private var failure: WikiIndex.Failure?
    private let index: WikiIndex
    /// The last rendered digest, with what it was rendered from.
    ///
    /// The index already throttles disk walks, but rendering was still running per
    /// call -- and the panel rebuilds its model on **every arriving token**, so a
    /// streaming answer was re-sorting 110 pages and rebuilding 7,600 characters
    /// hundreds of times a second for a hint line that had not changed. Keyed on the
    /// filter and on when the snapshot was built, so an edited wiki still refreshes.
    private var cached: (fingerprint: String, builtAt: Date, digest: WikiDigest)?

    public init(index: WikiIndex = .shared) {
        self.index = index
    }

    /// What went wrong last time the wiki was read, for the setup row to render.
    public var lastFailure: WikiIndex.Failure? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }

    /// The current filter's digest, or nil when there is no readable wiki.
    ///
    /// Never throws to the caller: a wiki that moved must not be able to make a
    /// question fail. The failure is recorded for the setup window and the question
    /// goes out bare.
    public func currentDigest() -> WikiDigest? {
        guard let root = WikiSettings.rootURL else {
            record(.noRoot)
            return nil
        }
        let filter = WikiSettings.filter
        do {
            let snapshot = try index.snapshot(root: root, folders: walkTargets(for: filter))
            record(nil)

            let key = filter.fingerprint + "|budget=\(WikiSettings.budgetCharacters)|root=\(root.path)"
            lock.lock()
            let hit = cached
            lock.unlock()
            if let hit, hit.fingerprint == key, hit.builtAt == snapshot.builtAt {
                return hit.digest
            }

            let digest = WikiDigestRenderer.render(
                pages: snapshot.pages,
                filter: filter,
                rootName: root.lastPathComponent,
                budgetCharacters: WikiSettings.budgetCharacters
            )
            lock.lock()
            cached = (key, snapshot.builtAt, digest)
            lock.unlock()
            return digest
        } catch let failure as WikiIndex.Failure {
            record(failure)
            return nil
        } catch {
            record(.missing(root.path))
            return nil
        }
    }

    public func preamble(conversationID: String?) -> WikiPreamble? {
        // Checked before the walk, not inside `decide`: walking the disk only to throw
        // the result away is the one cost this can avoid outright, and this runs on
        // the main thread between a keystroke and a network request.
        //
        // `.auto` is the same early return as `.off` here and a different thing entirely
        // one level down: it means the wiki is reachable but nothing rides *in front of*
        // the question, because under that mode the model asks for what it needs through
        // `wiki_search` once it knows what was asked.
        guard WikiSettings.mode == .manual else { return nil }
        let digest = currentDigest()
        let decision = WikiInjection.decide(
            enabled: true,
            digest: digest,
            conversationID: conversationID,
            sent: WikiSettings.sent
        )
        guard case .send(let isRefresh) = decision, let digest else { return nil }
        return WikiPreamble(digest: digest, isRefresh: isRefresh)
    }

    /// Records that the model has been told. Called once the message is on its way.
    public func commit(_ preamble: WikiPreamble, conversationID: String) {
        WikiSettings.sent = WikiSettings.SentRecord(
            conversationID: conversationID,
            digestHash: preamble.digest.hash,
            count: Self.nextCount(previous: WikiSettings.sent, conversationID: conversationID)
        )
    }

    /// How many blocks this conversation will have been given.
    ///
    /// Pure, because it is what the refresh cap counts and the cap is the only thing
    /// standing between a wiki edited all afternoon and a history full of near-identical
    /// lists. Moving to a different conversation restarts at one: the cap is a property
    /// of one conversation's history, not of the app's lifetime.
    static func nextCount(previous: WikiSettings.SentRecord?, conversationID: String) -> Int {
        guard let previous, previous.conversationID == conversationID else { return 1 }
        return previous.count + 1
    }

    /// Whether the conversation has been handed as many refreshes as it may get, which
    /// is what the panel hint and the setup row report.
    public func isRefreshCapped(conversationID: String?) -> Bool {
        guard let conversationID, let sent = WikiSettings.sent,
              sent.conversationID == conversationID
        else { return false }
        return sent.count >= WikiSettings.refreshCap
    }

    /// Only walk folders the filter can match; `_private` is not on the list at all.
    private func walkTargets(for filter: WikiFilter) -> [String] {
        let available = WikiIndex.indexableFolders + WikiIndex.optionalFolders
        guard !filter.folders.isEmpty else { return WikiIndex.indexableFolders }
        let chosen = available.filter { candidate in
            filter.folders.contains { $0 == candidate || candidate.hasPrefix($0 + "/") }
        }
        return chosen.isEmpty ? WikiIndex.indexableFolders : chosen
    }

    /// Drops the rendered digest. Called when the root changes, so a new checkout
    /// cannot be described by the old one's list.
    public func invalidate() {
        lock.lock()
        cached = nil
        lock.unlock()
    }

    private func record(_ newValue: WikiIndex.Failure?) {
        lock.lock()
        failure = newValue
        lock.unlock()
    }
}
