import ArgumentParser
import Foundation
import TrolleyKit

/// Replaces this binary with the newest signed release.
///
/// Works without a password because the installer hands `/usr/local/trolley` to
/// the installing user: the swap needs write access to the *directory*, not to
/// the file.
struct UpdateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update trolley in place from the latest signed release."
    )

    @Flag(help: "Only report whether an update exists; change nothing.")
    var check: Bool = false

    func run() throws {
        guard let current = SemanticVersion(TrolleyVersion.current) else {
            throw ValidationError("현재 버전을 해석할 수 없습니다: \(TrolleyVersion.current)")
        }
        let path = AccessibilityPermission.currentExecutablePath()
        print("설치 위치: \(path)")
        print("현재 버전: \(current)")

        let installer = LiveUpdateIO.live

        if check {
            switch try installer.check(
                feed: TrolleyVersion.releaseFeed,
                assetName: TrolleyVersion.updateAssetName,
                current: current
            ) {
            case .upToDate:
                print("최신입니다.")
            case .available(let release):
                print("새 버전 있음: \(release.version)")
                print("설치하려면: trolley update")
            }
            return
        }

        let installed = try installer.install(
            feed: TrolleyVersion.releaseFeed,
            assetName: TrolleyVersion.updateAssetName,
            current: current,
            installedAt: URL(fileURLWithPath: path)
        )

        guard let installed else {
            print("최신입니다.")
            return
        }
        print("업데이트 완료: \(current) → \(installed)")
        // The swap gave the path a new inode; anything already running keeps the
        // old one until it is restarted.
        print("실행 중인 trolley mcp는 재시작해야 새 버전으로 바뀝니다.")
    }
}
