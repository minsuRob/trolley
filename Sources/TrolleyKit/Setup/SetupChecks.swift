import Foundation

/// Where the running bundle lives.
///
/// Worth checking before anything else: run straight from the mounted disk
/// image, trolley reports a `/Volumes/...` path, and every grant and MCP
/// registration made against it dies the moment the image is ejected.
public enum InstallLocation: Equatable {
    case applications
    case diskImage
    case elsewhere

    public static func detect(bundlePath: String, home: String = NSHomeDirectory()) -> InstallLocation {
        if bundlePath.hasPrefix("/Applications/") || bundlePath.hasPrefix("\(home)/Applications/") {
            return .applications
        }
        if bundlePath.hasPrefix("/Volumes/") {
            return .diskImage
        }
        return .elsewhere
    }
}

/// Finds the `claude` executable so registration can happen in-app instead of
/// asking someone to paste a command.
public enum ClaudeCLI {
    /// Install locations in the order we prefer them. `~/.local/bin` comes first
    /// because that is where the current installer puts it -- leaving it out is
    /// what made the setup window report "claude 명령을 찾지 못했습니다" on a
    /// machine where `claude` worked perfectly in the terminal.
    public static let searchPaths = [
        "~/.local/bin/claude",
        "~/.claude/local/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
        "~/.bun/bin/claude",
        "~/.npm-global/bin/claude",
        "/usr/bin/claude"
    ]

    /// - Parameter shellLookup: asks the user's login shell where `claude` is.
    ///   A list of paths can only ever be a guess -- npm prefixes, version
    ///   managers and custom prefixes all move it -- so the shell, which owns the
    ///   real PATH, gets the last word.
    public static func locate(
        exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        home: String = NSHomeDirectory(),
        shellLookup: () -> String? = { nil }
    ) -> String? {
        for candidate in searchPaths {
            let path = candidate.hasPrefix("~/")
                ? home + String(candidate.dropFirst(1))
                : candidate
            if exists(path) { return path }
        }
        // Only absolute paths: `command -v` answers with "claude: aliased to ..."
        // when it is a shell alias, which is not something we can exec.
        if let found = shellLookup()?.trimmingCharacters(in: .whitespacesAndNewlines),
           found.hasPrefix("/"), exists(found) {
            return found
        }
        return nil
    }
}

/// The MCP side of setup: what to run, and how to tell it already happened.
public enum MCPRegistration {
    public static let serverName = "trolley"

    /// `--scope user` rather than the default. The default is `local`, which ties
    /// the entry to whatever directory the command ran in -- for a GUI app that
    /// is wherever launchd happened to leave it, so the registration would exist
    /// but never be found again.
    public static func addArguments(executablePath: String) -> [String] {
        ["mcp", "add", "--scope", "user", serverName, "--", executablePath, "mcp"]
    }

    public static func removeArguments() -> [String] {
        ["mcp", "remove", "--scope", "user", serverName]
    }

    /// `claude mcp list` prints one `name: command` line per server. Matching the
    /// name with its colon rather than searching for the word keeps a server
    /// called "trolley-dev", or a path that merely contains "trolley", from
    /// reading as us.
    public static func isRegistered(listOutput: String) -> Bool {
        listOutput
            .split(separator: "\n")
            .contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("\(serverName):") }
    }

    /// The command to show when the CLI cannot be found and someone has to run
    /// it themselves. Carries the same `--scope user`, so a hand-run command and
    /// the button end up in the same place.
    public static func manualCommand(executablePath: String) -> String {
        "claude " + addArguments(executablePath: executablePath)
            .map { $0.contains(" ") ? "\"\($0)\"" : $0 }
            .joined(separator: " ")
    }
}
