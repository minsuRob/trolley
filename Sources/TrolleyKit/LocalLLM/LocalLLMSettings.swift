import Foundation

/// Where the widget's prompt box sends what you type.
///
/// The default is the sister project's Tailscale Funnel URL rather than
/// `localhost`: that server is reachable under the same name from this machine
/// and from anything else on the internet, so one value works whether trolley
/// is running beside it or on another Mac. It is also the address that stays
/// correct when the model host moves -- Funnel follows the machine, a LAN IP
/// does not.
///
/// Stored in `UserDefaults` so a change survives `trolley update`, which
/// replaces the bundle wholesale.
public enum LocalLLMSettings {
    /// `DiffusionGemma-local` behind `--expose funnel` (the server's default),
    /// which publishes on 8443.
    public static let fallbackBaseURL = "https://feeeld-inc-macbookpro-2.tail15c8bb.ts.net:8443"

    public static let baseURLKey = "trolley.localLLM.baseURL"
    public static let tokenKey = "trolley.localLLM.token"
    public static let conversationKey = "trolley.localLLM.conversationID"
    public static let wikiConversationKey = "trolley.localLLM.wiki.conversationID"

    private static var defaults: UserDefaults { .standard }

    /// The configured address, or the default when nothing has been set.
    public static var baseURLString: String {
        get {
            let stored = defaults.string(forKey: baseURLKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return stored.isEmpty ? fallbackBaseURL : stored
        }
        set {
            let cleaned = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            // Storing the default as an explicit value would freeze it: a later
            // release changing `fallbackBaseURL` could no longer reach anyone
            // who had merely accepted it.
            if cleaned.isEmpty || cleaned == fallbackBaseURL {
                defaults.removeObject(forKey: baseURLKey)
            } else {
                defaults.set(cleaned, forKey: baseURLKey)
            }
            // A different server has different conversation ids -- every slot's.
            for slot in ConversationSlot.allCases { defaults.removeObject(forKey: slot.key) }
        }
    }

    public static var baseURL: URL? { normalize(baseURLString) }

    /// Only needed when the server runs `--auth token`; empty for its default
    /// `--auth open`.
    public static var token: String? {
        get {
            let stored = defaults.string(forKey: tokenKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return stored.isEmpty ? nil : stored
        }
        set {
            let cleaned = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if cleaned.isEmpty {
                defaults.removeObject(forKey: tokenKey)
            } else {
                defaults.set(cleaned, forKey: tokenKey)
            }
        }
    }

    /// Which thread a session talks into.
    ///
    /// Two, because the wiki window is a different conversation than the prompt box and
    /// has to stay one. The server replays a whole conversation as the prompt, so a
    /// shared thread would put a document body the wiki window sent in front of every
    /// later "크롬 켜줘" -- which is exactly the coupling the window exists to end.
    public enum ConversationSlot: CaseIterable {
        /// The widget's prompt box: this Mac, its apps, the tool loop.
        case main
        /// The wiki window: the vault, and nothing that can touch the screen.
        case wiki

        var key: String {
            switch self {
            case .main: return conversationKey
            case .wiki: return wikiConversationKey
            }
        }
    }

    /// The thread that slot keeps talking into, so a follow-up question has the previous
    /// turns behind it -- and so the same conversation is readable in the server's own
    /// web UI. Cleared when the server no longer knows it.
    public static func conversationID(_ slot: ConversationSlot) -> String? {
        defaults.string(forKey: slot.key)
    }

    public static func setConversationID(_ newValue: String?, for slot: ConversationSlot) {
        if let newValue, !newValue.isEmpty {
            defaults.set(newValue, forKey: slot.key)
        } else {
            defaults.removeObject(forKey: slot.key)
        }
    }

    /// The widget's thread, for callers that only ever mean that one -- `trolley ask`
    /// and `trolley prompt` both talk into the box a person is looking at.
    public static var conversationID: String? {
        get { conversationID(.main) }
        set { setConversationID(newValue, for: .main) }
    }

    public static func makeConfig() -> LocalLLMClient.Config? {
        guard let url = baseURL else { return nil }
        return LocalLLMClient.Config(baseURL: url, token: token)
    }

    /// Accepts what someone would actually paste: a bare host, a URL with a
    /// path, a trailing slash. Anything without a scheme is assumed `https`,
    /// which is what both Funnel modes serve.
    public static func normalize(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") {
            text = "https://" + text
        }
        while text.hasSuffix("/") {
            text.removeLast()
        }
        guard let url = URL(string: text), let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}
