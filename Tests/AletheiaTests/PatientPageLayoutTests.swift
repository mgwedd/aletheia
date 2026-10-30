@testable import Aletheia
import XCTest

final class PatientPageLayoutTests: XCTestCase {
    func testSessionPaneOnlyWithSessions() {
        XCTAssertFalse(PatientPageLayout.showsSessionPane(sessionCount: 0))
        XCTAssertTrue(PatientPageLayout.showsSessionPane(sessionCount: 1))
    }

    func testDraggedWidthIsKeptInRange() {
        XCTAssertEqual(PatientPageLayout.listWidth(proposed: 450, total: 1200), 450)
        XCTAssertEqual(PatientPageLayout.listWidth(proposed: 100, total: 1200), PatientPageLayout.listMinWidth)
        XCTAssertEqual(PatientPageLayout.listWidth(proposed: 2000, total: 1200), PatientPageLayout.listMaxWidth)
    }

    func testSessionKeepsItsMinimumInANarrowPage() {
        XCTAssertEqual(PatientPageLayout.listWidth(proposed: 600, total: 800), 800 - PatientPageLayout.sessionMinWidth)
    }

    func testListMinimumWinsWhenThePageIsTooNarrowForBoth() {
        XCTAssertEqual(PatientPageLayout.listWidth(proposed: 380, total: 500), PatientPageLayout.listMinWidth)
    }

    func testDamagedRecordsTitle() {
        XCTAssertEqual(DamagedRecordsNotice.title(count: 1), "1 record couldn't be read")
        XCTAssertEqual(DamagedRecordsNotice.title(count: 3), "3 records couldn't be read")
    }
}
