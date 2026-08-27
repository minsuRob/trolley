import Foundation

/// Finds a `markhub-llm-wiki` checkout on disk, so a wrong or stale `WikiSettings.rootPath`
/// does not have to be fixed by hand through `폴더 선택…`.
///
/// Spotlight rather than a hand-rolled walk: `mdfind` already has the home directory
/// indexed, so this costs one process launch instead of a recursive `FileManager` walk
/// that would have to guess how deep to go and what to skip. The vault lives under
/// `~/Desktop` (`CLAUDE.md`), so the search never leaves the home directory.
public enum WikiRootFinder {
    public static let folderName = "markhub-llm-wiki"

    /// - Parameter search: candidate paths, in the order to try them. Injectable so a
    ///   test never spawns `mdfind`.
    /// - Parameter isWikiRoot: same reason -- a candidate is only trusted once it looks
    ///   like the vault, not merely because it has the right name. See
    ///   `WikiSettings.isWikiRoot`, which this defaults to.
    public static func find(
        search: () -> [String] = defaultSearch,
        isWikiRoot: (URL) -> Bool = WikiSettings.isWikiRoot
    ) -> URL? {
        for candidate in search() where !candidate.isEmpty {
            let url = URL(fileURLWithPath: candidate)
            if isWikiRoot(url) { return url }
        }
        return nil
    }

    /// Blocking, like `ClaudeCLI.locate`'s shell lookup -- callers already run this off
    /// the main thread. `public`, not `private`: a default argument value on a public
    /// function must be at least as visible as the function itself.
    public static func defaultSearch() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = [
            "-onlyin", NSHomeDirectory(),
            "kMDItemFSName == '\(folderName)'c && kMDItemContentType == 'public.folder'"
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return []
        }
        // A stuck Spotlight index must not hang whatever's waiting on this -- the setup
        // window's refresh timer, or a button press.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
            if process.isRunning { process.terminate() }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
    }
}
