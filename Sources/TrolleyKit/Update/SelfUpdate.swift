import Foundation

/// A dotted version, compared numerically rather than lexically -- "0.10.0" is
/// newer than "0.2.0", which string comparison gets backwards.
public struct SemanticVersion: Equatable, Comparable, CustomStringConvertible {
    public let components: [Int]

    /// Accepts an optional leading "v" so a git tag can be fed in unmodified.
    public init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") {
            text.removeFirst()
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }

        var parsed: [Int] = []
        for part in parts {
            guard let value = Int(part), value >= 0 else { return nil }
            parsed.append(value)
        }
        components = parsed
    }

    public var description: String {
        components.map(String.init).joined(separator: ".")
    }

    /// Missing trailing components read as zero, so "1.2" == "1.2.0".
    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let width = max(lhs.components.count, rhs.components.count)
        for index in 0..<width {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}

/// What a release offers us: a version and the one asset we know how to install.
public struct ReleaseInfo: Equatable {
    public let version: SemanticVersion
    public let downloadURL: URL

    public init(version: SemanticVersion, downloadURL: URL) {
        self.version = version
        self.downloadURL = downloadURL
    }
}

public enum UpdateError: Error, LocalizedError, CustomStringConvertible {
    case feedUnreadable(String)
    case noRelease
    case assetMissing(String)
    case signatureRejected(String)
    case notWritable(String)
    case replaceFailed(String)

    public var errorDescription: String? { description }

    public var description: String {
        switch self {
        case .feedUnreadable(let detail):
            return "릴리스 정보를 읽지 못했습니다: \(detail)"
        case .noRelease:
            return "공개된 릴리스가 아직 없습니다."
        case .assetMissing(let name):
            return "릴리스에 \"\(name)\" 파일이 없습니다."
        case .signatureRejected(let detail):
            return "내려받은 파일의 서명을 신뢰할 수 없어 설치를 중단했습니다: \(detail)"
        case .notWritable(let path):
            return "\(path)에 쓸 수 없습니다. 설치파일로 다시 설치하면 권한이 정리됩니다."
        case .replaceFailed(let detail):
            return "교체에 실패했습니다: \(detail)"
        }
    }
}

/// Reads GitHub's "latest release" payload. Only the two fields we need, so an
/// unrelated schema change upstream cannot break the parse.
public enum GitHubRelease {
    public static func parse(_ data: Data, assetName: String) throws -> ReleaseInfo {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UpdateError.feedUnreadable("JSON이 아닙니다")
        }
        guard let tag = root["tag_name"] as? String, let version = SemanticVersion(tag) else {
            throw UpdateError.feedUnreadable("tag_name이 없거나 버전 형식이 아닙니다")
        }
        let assets = root["assets"] as? [[String: Any]] ?? []
        // Exact name match: a prefix match would happily grab "trolley-universal.sig".
        guard
            let asset = assets.first(where: { $0["name"] as? String == assetName }),
            let urlText = asset["browser_download_url"] as? String,
            let url = URL(string: urlText)
        else {
            throw UpdateError.assetMissing(assetName)
        }
        return ReleaseInfo(version: version, downloadURL: url)
    }
}

public enum UpdateDecision: Equatable {
    case upToDate
    case available(ReleaseInfo)

    /// A local build ahead of the newest release counts as up to date -- the
    /// updater installs updates, it does not roll developers backwards.
    public static func decide(current: SemanticVersion, latest: ReleaseInfo) -> UpdateDecision {
        current < latest.version ? .available(latest) : .upToDate
    }
}
