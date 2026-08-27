import Foundation

/// Reads the settings, walks the wiki, and renders the stored filter's digest.
///
/// It used to answer a second question -- whether that digest rides in front of the next
/// question -- and that question no longer exists. Nothing is put in front of a question
/// any more; the wiki is read in its own window. What is left is the digest itself, for
/// `trolley wiki` and the options window's preview, plus the memory of why the last walk
/// failed, which is what the setup row renders.
///
/// Settings are read on every call rather than captured, so changing a filter takes
/// effect on the next render instead of the next launch.
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
