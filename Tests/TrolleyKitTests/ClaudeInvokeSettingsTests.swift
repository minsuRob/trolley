import XCTest
@testable import TrolleyKit

final class ClaudeInvokeSettingsTests: XCTestCase {
    private static let keys = [
        ClaudeInvokeSettings.terminalEnabledKey, ClaudeInvokeSettings.orcaEnabledKey,
        ClaudeInvokeSettings.desktopEnabledKey, ClaudeInvokeSettings.attachWikiContextKey,
        ClaudeInvokeSettings.orcaConfirmKey, ClaudeInvokeSettings.orcaTargetHandleKey,
        ClaudeInvokeSettings.desktopAutoSubmitKey
    ]

    /// Same discipline as `WikiSeparationTests.withRoot`: save whatever the real domain
    /// held for these keys, clear it, run the test, put it back -- so a run on this
    /// machine's own `UserDefaults.standard` never leaks into the next test or the app.
    private func withCleanDefaults(_ body: () -> Void) {
        let defaults = UserDefaults.standard
        let saved = Self.keys.map { ($0, defaults.object(forKey: $0)) }
        Self.keys.forEach { defaults.removeObject(forKey: $0) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        body()
    }

    func testMethodsDefaultOff() {
        withCleanDefaults {
            XCTAssertFalse(ClaudeInvokeSettings.terminalEnabled)
            XCTAssertFalse(ClaudeInvokeSettings.orcaEnabled)
            XCTAssertFalse(ClaudeInvokeSettings.desktopEnabled)
        }
    }

    func testSafetyDefaultsAreOnAndAutoSubmitIsOff() {
        withCleanDefaults {
            XCTAssertTrue(ClaudeInvokeSettings.attachWikiContext)
            XCTAssertTrue(ClaudeInvokeSettings.orcaConfirmBeforeSend)
            XCTAssertFalse(ClaudeInvokeSettings.desktopAutoSubmit)
        }
    }

    func testTargetHandleRoundTripsAndBlankMeansAutomatic() {
        withCleanDefaults {
            ClaudeInvokeSettings.orcaTargetHandle = "  term_abc  "
            XCTAssertEqual(ClaudeInvokeSettings.orcaTargetHandle, "term_abc")
            ClaudeInvokeSettings.orcaTargetHandle = "   "
            XCTAssertEqual(ClaudeInvokeSettings.orcaTargetHandle, "")
        }
    }

    func testTogglesPersist() {
        withCleanDefaults {
            ClaudeInvokeSettings.orcaEnabled = true
            ClaudeInvokeSettings.orcaConfirmBeforeSend = false
            XCTAssertTrue(ClaudeInvokeSettings.orcaEnabled)
            XCTAssertFalse(ClaudeInvokeSettings.orcaConfirmBeforeSend)
        }
    }
}
