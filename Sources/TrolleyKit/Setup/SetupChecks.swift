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
    /// Install locations in the order we prefer them: the per-user install the
    /// Claude Code installer writes, then the two Homebrew prefixes.
    public static let searchPaths = [
        "~/.claude/local/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
        "/usr/bin/claude"
    ]

    public static func locate(
        exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        home: String = NSHomeDirectory()
    ) -> String? {
        for candidate in searchPaths {
            let path = candidate.hasPrefix("~/")
                ? home + String(candidate.dropFirst(1))
                : candidate
            if exists(path) { return path }
        }
        return nil
    }
}

/// The MCP side of setup: what to run, and how to tell it already happened.
public enum MCPRegistration {
    public static let serverName = "trolley"

    public static func addArguments(executablePath: String) -> [String] {
        ["mcp", "add", serverName, "--", executablePath, "mcp"]
    }

    public static func removeArguments() -> [String] {
        ["mcp", "remove", serverName]
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
    /// it themselves.
    public static func manualCommand(executablePath: String) -> String {
        "claude " + addArguments(executablePath: executablePath)
            .map { $0.contains(" ") ? "\"\($0)\"" : $0 }
            .joined(separator: " ")
    }
}
