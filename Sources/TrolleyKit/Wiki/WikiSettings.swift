import Foundation

/// Where the wiki is, whether to use it, and how to filter it.
///
/// Same shape as `LocalLLMSettings`: a namespace of static computed properties over
/// `UserDefaults.standard`, keys under `trolley.`, and a value equal to the built-in
/// default is *removed* rather than stored -- so a later release can change a default
/// for everyone who merely accepted it.
///
/// The MCP server and the CLI read these too. They run from the executable inside the
/// app bundle, so `Bundle.main.bundleIdentifier` resolves and they share the app's
/// defaults domain -- the same way `trolley ask` already shares the model address.
public enum WikiSettings {
    /// The one place in this codebase that names the real wiki. No test may reference
    /// it: those files are edited daily by people, and a test that reads them fails on
    /// someone else's commit.
    ///
    /// Prefilling a path is safe because of what `rootIsReadable` asks of it. A wrong
    /// model address fails loudly on the next question; a wrong *path* just quietly
    /// reads somebody else's folder -- so the folder at this path has to carry the
    /// vault's own `context/` layout before anything reads it, and a folder that merely
    /// happens to sit here is not mistaken for the wiki.
    public static let fallbackRoot = "~/Desktop/workspace/MAKi/markhub-llm-wiki"

    public static let rootKey = "trolley.wiki.root"
    public static let enabledKey = "trolley.wiki.enabled"
    public static let modeKey = "trolley.wiki.mode"
    public static let filterKey = "trolley.wiki.filter"
    public static let budgetKey = "trolley.wiki.budgetCharacters"
    public static let sentConversationKey = "trolley.wiki.sent.conversationID"
    public static let sentHashKey = "trolley.wiki.sent.digestHash"
    public static let sentCountKey = "trolley.wiki.sent.count"

    /// How many times one conversation may be handed a refreshed digest before it is
    /// told to start a new one. Without a cap, a wiki edited through a long session
    /// drips a fresh 8KB block into the history on every change.
    public static let refreshCap = 5

    private static var defaults: UserDefaults { .standard }

    /// Stored with `~` intact so the setting survives a home directory that moves,
    /// and expanded only on the way out.
    public static var rootPath: String {
        get {
            let stored = defaults.string(forKey: rootKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return stored.isEmpty ? fallbackRoot : stored
        }
        set {
            let cleaned = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty || cleaned == fallbackRoot {
                defaults.removeObject(forKey: rootKey)
            } else {
                defaults.set(cleaned, forKey: rootKey)
            }
            // Pages from the previous checkout must not survive into the new one.
            clearSent()
            // And neither may the verdict on whether the previous one was a wiki --
            // `mode` reads that, so a stale one decides on/off for the next two seconds.
            invalidateRootProbe()
        }
    }

    public static var rootURL: URL? {
        let expanded = NSString(string: rootPath).expandingTildeInPath
        guard !expanded.isEmpty else { return nil }
        return URL(fileURLWithPath: expanded)
    }

    // MARK: - A wiki that is simply there

    /// How long a look at the root is trusted for. Two seconds, matching the gate
    /// `WikiIndex` puts in front of its walk, and for the same reason: `mode` reads this,
    /// and `mode` is read on every send, on every tool-catalog build, and forty times a
    /// minute by the setup window's repaint timer.
    private static let probeInterval: TimeInterval = 2.0
    private static let probeLock = NSLock()
    private static var probed: (path: String, readable: Bool, at: Date)?

    /// Whether `rootPath` currently points at something that reads like the vault.
    ///
    /// A readable directory is deliberately not enough. The default path is prefilled
    /// into every install, so "a folder exists there" says nothing about whether it is
    /// this team's wiki; one of the folders the index actually walks has to be under it.
    /// That is the whole difference between switching on for a checkout somebody has and
    /// switching on for a coincidence.
    ///
    /// Three `stat`s at worst, memoised -- see `probeInterval` for why that matters.
    public static var rootIsReadable: Bool {
        guard let root = rootURL else { return false }
        probeLock.lock()
        let hit = probed
        probeLock.unlock()
        if let hit, hit.path == root.path, Date().timeIntervalSince(hit.at) < probeInterval {
            return hit.readable
        }
        let readable = probeRoot(root)
        probeLock.lock()
        probed = (root.path, readable, Date())
        probeLock.unlock()
        return readable
    }

    /// Makes the next `rootIsReadable` look at the disk again. The root setter calls it;
    /// so does anything that has just changed what the disk would answer -- a folder
    /// picked through the panel is readable a moment after it was not, and waiting out
    /// the memo would show 꺼짐 for two seconds after the grant.
    public static func invalidateRootProbe() {
        probeLock.lock()
        probed = nil
        probeLock.unlock()
    }

    private static func probeRoot(_ root: URL) -> Bool {
        let manager = FileManager.default
        guard isDirectory(manager, root.path), manager.isReadableFile(atPath: root.path)
        else { return false }
        return WikiIndex.indexableFolders.contains { folder in
            isDirectory(manager, root.appendingPathComponent(folder).path)
        }
    }

    private static func isDirectory(_ manager: FileManager, _ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return manager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Who decides what the wiki contributes to a question.
    ///
    /// This replaced a boolean, and the reason is the middle case. On/off could only
    /// say *whether* the wiki was consulted; the filter -- 유형, 상태, 영역, 담당, 폴더 --
    /// was always a person's standing choice, made once in the options window and then
    /// applied to every question regardless of what was asked. A question about one
    /// task carried the same 84-title list as a question about none.
    ///
    /// `.auto` hands that choice to trolley instead: nothing rides in front of the
    /// question, and the model picks the axes per question through `wiki_search`. That
    /// is strictly more selective than any stored filter can be, because it is chosen
    /// after the question is known rather than before.
    public enum Mode: String, CaseIterable {
        /// Nothing. No digest, and the wiki tools are not in the catalog either -- a
        /// tool that is listed but must not be used is worse than one that is absent.
        case off
        /// trolley picks. No list in front of the question; `wiki_search`/`wiki_read`
        /// are in the catalog with every axis open, and the stored filter is not
        /// applied to them.
        case auto
        /// The stored filter decides, and its digest rides the first question of a
        /// conversation. What every enabled wiki did before `.auto` existed.
        case manual

        public var title: String {
            switch self {
            case .off: return "끔"
            case .auto: return "자동 — trolley가 고름"
            case .manual: return "직접 지정"
            }
        }
    }

    /// On when there is a wiki to be on about.
    ///
    /// This used to start `.off` and wait to be switched on, and what that cost is the
    /// reason it no longer does: the folder read fine, the options window's preview
    /// listed all 48 pages of it, and the setup row still said 꺼져 있음 -- because the
    /// preview never consulted the switch. A checkbox standing between a folder already
    /// on the disk and the wiki counting for anything only ever produced that.
    ///
    /// So the disk decides, unless a person has said otherwise. A stored choice always
    /// wins: picking 끔 writes `modeKey`, and that keeps it off for good. `.auto` rather
    /// than `.manual` is what a detected wiki lands on -- it is the mode that spends no
    /// context up front, which is the only honest default for something nobody asked
    /// for.
    ///
    /// The legacy boolean still means `.auto` when it says true. When it says false it is
    /// *not* read as a refusal: false was the old default, so it is equally what every
    /// install that never opened the window stored, and the two cannot be told apart.
    /// Anyone who does mean off now says so in a window that records it as such.
    public static var mode: Mode {
        get {
            if let raw = defaults.string(forKey: modeKey), let stored = Mode(rawValue: raw) {
                return stored
            }
            if defaults.bool(forKey: enabledKey) { return .auto }
            return rootIsReadable ? .auto : .off
        }
        set {
            defaults.set(newValue.rawValue, forKey: modeKey)
            // The boolean is still written, and for the same reason `WikiFilter` still
            // encodes `includeSummary`: `trolley update` can put an older bundle back
            // on the same defaults domain, and that build reads only this key.
            defaults.set(newValue != .off, forKey: enabledKey)
            // Only `.manual` ever sends a digest, so leaving it means whatever the
            // conversation was told is no longer something to compare against.
            if newValue != .manual { clearSent() }
        }
    }

    /// True when nothing is stored and the folder itself is what turned the wiki on.
    ///
    /// Exists so the setup row and `trolley wiki` can say *why* it is on. Being told the
    /// wiki is 자동 is not the same as being told nobody chose that -- and someone who
    /// wants it off needs to know there is a switch they have never touched.
    public static var modeWasDetected: Bool {
        defaults.string(forKey: modeKey) == nil
            && !defaults.bool(forKey: enabledKey)
            && rootIsReadable
    }

    /// Whether the wiki is reachable at all -- as a digest or as a tool.
    ///
    /// Kept because that is the question most callers actually have (the setup row, the
    /// prewarm, the tool catalog), and none of them care which of the two enabled modes
    /// is set. Writing `true` means `.auto`, which is what "turn the wiki on" now means.
    public static var isEnabled: Bool {
        get { mode != .off }
        set { mode = newValue ? .auto : .off }
    }

    /// A stored filter that no longer decodes -- an older release's shape -- falls
    /// back to the default rather than throwing. The wiki going quiet is a much
    /// smaller problem than the prompt box refusing to send.
    public static var filter: WikiFilter {
        get {
            guard let data = defaults.data(forKey: filterKey),
                  let decoded = try? JSONDecoder().decode(WikiFilter.self, from: data)
            else { return .default }
            return decoded
        }
        set {
            if newValue == .default {
                defaults.removeObject(forKey: filterKey)
            } else if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: filterKey)
            }
        }
    }

    public static var budgetCharacters: Int {
        get {
            let stored = defaults.integer(forKey: budgetKey)
            guard stored > 0 else { return WikiDigestRenderer.defaultBudget }
            return min(max(stored, 500), 20_000)
        }
        set {
            let clamped = min(max(newValue, 500), 20_000)
            if clamped == WikiDigestRenderer.defaultBudget {
                defaults.removeObject(forKey: budgetKey)
            } else {
                defaults.set(clamped, forKey: budgetKey)
            }
        }
    }

    /// What the model has already been told, and in which conversation.
    public struct SentRecord: Equatable {
        public let conversationID: String
        public let digestHash: String
        public let count: Int

        public init(conversationID: String, digestHash: String, count: Int) {
            self.conversationID = conversationID
            self.digestHash = digestHash
            self.count = count
        }
    }

    public static var sent: SentRecord? {
        get {
            guard let conversation = defaults.string(forKey: sentConversationKey),
                  !conversation.isEmpty,
                  let hash = defaults.string(forKey: sentHashKey), !hash.isEmpty
            else { return nil }
            return SentRecord(
                conversationID: conversation,
                digestHash: hash,
                count: max(1, defaults.integer(forKey: sentCountKey))
            )
        }
        set {
            guard let newValue else { clearSent(); return }
            defaults.set(newValue.conversationID, forKey: sentConversationKey)
            defaults.set(newValue.digestHash, forKey: sentHashKey)
            defaults.set(newValue.count, forKey: sentCountKey)
        }
    }

    // MARK: - Who "me" is

    public static let meKey = "trolley.wiki.me"

    /// The 담당 handle that means "me", for the 내 일감 preset.
    ///
    /// There is no way to derive this. The vault's 담당 values are GitHub handles and
    /// the Mac knows only `NSUserName()`, a short user name; the `minsuRob` in
    /// `Version.swift` is the release repo's owner, not whoever is running the build.
    /// Guessing either would be wrong for two of this vault's three people, so it is
    /// learned instead -- picking yourself in the 담당 popup and saving is what sets it.
    ///
    /// Deliberately does *not* `clearSent()`: this is not part of the digest.
    public static var me: String {
        get {
            defaults.string(forKey: meKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        set {
            let cleaned = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty {
                defaults.removeObject(forKey: meKey)
            } else {
                defaults.set(cleaned, forKey: meKey)
            }
        }
    }

    public static func clearSent() {
        defaults.removeObject(forKey: sentConversationKey)
        defaults.removeObject(forKey: sentHashKey)
        defaults.removeObject(forKey: sentCountKey)
    }
}
