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
    ///
    /// - Parameter uptime: already formatted by `uptime(_:)`. This row used to sit in
    ///   the panel's header, ticking beside the title. It reads as a fact about this
    ///   run rather than something to watch, and next to 버전 it is one more line of
    ///   the same paste -- "떠 있은 지 얼마나 됐나" is exactly a bug-report question.
    static func details(
        version: String,
        uptime: String,
        path: String,
        model: String?,
        address: String
    ) -> [(label: String, value: String)] {
        [
            ("버전", version),
            ("가동 시간", uptime),
            ("프로그램 경로", path),
            ("모델", model ?? "확인 중…"),
            ("서버 주소", address)
        ]
    }

    /// How long this run has been up, as `분:초` -- or `시:분:초` once there are hours.
    ///
    /// Hours only once there are any: "00:14:02" reads as a stopwatch, and a session
    /// that old is the exception.
    static func uptime(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let (hours, minutes, seconds) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }

    static func diagnostics(_ rows: [(label: String, value: String)]) -> String {
        rows.map { "\($0.label): \($0.value)" }.joined(separator: "\n")
    }

    // MARK: - 리소스

    static let detailsResourceButton = "리소스 확인"
    static let resourceSheetTitle = "지금 이 모델의 여유"

    /// The same (label, value) shape as `details(...)`, so `diagnostics(_:)` renders
    /// it and the sheet stays one string.
    ///
    /// Scalars rather than a `LocalLLMClient.Status`, for the reason this whole file
    /// exists: half the value of this table is what it says when a number is
    /// *missing*, and that branch is only testable if a test can leave one out.
    ///
    /// Jargon rule: this sits inside "자세히" next to 정보 복사, on the `details(...)`
    /// side of the line -- 토큰 and GB are the right words here, and there is no
    /// plainer one that still means the thing.
    static func resources(
        busy: Bool,
        waiting: Int,
        maxQueueDepth: Int?,
        maxContext: Int?,
        hardContextLimit: Int?,
        wikiTokens: Int?,
        lastPeakGB: Double?,
        totalJobs: Int?,
        remoteActive: Int?,
        remoteLimit: Int?
    ) -> [(label: String, value: String)] {
        var rows: [(label: String, value: String)] = [
            ("지금", busy ? "답하는 중입니다" : "쉬고 있습니다")
        ]

        if let maxQueueDepth {
            let free = max(0, maxQueueDepth - waiting)
            rows.append((
                "대기 줄",
                "\(maxQueueDepth)자리 중 \(waiting)자리 사용 — \(free)자리 남음"
            ))
        } else {
            rows.append(("대기 줄", "\(waiting)명 기다리는 중"))
        }

        // No arithmetic without the ceiling: a headroom figure derived from a
        // guessed limit is not a headroom figure.
        if let maxContext {
            var line = "\(number(maxContext))토큰까지"
            if let wikiTokens {
                line += " · 위키가 약 \(number(wikiTokens))토큰"
                line += " · 약 \(number(max(0, maxContext - wikiTokens)))토큰 남음"
            } else {
                line += " · 위키는 함께 가지 않아 전부 남습니다"
            }
            rows.append(("한 번에 담는 글", line))
        } else {
            rows.append(("한 번에 담는 글", "확인 중…"))
        }

        if let hardContextLimit {
            rows.append(("안전 상한", "\(number(hardContextLimit))토큰"))
        }

        if let lastPeakGB {
            rows.append(("메모리", "마지막 답변이 최고 \(String(format: "%.1f", lastPeakGB))GB 썼습니다"))
        } else {
            rows.append(("메모리", "아직 답한 적이 없어 알 수 없습니다"))
        }

        if let totalJobs {
            rows.append(("처리한 질문", "\(number(totalJobs))건"))
        }

        if let remoteLimit {
            rows.append(("원격 모델", "\(remoteLimit)자리 중 \(remoteActive ?? 0)자리 사용"))
        }

        return rows
    }

    /// Says why there are no numbers instead of showing zeros. The address is the
    /// thing to check, and the row above the button already offers the button that
    /// changes it.
    static func resourcesUnavailable(_ reason: String) -> String {
        "서버에서 지금 상태를 읽지 못했습니다.\n\(reason)"
    }

    /// Thousands separators by hand rather than a `NumberFormatter`: this table
    /// puts 96000 two lines above 120000, which is the exact pair that is easy to
    /// misread, and a formatter would drag a locale into a string that is Korean
    /// either way.
    private static func number(_ value: Int) -> String {
        let digits = Array(String(abs(value)))
        var out = ""
        for (index, digit) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { out.append(",") }
            out.append(digit)
        }
        return (value < 0 ? "-" : "") + out
    }
}
