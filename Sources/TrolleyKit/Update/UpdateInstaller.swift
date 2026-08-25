import Foundation

/// Fetches, verifies and swaps in a new trolley binary.
///
/// Every side effect is injected, matching the seams used elsewhere in this
/// package (`TrolleyTools`, `AppLauncher(sleeper:)`, `ToolCallObserver`): the
/// ordering rules below are then testable without touching the network or the
/// installed binary.
public struct UpdateInstaller {
    public var fetch: (URL) throws -> Data
    public var download: (URL, URL) throws -> Void
    public var verifySignature: (URL) throws -> Void
    public var replace: (URL, URL) throws -> Void
    public var removeTemporary: (URL) -> Void

    public init(
        fetch: @escaping (URL) throws -> Data,
        download: @escaping (URL, URL) throws -> Void,
        verifySignature: @escaping (URL) throws -> Void,
        replace: @escaping (URL, URL) throws -> Void,
        removeTemporary: @escaping (URL) -> Void
    ) {
        self.fetch = fetch
        self.download = download
        self.verifySignature = verifySignature
        self.replace = replace
        self.removeTemporary = removeTemporary
    }

    public func check(feed: URL, assetName: String, current: SemanticVersion) throws -> UpdateDecision {
        let data = try fetch(feed)
        let latest = try GitHubRelease.parse(data, assetName: assetName)
        return UpdateDecision.decide(current: current, latest: latest)
    }

    /// Downloads beside the installed binary, verifies, then swaps.
    ///
    /// The staging file is a sibling because the swap is `rename(2)`, which needs
    /// both paths on one filesystem. A verification failure deletes the download
    /// and leaves the installed binary untouched.
    ///
    /// - Returns: the version now installed, or nil when already current.
    @discardableResult
    public func install(
        feed: URL,
        assetName: String,
        current: SemanticVersion,
        installedAt destination: URL
    ) throws -> SemanticVersion? {
        guard case .available(let release) = try check(feed: feed, assetName: assetName, current: current) else {
            return nil
        }

        let directory = destination.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: directory.path) else {
            throw UpdateError.notWritable(directory.path)
        }
        let staging = directory.appendingPathComponent(".\(destination.lastPathComponent).update")

        removeTemporary(staging)
        do {
            try download(release.downloadURL, staging)
            try verifySignature(staging)
            try replace(staging, destination)
        } catch {
            removeTemporary(staging)
            throw error
        }
        return release.version
    }
}

// MARK: - Live implementations

public enum LiveUpdateIO {
    /// Synchronous on purpose: `ParsableCommand.run()` has no async entry point.
    public static func fetch(_ url: URL) throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(TrolleyVersion.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        return try send(request)
    }

    public static func download(_ url: URL, to destination: URL) throws {
        var request = URLRequest(url: url)
        request.setValue(TrolleyVersion.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let data = try send(request)
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: destination.path
        )
    }

    /// Pins the download to our Developer ID team. Anything else -- ad-hoc,
    /// unsigned, or another team's signature -- is refused.
    public static func verifySignature(_ url: URL) throws {
        let requirement = "anchor apple generic and certificate leaf[subject.OU] = \"\(TrolleyVersion.teamIdentifier)\""
        let result = run("/usr/bin/codesign", ["--verify", "--strict", "-R=\(requirement)", url.path])
        guard result.status == 0 else {
            throw UpdateError.signatureRejected(result.output.isEmpty ? "codesign \(result.status)" : result.output)
        }
    }

    /// `rename(2)`: atomic, and it hands the path a *new* inode. Writing over the
    /// existing file instead leaves the kernel holding a code signature that no
    /// longer matches the bytes, and the next run dies with `Killed: 9`.
    public static func replace(_ staging: URL, with destination: URL) throws {
        guard rename(staging.path, destination.path) == 0 else {
            throw UpdateError.replaceFailed(String(cString: strerror(errno)))
        }
    }

    public static func removeTemporary(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    public static var live: UpdateInstaller {
        UpdateInstaller(
            fetch: fetch,
            download: download,
            verifySignature: verifySignature,
            replace: { staging, destination in try replace(staging, with: destination) },
            removeTemporary: removeTemporary
        )
    }

    // MARK: - Helpers

    private static func send(_ request: URLRequest) throws -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        var payload: Data?
        var failure: Error?
        var status: Int?

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            payload = data
            failure = error
            status = (response as? HTTPURLResponse)?.statusCode
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()

        if let failure {
            throw UpdateError.feedUnreadable(failure.localizedDescription)
        }
        if let status, status == 404 {
            throw UpdateError.noRelease
        }
        if let status, !(200..<300).contains(status) {
            throw UpdateError.feedUnreadable("HTTP \(status)")
        }
        guard let payload else {
            throw UpdateError.feedUnreadable("응답이 비어 있습니다")
        }
        return payload
    }

    private static func run(_ launchPath: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, text)
    }
}
