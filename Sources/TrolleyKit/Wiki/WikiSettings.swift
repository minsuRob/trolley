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
    /// Prefilling a path is safe only because `isEnabled` starts false. A wrong model
    /// address fails loudly on the next question; a wrong *path* just quietly reads
    /// somebody else's folder, so nothing is read until a person switches it on.
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
        }
    }

    public static var rootURL: URL? {
        let expanded = NSString(string: rootPath).expandingTildeInPath
        guard !expanded.isEmpty else { return nil }
        return URL(fileURLWithPath: expanded)
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

    /// Off until someone turns it on. Injecting into a conversation nobody asked to
    /// have augmented is a context-budget surprise, and the setup row is where the
    /// asking happens.
    ///
    /// A build that predates `modeKey` stored only the boolean, and an enabled wiki
    /// there becomes `.auto` rather than `.manual`. That is a deliberate change of
    /// behaviour for someone who merely accepted the old default: the stored filter
    /// they never opened was costing them the whole list on every first question, and
    /// `.manual` is one radio button away for anyone who did mean it.
    public static var mode: Mode {
        get {
            if let raw = defaults.string(forKey: modeKey), let stored = Mode(rawValue: raw) {
                return stored
            }
            return defaults.bool(forKey: enabledKey) ? .auto : .off
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
