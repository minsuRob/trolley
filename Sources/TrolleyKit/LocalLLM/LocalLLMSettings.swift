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
            // A different server has different conversation ids.
            defaults.removeObject(forKey: conversationKey)
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

    /// The thread the widget keeps talking into, so a follow-up question has the
    /// previous turns behind it -- and so the same conversation is readable in
    /// the server's own web UI. Cleared when the server no longer knows it.
    public static var conversationID: String? {
        get { defaults.string(forKey: conversationKey) }
        set {
            if let newValue, !newValue.isEmpty {
                defaults.set(newValue, forKey: conversationKey)
            } else {
                defaults.removeObject(forKey: conversationKey)
            }
        }
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
