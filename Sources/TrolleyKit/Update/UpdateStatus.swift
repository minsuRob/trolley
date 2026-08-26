import Foundation

/// What the app knows about updates right now.
///
/// This is the whole surface `TrolleyKit` offers the UI. Views are the app's
/// business, and a status that can be rendered without asking a further
/// question is what keeps them separable -- the widget reads `summary` and
/// `actionTitle` and never has to know a `SemanticVersion` from a URL.
public enum UpdateStatus: Equatable {
    case upToDate
    case checking
    case available(SemanticVersion)
    case downloading(SemanticVersion)
    /// Fetched and verified, sitting beside the installation. One click away.
    case downloaded(SemanticVersion)
    case failed(String)

    /// One line, for the panel. Korean because it is read by a person.
    public var summary: String {
        switch self {
        case .upToDate: return "최신 버전입니다"
        case .checking: return "업데이트 확인 중…"
        case .available(let version): return "새 버전 \(version) 이 있습니다"
        case .downloading(let version): return "\(version) 내려받는 중…"
        case .downloaded(let version): return "\(version) 준비됨 — 누르면 설치합니다"
        case .failed(let reason): return reason
        }
    }

    /// The button's words, or nil when there is nothing to press. Only the
    /// downloaded case offers an action: until the bytes are here and verified,
    /// pressing anything would just mean "wait".
    public var actionTitle: String? {
        switch self {
        case .downloaded: return "설치하고 다시 시작"
        default: return nil
        }
    }

    /// Whether the widget should put itself in front of the user over this.
    /// Only a finished download does -- everything else is either transient or
    /// already visible in the panel.
    public var deservesAttention: Bool {
        if case .downloaded = self { return true }
        return false
    }
}

/// The four independent choices hiding inside "automatic update".
///
/// One named value rather than four scattered booleans so that moving to fully
/// unattended updating later is an edit to this literal, not surgery across the
/// coordinator. They are genuinely independent: downloading automatically while
/// installing on a click is the shipping default, and it is not expressible if
/// the two are folded together.
public struct UpdatePolicy: Equatable {
    public var checksAutomatically: Bool
    public var downloadsAutomatically: Bool
    public var installsAutomatically: Bool
    /// Whether installing also relaunches. `replace` gives the path a new inode,
    /// so a process that keeps running keeps the old one -- see `TrolleyRelaunch`.
    public var relaunchesAutomatically: Bool
    public var interval: TimeInterval

    public init(
        checksAutomatically: Bool,
        downloadsAutomatically: Bool,
        installsAutomatically: Bool,
        relaunchesAutomatically: Bool,
        interval: TimeInterval
    ) {
        self.checksAutomatically = checksAutomatically
        self.downloadsAutomatically = downloadsAutomatically
        self.installsAutomatically = installsAutomatically
        self.relaunchesAutomatically = relaunchesAutomatically
        self.interval = interval
    }

    /// Check and fetch without asking; install only when a person presses the
    /// button. Replacing a running app interrupts whatever it was doing, and
    /// the model session it is holding is not ours to throw away.
    ///
    /// Six hours rather than something shorter because the feed is a static
    /// file and a release lands a few times a week at most; a tighter loop
    /// would spend the user's network to learn the same thing.
    public static let `default` = UpdatePolicy(
        checksAutomatically: true,
        downloadsAutomatically: true,
        installsAutomatically: false,
        relaunchesAutomatically: true,
        interval: 6 * 60 * 60
    )
}
