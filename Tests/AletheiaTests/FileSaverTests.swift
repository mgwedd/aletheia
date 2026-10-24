import XCTest
@testable import Aletheia

final class FileSaverTests: XCTestCase {
    func testFileNameSanitizesDisallowedCharacters() {
        let name = FileSaver.fileName("Patient/Name*", "Summary: Notes?")
        XCTAssertEqual(name, "Patient-Name- - Summary- Notes-")
    }

    func testFileNameJoinsMultiplePartsWithHyphenSpace() {
        let name = FileSaver.fileName("Alice Smith", "2026-09-30")
        XCTAssertEqual(name, "Alice Smith - 2026-09-30")
    }
}

final class ExportFileNameTests: XCTestCase {
    func testDefaultNameUsesInitialsAndDateNotTheName() {
        let name = FileSaver.exportFileName(forPatientNamed: "Alice Smith", "2026-09-30")
        XCTAssertEqual(name, "A.S. - 2026-09-30")
        XCTAssertFalse(name.contains("Alice"))
        XCTAssertFalse(name.contains("Smith"))
    }

    func testBlankNameFallsBackToClient() {
        XCTAssertEqual(FileSaver.exportFileName(forPatientNamed: "  ", "Records"), "Client - Records")
    }

    func testPathCharactersInPartsAreStillCleaned() {
        XCTAssertEqual(FileSaver.exportFileName(forPatientNamed: "Jo Li", "a/b"), "J.L. - a-b")
    }

    func testExportCallersNeverNameTheFileAfterThePatient() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        for file in ["Sources/App/Views/SessionDetailView.swift", "Sources/App/Views/PatientDetailView.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            XCTAssertFalse(text.contains("FileSaver.fileName(patient.name"), file)
        }
    }
}
