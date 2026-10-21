import XCTest
@testable import Aletheia

final class SettingsSidebarPolishTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8)
    }

    /// The sheet focuses the first row when it opens, so a focus ring stayed on
    /// "General" whichever pane was selected. The selected fill marks the row.
    func testSidebarRowsDrawNoFocusRing() throws {
        let components = try source("Sources/App/Views/Settings/SettingsComponents.swift")
        let row = try XCTUnwrap(components.range(of: "private struct SettingsSidebarRow"))
        XCTAssertTrue(components[row.lowerBound...].contains(".focusEffectDisabled()"))
    }

    func testSummaryLengthCaptionIsOnlyTheBlurb() throws {
        XCTAssertFalse(try source("Sources/App/Views/SettingsView.swift").contains("Clarity comes first"))
    }

    /// A checkmark says a model is downloaded; "to this Mac" is implied.
    func testDownloadedModelsShowACheckmarkNotACaption() throws {
        let settings = try source("Sources/App/Views/SettingsView.swift")
        XCTAssertFalse(settings.contains("Downloaded to this Mac"))
        XCTAssertEqual(settings.components(separatedBy: "DownloadedMark()").count - 1, 2, "Whisper and the language model")
        XCTAssertTrue(settings.contains(#"Image(systemName: "checkmark.circle.fill")"#))
    }
}
