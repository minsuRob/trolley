import XCTest
@testable import trolley

final class MenuBarMenuTests: XCTestCase {
    /// Three things and nothing else. The menu is the first thing a new user
    /// reads, so every extra row costs more than it gives.
    func testTheMenuIsAskSettingsQuitInThatOrder() {
        XCTAssertEqual(MenuBarMenu.titles, ["물어보기", "설정", "종료"])
    }

    /// "종료" sits behind a separator because it is the only one that cannot be
    /// undone, and mis-clicking it kills the pet with no obvious way back.
    func testQuitIsSeparatedFromTheRest() {
        guard case .separator = MenuBarMenu.specs[2] else {
            return XCTFail("종료 앞에 구분선이 없습니다: \(MenuBarMenu.specs)")
        }
        XCTAssertEqual(MenuBarMenu.specs.count, 4)
    }

    /// Every item needs a real selector; a nil action is an item that greys out.
    func testEveryItemCarriesAnAction() {
        for spec in MenuBarMenu.specs {
            if case .item(let title, let action) = spec {
                XCTAssertFalse(
                    NSStringFromSelector(action).isEmpty, "\(title) 에 동작이 없습니다"
                )
            }
        }
    }
}
