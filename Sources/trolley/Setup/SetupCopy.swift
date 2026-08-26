import Foundation
import TrolleyKit

/// Every word the setup window says, as pure functions.
///
/// Pulled out of the controller for one reason above all: the point of this
/// change is that none of these lines may leak developer vocabulary, and that is
/// a property a test can enforce (`SetupCopyTests`) only if the strings exist
/// somewhere a test can reach without a window server.
///
/// The split is deliberate. `RowContent` is what a first-time user reads and is
/// held to plain Korean; `details(...)` is the "자세히" table, where paths, model
/// ids and MCP scopes are exactly what is wanted.
enum SetupCopy {
    struct RowContent: Equatable {
        let state: SetupRow.State
        let detail: String
        let button: String?
    }

    // MARK: - Required three

    static let checklistHeading = "아래 세 가지가 준비되면 trolley를 쓸 수 있습니다."

    static let locationTitle = "프로그램 위치"

    static func location(_ location: InstallLocation) -> RowContent {
        switch location {
        case .applications:
            return RowContent(state: .done, detail: "응용 프로그램 폴더에 있습니다.", button: nil)
        case .diskImage:
            return RowContent(
                state: .blocked,
                detail: "지금은 설치 이미지 안에서 실행 중입니다. 응용 프로그램 폴더로 옮긴 뒤 다시 열어 주세요.",
                button: "옮기기"
            )
        case .elsewhere:
            return RowContent(
                state: .actionNeeded,
                detail: "다른 곳에 두면 허용해 둔 권한이 자꾸 풀립니다. 응용 프로그램 폴더로 옮겨 주세요.",
                button: "옮기기"
            )
        }
    }

    /// Named for what it lets trolley do, not for the switch it corresponds to.
    /// The macOS name follows in brackets only because the button sends you to a
    /// settings pane that uses it -- without it you would be hunting.
    static let accessibilityTitle = "다른 앱을 대신 다루기"

    static func accessibility(granted: Bool) -> RowContent {
        granted
            ? RowContent(state: .done, detail: "허용됨 — 버튼을 누르고 글자를 입력할 수 있습니다.", button: nil)
            : RowContent(
                state: .actionNeeded,
                detail: "trolley가 대신 버튼을 누르고 글자를 입력하려면 허락이 필요합니다. "
                    + "'허용하기'를 누르면 설정 창이 열립니다. (거기서는 '손쉬운 사용'이라고 부릅니다)",
                button: "허용하기"
            )
    }

    static let screenRecordingTitle = "화면을 보고 확인하기"

    /// No longer called optional. `isEverythingReady()` requires it, so the old
    /// "없어도 나머지는 동작합니다" left anyone who believed it permanently short of
    /// "준비 완료" -- and now, short of the one-time introduction too.
    static func screenRecording(granted: Bool) -> RowContent {
        granted
            ? RowContent(state: .done, detail: "허용됨 — 화면을 보고 결과를 확인합니다.", button: nil)
            : RowContent(
                state: .actionNeeded,
                detail: "trolley가 지금 화면이 어떤 모습인지 보려면 허락이 필요합니다. "
                    + "'허용하기'를 누르면 설정 창이 열립니다. (거기서는 '화면 기록'이라고 부릅니다)",
                button: "허용하기"
            )
    }

    // MARK: - Ready

    static let readyTitle = "준비 완료 — 이렇게 쓰세요"

    static let readySteps = [
        "1. 화면 위쪽 메뉴 막대의 trolley 아이콘을 누르고 '물어보기'를 고르세요.",
        "2. 화면에 떠 있는 폴더를 눌러도 같은 창이 열립니다.",
        "3. 하고 싶은 말을 적고 엔터를 누르면 됩니다."
    ]

    static let readyExample = "예) 이 문장을 좀 더 정중하게 고쳐 줘"
    static let readyButton = "지금 물어보기"
    static let readyFooter = "이 창은 닫아도 됩니다. trolley는 계속 켜져 있습니다."

    // MARK: - Optional

    static let llmTitle = "Local LLM 연결 주소"

    /// The model id, the address and the queue depth all move to `details(...)`.
    /// What belongs here is only whether asking will work right now.
    static func llm(reachable: Bool?) -> RowContent {
        switch reachable {
        case .some(true):
            return RowContent(state: .done, detail: "연결됨 — 물어보면 이 서버가 답합니다.", button: "주소 변경")
        case .some(false):
            return RowContent(
                state: .optional,
                detail: "지금은 연결되지 않습니다. 서버가 켜져 있는지 확인해 주세요.",
                button: "주소 변경"
            )
        case .none:
            return RowContent(state: .optional, detail: "확인 중…", button: "주소 변경")
        }
    }

    static let llmSheetTitle = "Local LLM 연결 주소"
    static let llmSheetBody = "평소에는 바꿀 일이 없습니다. 비워두면 기본값으로 돌아갑니다."

    // MARK: - 자세히

    static let detailsToggle = "자세히"
    static let detailsCopyButton = "정보 복사"

    /// The technical table. Jargon is correct here -- this is what you paste into a
    /// bug report.
    static func details(
        version: String,
        path: String,
        model: String?,
        address: String
    ) -> [(label: String, value: String)] {
        [
            ("버전", version),
            ("프로그램 경로", path),
            ("모델", model ?? "확인 중…"),
            ("서버 주소", address)
        ]
    }

    static func diagnostics(_ rows: [(label: String, value: String)]) -> String {
        rows.map { "\($0.label): \($0.value)" }.joined(separator: "\n")
    }
}
