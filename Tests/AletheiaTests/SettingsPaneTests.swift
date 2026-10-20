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

/// The Settings window must be at least as wide as its sidebar plus the
/// narrowest pane, and nothing that presents it may squeeze it below that:
/// a smaller outer `.frame(minWidth:)` clipped the sidebar and every row.
final class SettingsLayoutTests: XCTestCase {
    func testMinimumWidthFitsSidebarAndPane() {
        XCTAssertEqual(SettingsLayout.minWidth, SettingsLayout.sidebarWidth + SettingsLayout.paneMinWidth)
        XCTAssertGreaterThanOrEqual(SettingsLayout.idealWidth, SettingsLayout.minWidth)
        XCTAssertGreaterThanOrEqual(SettingsLayout.idealHeight, SettingsLayout.minHeight)
    }

    func testNoPresenterWrapsSettingsInASmallerMinimumFrame() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/App")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where line.contains("SettingsView()") {
                // The modifiers chained straight after the view, up to the closing brace.
                for next in lines[(index + 1)...].prefix(10) {
                    if next.trimmingCharacters(in: .whitespaces).hasPrefix("}") { break }
                    if next.contains(".frame(") { offenders.append("\(url.lastPathComponent):\(index + 1)") }
                }
            }
        }
        XCTAssertEqual(offenders, [], "SettingsView sizes itself; presenters must not add a frame")
    }
}
