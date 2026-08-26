import ArgumentParser
import Foundation
import TrolleyKit

/// Replaces this binary with the newest signed release.
///
/// Works without a password: dragged to /Applications, the bundle sits in a
/// directory the admin group can write, and the swap needs write access to the
/// *directory* rather than to what it replaces.
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
        let layout = InstallLayout.detect(executablePath: path)
        print("설치 위치: \(layout.target.path)")
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
            layout: layout
        )

        guard let installed else {
            print("최신입니다.")
            return
        }
        print("업데이트 완료: \(current) → \(installed)")
        // The swap gave the path a new inode; anything already running keeps the
        // old one until it is restarted.
        print("실행 중인 trolley 앱은 다시 열어야 새 버전으로 바뀝니다.")
    }
}
