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

    /// The risk-phrase field shows no example phrase.
    func testRiskPhraseFieldHasNoExample() throws {
        let settings = try source("Sources/App/Views/SettingsView.swift")
        XCTAssertTrue(settings.contains(#"TextField("Add a phrase", text: $newRiskPhrase)"#))
        XCTAssertFalse(settings.contains("e.g. kill myself"))
    }

    func testSummaryLengthCaptionIsOnlyTheBlurb() throws {
        XCTAssertFalse(try source("Sources/App/Views/SettingsView.swift").contains("Clarity comes first"))
    }

    /// A checkmark says a model is downloaded; "to this Mac" is implied.
    func testDownloadedModelsShowACheckmarkNotACaption() throws {
        let settings = try source("Sources/App/Views/SettingsView.swift")
        XCTAssertFalse(settings.contains("Downloaded to this Mac"))
        // One shared row builder renders the mark for both the Whisper and language-model cards.
        XCTAssertEqual(settings.components(separatedBy: "DownloadedMark()").count - 1, 1)
        XCTAssertEqual(settings.components(separatedBy: "modelRow(").count - 1, 3, "its definition, Whisper and the language model")
        XCTAssertTrue(settings.contains(#"Image(systemName: "checkmark.circle.fill")"#))
    }
}
