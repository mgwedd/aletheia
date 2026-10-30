import XCTest

extension Copy {
    static let exportPsychotherapyNotes = "Export psychotherapy notes…"
    static let psychotherapyConfirmationTitle = "Export psychotherapy notes?"
    static let nothingToExportPsychotherapy = "No psychotherapy notes to export"
}

/// What clicking Export psychotherapy notes… put on screen.
struct PsychotherapyExportOnScreen {
    let driver: AppDriver

    /// An alert's words may sit in its value rather than its label on macOS.
    func text(_ words: String) -> XCUIElement {
        driver.app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", words, words)).firstMatch
    }
}

extension Given {
    /// Jane Doe with one session that has no psychotherapy note or private comment.
    func janeWithASessionAndNoPsychotherapyNotes() {
        app.seed {
            $0.license = "test"
            $0.fileVault = "on"
            $0.patients = [.init(name: "Jane Doe", sessions: 1)]
        }
    }
}

extension When {
    /// Puts Jane Doe's page on screen (the scenario's `open`).
    func openPatientPage(of name: String) {
        app.seed { $0.open = name }
        app.ensureLaunched()
        XCTAssertTrue(app.exists(app.button(Copy.exportPsychotherapyNotes)), "\(name)'s page is not on screen")
    }

    func pressExportPsychotherapyNotes() -> PsychotherapyExportOnScreen {
        app.tap(Copy.exportPsychotherapyNotes)
        return PsychotherapyExportOnScreen(driver: app)
    }
}

extension Then where Subject == PsychotherapyExportOnScreen {
    func saysThereIsNothingToExport() {
        expect(subject.driver.exists(subject.text(Copy.nothingToExportPsychotherapy)),
               "no \"\(Copy.nothingToExportPsychotherapy)\" alert")
    }

    func asksForNoAuthorization() {
        expect(!subject.text(Copy.psychotherapyConfirmationTitle).exists,
               "the authorization confirmation opened anyway")
    }
}
