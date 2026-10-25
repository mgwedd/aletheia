import XCTest
@testable import Aletheia

/// "On this Mac" is said up front (first run, setup, the consent guide) and on
/// the security overview, and not repeated through the rest of the interface.
final class OnDeviceCopyTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/App/\(path)"), encoding: .utf8)
    }

    func testFeatureScreensDoNotRepeatTheReassurance() throws {
        let removed: [(String, [String])] = [
            ("Views/PatientProfileEditor.swift", ["It stays on this Mac", "local AI model"]),
            ("Views/PatientProfileCard.swift", ["local AI model"]),
            ("Views/SessionDetailView.swift", ["on-device\"", "Recording on this Mac"]),
            ("Views/SettingsView.swift", ["recorded only on this Mac", "every AI path is on-device"]),
            ("Views/DoctorView.swift", ["Everything is checked on this Mac"]),
            ("Views/GlobalSearchResultsView.swift", ["Searched on this Mac"]),
            ("Views/EncryptionSettingsView.swift", ["recordings on this Mac"]),
            ("Views/TranscriptionProgressView.swift", ["Runs entirely on this Mac"]),
            ("Views/MermaidDiagramView.swift", ["on-device model"]),
            ("Services/AIEngineProblem.swift", ["stays on this Mac", "then runs on this Mac"]),
            ("Services/ContextBudget.swift", ["sessions on this Mac"]),
            ("Services/Digest/LongSessionNote.swift", ["room on this Mac"]),
        ]
        for (path, phrases) in removed {
            let text = try source(path)
            for phrase in phrases {
                XCTAssertFalse(text.contains(phrase), "\(path) still says \"\(phrase)\"")
            }
        }
    }

    func testTheStatementIsStillMadeWhereItBelongs() throws {
        XCTAssertTrue(try source("Views/FirstRunView.swift").contains("run on this Mac"))
        XCTAssertTrue(try source("Views/SetupChecklistView.swift").contains("runs on this Mac"))
        XCTAssertTrue(try source("Views/ConsentGuideView.swift").contains("runs on this Mac"))
        XCTAssertTrue(try source("Services/SecurityPosture.swift").contains("run on this Mac's own hardware"))
    }

    func testSearchFooterIsEmptyBeforeATypedQuery() throws {
        // Read as source: results (and their footer) show only once something is
        // typed, and the footer's count only once something matched.
        XCTAssertTrue(try source("Views/RootView.swift").contains("if search.hasQuery && hasOpenPatient {"))
        XCTAssertTrue(try source("Views/GlobalSearchResultsView.swift").contains("guard total > 0 else { return \"\" }"))
    }
}
