import XCTest
@testable import Aletheia

final class ExportConfirmationTests: XCTestCase {
    private func make(
        name: String = "Alice Smith", count: Int = 3, scope: ExportConfirmation.Scope = .patientWide,
        proceed: @escaping () -> Void
    ) -> ExportConfirmation {
        ExportConfirmation(patientName: name, noun: "session", count: count, fileType: "zip", scope: scope, proceed: proceed)
    }

    func testCancelRunsNothing() {
        var ran = false
        make { ran = true }.resolve(confirmed: false)
        XCTAssertFalse(ran)
    }

    func testConfirmRunsTheExportOnce() {
        var runs = 0
        make { runs += 1 }.resolve(confirmed: true)
        XCTAssertEqual(runs, 1)
    }

    func testCancelWritesNoFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        let confirmation = make { _ = FileSaver.write(Data("x".utf8), to: url) }
        confirmation.resolve(confirmed: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        confirmation.resolve(confirmed: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testTextNamesInitialsAndCountButNeverTheName() {
        let c = make {}
        XCTAssertEqual(c.contents, "3 sessions")
        for text in [c.title, c.message, c.advice] {
            XCTAssertFalse(text.contains("Alice"))
            XCTAssertFalse(text.contains("Smith"))
        }
        XCTAssertTrue(c.title.contains("A.S."))
        XCTAssertTrue(c.message.contains("3 sessions"))
        XCTAssertTrue(c.message.contains("not encrypted"))
    }

    func testSingularCount() {
        XCTAssertEqual(make(count: 1) {}.contents, "1 session")
    }

    func testEveryExportEntryPointAsksFirst() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let session = try String(contentsOf: root.appendingPathComponent("Sources/App/Views/SessionDetailView.swift"), encoding: .utf8)
        let patient = try String(contentsOf: root.appendingPathComponent("Sources/App/Views/PatientDetailView.swift"), encoding: .utf8)
        XCTAssertEqual(session.components(separatedBy: "ExportConfirmation(").count - 1, 3)
        XCTAssertEqual(patient.components(separatedBy: "ExportConfirmation(").count - 1, 2)
        XCTAssertTrue(session.contains(".exportConfirmation($pendingExport, settings: settings)"))
        XCTAssertTrue(patient.contains(".exportConfirmation($pendingExport, settings: settings)"))
        // The save happens only in the functions the confirmation calls.
        for (text, button) in [(session, "exportSession(as format: ExportFormat) {"), (session, "exportNote(as format: ExportFormat) {"), (session, "exportPsychotherapyNote(as format: ExportFormat) {"), (patient, "exportRecords() {")] {
            let body = text.components(separatedBy: button)[1].components(separatedBy: "\n    }\n")[0]
            XCTAssertFalse(body.contains("ExportRenderer.save"), button)
            XCTAssertFalse(body.contains("chooseDestination"), button)
        }
    }

    func testSkippingAppliesOnlyToASingleNote() {
        for scope in [ExportConfirmation.Scope.session, .patientWide] {
            var presented = false
            var ran = false
            make(scope: scope) { ran = true }.begin(skipSingleNote: true) { _ in presented = true }
            XCTAssertTrue(presented, "\(scope) must still ask")
            XCTAssertFalse(ran)
            XCTAssertFalse(make(scope: scope) {}.offersDontAskAgain)
        }
    }

    func testSingleNoteAsksByDefaultAndOffersTheCheckbox() {
        var presented = false
        var ran = false
        let c = make(scope: .singleNote) { ran = true }
        c.begin(skipSingleNote: false) { _ in presented = true }
        XCTAssertTrue(presented)
        XCTAssertFalse(ran)
        XCTAssertTrue(c.offersDontAskAgain)
    }

    func testSingleNoteExportsDirectlyWhenOptedOut() {
        var presented = false
        var ran = false
        make(scope: .singleNote) { ran = true }.begin(skipSingleNote: true) { _ in presented = true }
        XCTAssertFalse(presented)
        XCTAssertTrue(ran)
    }

    func testSkipSettingDefaultsOffAndPersists() {
        let suite = "skip-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = AppSettings(defaults: defaults)
        XCTAssertFalse(first.skipSingleNoteExportConfirmation)
        first.skipSingleNoteExportConfirmation = true
        XCTAssertTrue(AppSettings(defaults: defaults).skipSingleNoteExportConfirmation)
    }

    func testPatientRecordsExportIsPatientWide() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let patient = try String(contentsOf: root.appendingPathComponent("Sources/App/Views/PatientDetailView.swift"), encoding: .utf8)
        XCTAssertTrue(patient.contains("scope: .patientWide"))
        XCTAssertFalse(patient.contains("singleNote"))
    }

    // MARK: Psychotherapy exports

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// The function bodies of a Swift source, keyed by name.
    private func functions(in text: String) -> [(name: String, body: String)] {
        text.components(separatedBy: "    private func ").dropFirst().map { chunk in
            let name = String(chunk.prefix { $0 != "(" })
            return (name, chunk)
        }
    }

    func testPsychotherapyScopeAlwaysAsksInTheAuthorizationWording() {
        var presented = false
        var ran = false
        let c = make(scope: .psychotherapy) { ran = true }
        c.begin(skipSingleNote: true) { _ in presented = true }
        XCTAssertTrue(presented, "the single-note opt-out must not apply")
        XCTAssertFalse(ran)
        XCTAssertFalse(c.offersDontAskAgain)
        XCTAssertEqual(c.title, PsychotherapyExport.confirmationTitle)
        XCTAssertEqual(c.message, PsychotherapyExport.confirmationMessage)
        XCTAssertEqual(c.confirmButtonTitle, PsychotherapyExport.confirmButton)
        for text in [c.title, c.message, c.advice] {
            XCTAssertFalse(text.contains("Alice"))
            XCTAssertFalse(text.contains("Smith"))
        }
        c.resolve(confirmed: false)
        XCTAssertFalse(ran)
        c.resolve(confirmed: true)
        XCTAssertTrue(ran)
    }

    func testOtherScopesKeepTheStandardButton() {
        XCTAssertEqual(make(scope: .singleNote) {}.confirmButtonTitle, ExportConfirmation.confirmTitle)
    }

    func testNoExportPathSavesWithoutTheConfirmation() throws {
        let allowed: Set<String> = ["saveSession", "saveNote", "savePsychotherapyNote", "saveRecords", "exportPsychotherapyNotes"]
        for path in ["Sources/App/Views/SessionDetailView.swift", "Sources/App/Views/PatientDetailView.swift"] {
            let text = try source(path)
            for fn in functions(in: text) {
                let saves = fn.body.components(separatedBy: "\n    }\n")[0]
                let writes = saves.contains("ExportRenderer.save(") || saves.contains("chooseDestination(")
                    || saves.contains("FileSaver.saveText") || saves.contains("FileSaver.saveData")
                if writes { XCTAssertTrue(allowed.contains(fn.name), "\(path): \(fn.name) saves without the confirmation") }
            }
            XCTAssertFalse(text.contains(".confirmationDialog(\n            PsychotherapyExport"), path)
        }
    }

    func testPsychotherapyExportsGoThroughTheConfirmationAndUseInitials() throws {
        let session = try source("Sources/App/Views/SessionDetailView.swift")
        let patient = try source("Sources/App/Views/PatientDetailView.swift")
        XCTAssertTrue(session.contains("scope: .psychotherapy"))
        XCTAssertTrue(session.contains("{ savePsychotherapyNote(as: format) }"))
        XCTAssertTrue(patient.contains("scope: .psychotherapy"))
        XCTAssertTrue(patient.contains("{ exportPsychotherapyNotes() }"))
        XCTAssertFalse(patient.contains("PatientLabel(patient).text"), "export names use the initials helper")
        XCTAssertTrue(patient.contains("exportFileName(forPatientNamed: patient.name, \"Psychotherapy notes\")"))
        XCTAssertTrue(try source("Sources/App/Services/PsychotherapyExport.swift")
            .contains("FileSaver.exportFileName(forPatientNamed: patientName"))
        // Every suggested export name in these views comes from the initials helper.
        for text in [session, patient] { XCTAssertFalse(text.contains("suggestedName: FileSaver.fileName(")) }
    }
}
