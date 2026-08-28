import Foundation

/// A thin shell-out to the `orca` CLI -- the same one `tools/copy-chat.py`
/// drives, with the same three subcommands and the same JSON envelope
/// (`{id, ok, result}`). No shell is involved: arguments go straight to
/// `execve` through `Process.arguments`, so a prompt containing quotes,
/// newlines, or Korean needs no escaping at all.
public enum OrcaCLI {
    public static let searchPaths = [
        "/opt/homebrew/bin/orca", "/usr/local/bin/orca", "~/.local/bin/orca"
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

    public struct Terminal: Decodable {
        public let handle: String
        public let title: String
    }

    struct ListEnvelope: Decodable {
        struct Result: Decodable { let terminals: [Terminal] }
        let ok: Bool
        let result: Result?
    }

    struct ReadEnvelope: Decodable {
        struct Terminal: Decodable { let tail: [String] }
        struct Result: Decodable { let terminal: Terminal }
        let ok: Bool
        let result: Result?
    }

    public static func parseTerminals(_ json: String) -> [Terminal]? {
        guard let data = json.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(ListEnvelope.self, from: data),
              envelope.ok
        else { return nil }
        return envelope.result?.terminals
    }

    public static func parseTail(_ json: String) -> [String]? {
        guard let data = json.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(ReadEnvelope.self, from: data),
              envelope.ok
        else { return nil }
        return envelope.result?.terminal.tail
    }

    /// Runs `orca <arguments>` and returns its exit code and combined
    /// stdout+stderr. A blocking call by design -- every caller here is
    /// already off the main thread (see `ClaudeInvokeDispatcher`).
    public static func run(_ executable: String, _ arguments: [String]) -> (exitCode: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, "orca 실행 실패 — \(error)")
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
