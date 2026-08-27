import Foundation

/// Where the wiki is and how to filter it.
///
/// No longer *whether* to use it. The wiki used to ride in front of every question and
/// sit in every question's tool list, so a switch had to exist; now it is reachable only
/// from its own window, where opening it is the switch. What is left here is the folder,
/// the filter that window starts from, and the numbers the CLI prints.
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
    public static let filterKey = "trolley.wiki.filter"
    public static let budgetKey = "trolley.wiki.budgetCharacters"

    /// Written by builds that gated the wiki behind a switch. Named only so an upgrade
    /// can clear them: an old bundle put back by `trolley update` would read `enabled`
    /// again, and leaving a stale `false` there would turn its wiki off for reasons
    /// nobody could see from this build.
    static let retiredKeys = [
        "trolley.wiki.enabled", "trolley.wiki.mode",
        "trolley.wiki.sent.conversationID", "trolley.wiki.sent.digestHash",
        "trolley.wiki.sent.count"
    ]

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
            // The verdict on whether the old folder was a wiki must not survive it:
            // `rootIsReadable` is what decides the window opens at all.
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
    /// `WikiIndex` puts in front of its walk, and for the same reason: this is what the
    /// setup row, the menu bar and the wiki window all ask, and the setup window asks it
    /// forty times a minute from its repaint timer.
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
    /// the memo would leave the window shut for two seconds after the grant.
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

    /// Clears settings only older builds understood.
    ///
    /// Called once at launch. `trolley update` can put an older bundle back on this same
    /// defaults domain, and that build reads `trolley.wiki.enabled` -- a `false` left
    /// there from before the switch was retired would silently turn its wiki off. The
    /// digest bookkeeping goes with them: nothing sends a digest any more, so a record of
    /// what was sent is a claim about a conversation this build cannot make.
    public static func forgetRetiredSettings() {
        for key in retiredKeys { defaults.removeObject(forKey: key) }
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

    // MARK: - Who "me" is

    public static let meKey = "trolley.wiki.me"

    /// The 담당 handle that means "me", for the 내 일감 preset.
    ///
    /// There is no way to derive this. The vault's 담당 values are GitHub handles and
    /// the Mac knows only `NSUserName()`, a short user name; the `minsuRob` in
    /// `Version.swift` is the release repo's owner, not whoever is running the build.
    /// Guessing either would be wrong for two of this vault's three people, so it is
    /// learned instead -- picking yourself in the 담당 popup and saving is what sets it.
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

}
