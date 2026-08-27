import ArgumentParser
import Foundation
import TrolleyKit

/// `staging` 번들의 서명을 검증하고 `target` 자리에 원자적으로 바꿔친다.
///
/// `trolley update`가 다운로드한 번들에 쓰는 것과 같은 `LiveUpdateIO` 스왑 경로다 --
/// 다운로드 대신 dev-run.sh 가 방금 로컬에서 서명한 번들을 그대로 준다는 점만 다르다.
/// bash 만으로는 이 스왑의 원자성(`renamex_np(RENAME_SWAP)`)을 재현할 수 없어서
/// 셸이 아니라 여기서 한다.
///
/// `staging`을 인자로 받는 이유: `InstallLayout.detect`는 "지금 실행 중인 설치가
/// 어디 있는가"를 `.app` 확장자로 판별하는 용도라, 숨김 스테이징 이름(`.foo.app.update`)
/// 에 쓰면 `pathExtension`이 "update"가 되어 번들로 인식되지 않는다 -- 실측. 호출자
/// (dev-run.sh)는 이미 두 경로를 알고 있으니 그냥 넘겨받는다.
struct InstallLocalCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install-local",
        abstract: "Verify a locally built bundle's signature and swap it into target.",
        shouldDisplay: false
    )

    @Argument var staging: String
    @Argument var target: String

    func run() throws {
        guard let version = SemanticVersion(TrolleyVersion.current) else {
            throw ValidationError("현재 버전을 해석할 수 없습니다: \(TrolleyVersion.current)")
        }
        let stagingURL = URL(fileURLWithPath: staging)
        try LiveUpdateIO.verifySignature(stagingURL)
        let staged = UpdateInstaller.StagedUpdate(
            version: version, staging: stagingURL, target: URL(fileURLWithPath: target)
        )
        try LiveUpdateIO.live.commit(staged)
        print(target)
    }
}
