import XCTest
@testable import Aletheia

final class PatientLabelTests: XCTestCase {
    func testLabelIsDottedInitials() {
        XCTAssertEqual(PatientLabel(name: "Jane Doe").text, "J.D.")
        XCTAssertEqual(PatientLabel(name: "jane").text, "J.")
        XCTAssertEqual(PatientLabel(name: "Mary Ann van Buren").text, "M.B.")
        XCTAssertEqual(PatientLabel(name: "  ").text, "?")
        XCTAssertEqual(PatientLabel(name: "").text, "?")
    }

    func testLabelNeverContainsTheName() {
        let label = PatientLabel(name: "Jane Doe").text
        XCTAssertFalse(label.contains("ane"))
        XCTAssertFalse(label.contains("oe"))
    }

    func testPatientInitializerMatchesName() {
        let id = UUID()
        let patient = Patient(id: id, name: "Jane Doe", slug: id.uuidString)
        XCTAssertEqual(PatientLabel(patient), PatientLabel(name: "Jane Doe"))
    }

    func testContinuationOpensNothingWhileLocked() {
        let id = SpotlightItemBuilder.patientIdentifier(UUID())
        XCTAssertNil(SystemSurfaceAccess.route(forIdentifier: id, isLocked: true))
        XCTAssertNotNil(SystemSurfaceAccess.route(forIdentifier: id, isLocked: false))
    }

    func testSystemSurfacesFollowTheLockMirror() {
        let prior = SystemSurfaceAccess.isLocked
        defer { SessionSearch.setAppLocked(prior) }
        SessionSearch.setAppLocked(true)
        XCTAssertTrue(SystemSurfaceAccess.isLocked)
        SessionSearch.setAppLocked(false)
        XCTAssertEqual(SystemSurfaceAccess.isLocked, !SessionSearch.mayOpenIndex)
    }

    // MARK: - Source scan

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(relative), encoding: .utf8)
    }

    private func swiftFiles(under relative: String) throws -> [String] {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let names = try FileManager.default.contentsOfDirectory(atPath: repo.appendingPathComponent(relative).path)
        return names.filter { $0.hasSuffix(".swift") }.map { relative + "/" + $0 }
    }

    func testOutOfAppBuildersNeverReadAPatientName() throws {
        var files = try ["Sources/App/Services/Spotlight", "Sources/App/Intents",
                         "Sources/App/Services/Calendar", "Sources/App/Services/Reminders"]
            .flatMap(swiftFiles(under:))
        files.append("Sources/App/Services/SessionQueries.swift")
        XCTAssertGreaterThanOrEqual(files.count, 9, "the scan must find the builders")
        let banned = try NSRegularExpression(pattern: #"\.name\b|patientName"#)
        for file in files {
            let code = try source(file).split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            let range = NSRange(code.startIndex..., in: code)
            XCTAssertNil(banned.firstMatch(in: code, range: range), "\(file) reads a patient name; use PatientLabel")
        }
    }
}
