import XCTest

/// The psychotherapy notes export on a patient's page. The save panel can't be
/// answered by a UI test, so only what comes before it is driven here.
final class PsychotherapyExportUITests: AcceptanceCase {
    func test_EXPORT_13() {
        given.janeWithASessionAndNoPsychotherapyNotes()
        when.openPatientPage(of: "Jane Doe")

        let screen = when.pressExportPsychotherapyNotes()

        then(screen).saysThereIsNothingToExport()
        then(screen).asksForNoAuthorization()
    }
}
