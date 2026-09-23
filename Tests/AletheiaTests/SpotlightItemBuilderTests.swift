import AletheiaCore
import XCTest
@testable import Aletheia

final class SpotlightItemBuilderTests: XCTestCase {
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func patient() -> Patient {
        Patient(id: UUID(), name: "Jane Doe", slug: "Jane-Doe")
    }

    func testEntriesIncludeAPatientCardAndOnePerSession() {
        let p = patient()
        let sessions = [
            SessionRecord(patientId: p.id, date: date(2026, 3, 5), folderName: "2026-03-05_Session"),
            SessionRecord(patientId: p.id, date: date(2026, 1, 5), folderName: "2026-01-05_Session"),
        ]
        let entries = SpotlightItemBuilder.entries(for: p, sessions: sessions)

        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.first?.uniqueIdentifier, SpotlightItemBuilder.patientIdentifier(p.id))
        XCTAssertNil(entries.first?.contentModificationDate, "patient card has no modification date")

        let sessionEntry = entries[1]
        XCTAssertEqual(sessionEntry.uniqueIdentifier, SpotlightItemBuilder.sessionIdentifier(patientID: p.id, folderName: "2026-03-05_Session"))
        XCTAssertTrue(sessionEntry.title.contains("Jane Doe"))
        XCTAssertEqual(sessionEntry.contentModificationDate, date(2026, 3, 5))
    }

    func testEntriesNeverContainTranscriptContent() {
        // The builder only ever gets patient + session metadata, so by
        // construction it can't leak transcript text; assert the description is
        // the fixed metadata string.
        let p = patient()
        let entries = SpotlightItemBuilder.entries(
            for: p,
            sessions: [SessionRecord(patientId: p.id, date: date(2026, 3, 5), folderName: "2026-03-05_Session")]
        )
        XCTAssertTrue(entries.allSatisfy { $0.keywords.contains("therapy") })
        XCTAssertEqual(entries[1].contentDescription, "Therapy session on \(longDate(2026, 3, 5)).")
    }

    func testPatientRouteRoundTrips() {
        let id = UUID()
        let route = SpotlightItemBuilder.route(forIdentifier: SpotlightItemBuilder.patientIdentifier(id))
        XCTAssertEqual(route, .patient(id))
    }

    func testSessionRouteRoundTrips() {
        let id = UUID()
        let identifier = SpotlightItemBuilder.sessionIdentifier(patientID: id, folderName: "2026-03-05_Session")
        XCTAssertEqual(SpotlightItemBuilder.route(forIdentifier: identifier), .session(patientID: id, folderName: "2026-03-05_Session"))
    }

    func testMalformedIdentifiersReturnNil() {
        XCTAssertNil(SpotlightItemBuilder.route(forIdentifier: ""))
        XCTAssertNil(SpotlightItemBuilder.route(forIdentifier: "bogus"))
        XCTAssertNil(SpotlightItemBuilder.route(forIdentifier: "patient/not-a-uuid"))
        XCTAssertNil(SpotlightItemBuilder.route(forIdentifier: "session/\(UUID().uuidString)"), "missing folder name")
    }

    private func longDate(_ y: Int, _ m: Int, _ d: Int) -> String {
        let f = DateFormatter()
        f.dateStyle = .long
        return f.string(from: date(y, m, d))
    }
}
