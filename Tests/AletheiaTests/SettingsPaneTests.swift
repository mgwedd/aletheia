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

    // MARK: - Note format switches

    func testNoteFormatSettingsDefaultToTrue() {
        let settings = AppSettings.shared
        XCTAssertTrue(settings.includeCommentsInDrafts)
        XCTAssertTrue(settings.includePatientBackground)
    }

    func testNoteFormatSettingsPersistInUserDefaults() {
        let settings = AppSettings.shared
        let originalComments = settings.includeCommentsInDrafts
        let originalBackground = settings.includePatientBackground

        defer {
            settings.includeCommentsInDrafts = originalComments
            settings.includePatientBackground = originalBackground
        }

        settings.includeCommentsInDrafts = false
        XCTAssertFalse(settings.includeCommentsInDrafts)
        XCTAssertEqual(UserDefaults.standard.bool(forKey: "includeCommentsInDrafts"), false)

        settings.includeCommentsInDrafts = true
        XCTAssertTrue(settings.includeCommentsInDrafts)
        XCTAssertEqual(UserDefaults.standard.bool(forKey: "includeCommentsInDrafts"), true)

        settings.includePatientBackground = false
        XCTAssertFalse(settings.includePatientBackground)
        XCTAssertEqual(UserDefaults.standard.bool(forKey: "includePatientBackground"), false)

        settings.includePatientBackground = true
        XCTAssertTrue(settings.includePatientBackground)
        XCTAssertEqual(UserDefaults.standard.bool(forKey: "includePatientBackground"), true)
    }
}
