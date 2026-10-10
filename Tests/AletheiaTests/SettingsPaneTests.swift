import XCTest
@testable import Aletheia

/// The Settings sidebar's order and its up/down stepping.
final class SettingsPaneTests: XCTestCase {
    func testSidebarOrder() {
        XCTAssertEqual(
            SettingsPane.allCases.map(\.title),
            ["General", "AI and models", "Note format", "Encryption", "Backups", "Security"]
        )
    }

    func testMovedStepsAndClampsAtEnds() {
        XCTAssertEqual(SettingsPane.general.moved(by: 1), .ai)
        XCTAssertEqual(SettingsPane.ai.moved(by: -1), .general)
        XCTAssertEqual(SettingsPane.general.moved(by: -1), .general)
        XCTAssertEqual(SettingsPane.security.moved(by: 1), .security)
    }

    func testRawValueRoundTripsForPersistence() {
        for pane in SettingsPane.allCases {
            XCTAssertEqual(SettingsPane(rawValue: pane.rawValue), pane)
        }
        XCTAssertNil(SettingsPane(rawValue: "nonsense"))
    }
}
