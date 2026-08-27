import XCTest
@testable import trolley

final class MenuBarMenuTests: XCTestCase {
    /// The menu is the first thing a new user reads, so every extra row costs more than
    /// it gives -- which is why "위키" is only there when there is a vault to open.
    func testTheMenuIsAskSettingsQuitWithoutAWiki() {
        XCTAssertEqual(MenuBarMenu.titles(wikiIsAvailable: false), ["물어보기", "설정", "종료"])
    }

    /// Second, not last. 물어보기 and 위키 are the two things trolley does; 설정 is where
    /// you go when one of them is not working.
    func testTheWikiSitsRightAfterAsk() {
        XCTAssertEqual(MenuBarMenu.titles(wikiIsAvailable: true), ["물어보기", "위키", "설정", "종료"])
    }

    /// "종료" sits behind a separator because it is the only one that cannot be
    /// undone, and mis-clicking it kills the pet with no obvious way back.
    func testQuitIsSeparatedFromTheRest() {
        for available in [true, false] {
            let specs = MenuBarMenu.specs(wikiIsAvailable: available)
            guard case .separator = specs[specs.count - 2] else {
                return XCTFail("종료 앞에 구분선이 없습니다: \(specs)")
            }
        }
    }

    /// Every item needs a real selector; a nil action is an item that greys out.
    func testEveryItemCarriesAnAction() {
        for spec in MenuBarMenu.specs(wikiIsAvailable: true) {
            if case .item(let title, let action) = spec {
                XCTAssertFalse(
                    NSStringFromSelector(action).isEmpty, "\(title) 에 동작이 없습니다"
                )
            }
        }
    }
}
