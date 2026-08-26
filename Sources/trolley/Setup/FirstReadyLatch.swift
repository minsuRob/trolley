import Foundation

/// Fires once, on the first time everything is ready.
///
/// Split out as a value type because the interesting part is a sequence of
/// observations over time, and that is miserable to test through a window and a
/// timer. The persistence lives at the call site.
struct FirstReadyLatch: Equatable {
    private(set) var hasFired: Bool

    init(hasFired: Bool) {
        self.hasFired = hasFired
    }

    /// - Returns: true exactly once, on the first `isReady: true` it is shown.
    ///   Never again -- including after readiness is lost and regained, which
    ///   happens whenever someone toggles a permission off and on again.
    mutating func observe(isReady: Bool) -> Bool {
        guard !hasFired, isReady else { return false }
        hasFired = true
        return true
    }
}

/// Where the latch's memory lives. A separate key from anything else in
/// `UserDefaults`, so clearing it re-arms the introduction for testing.
enum FirstReadyStore {
    static let defaultsKey = "trolley.didIntroducePrompt"

    static var hasIntroduced: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }
}
