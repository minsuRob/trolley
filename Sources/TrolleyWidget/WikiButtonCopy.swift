import Foundation

/// What the panel's 위키 버튼 says.
///
/// Split out of `ActivityPanelController` so the wording can be asserted without a window
/// server -- the same reason `MenuBarMenu` holds the menu's shape as data. Building the
/// panel means building an `NSPanel`, and a test that needs one of those is a test that
/// does not run.
enum WikiButtonCopy {
    /// - Parameter myCount: nil when nobody has said which 담당 handle is theirs, so
    ///   there is no number to give. That is not the same as 0, which is a real answer --
    ///   you are known and nothing is open on you -- and it keeps its parentheses so the
    ///   number does not appear and vanish as the last task closes.
    static func title(myCount: Int?) -> String {
        guard let myCount else { return "위키 열기" }
        return "위키 열기(\(myCount)개)"
    }

    static func tooltip(myCount: Int?) -> String {
        guard let myCount else { return "위키 창을 엽니다" }
        return "내 일감 \(myCount)건 — 담당=나 · 진행중·대기"
    }
}
