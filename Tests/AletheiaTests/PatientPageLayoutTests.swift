@testable import Aletheia
import XCTest

final class PatientPageLayoutTests: XCTestCase {
    func testSessionPaneOnlyWhileASessionIsOpen() {
        XCTAssertFalse(PatientPageLayout.showsSessionPane(hasOpenSession: false))
        XCTAssertTrue(PatientPageLayout.showsSessionPane(hasOpenSession: true))
    }

    func testDraggedWidthIsKeptInRange() {
        XCTAssertEqual(PatientPageLayout.listWidth(proposed: 450, total: 1200), 450)
        XCTAssertEqual(PatientPageLayout.listWidth(proposed: 100, total: 1200), PatientPageLayout.listMinWidth)
        XCTAssertEqual(PatientPageLayout.listWidth(proposed: 2000, total: 1200), 1200 - 1 - PatientPageLayout.sessionMinWidth)
    }

    func testOpensWithACompactListAndTheSessionTakingMostOfThePage() {
        let list = PatientPageLayout.listWidth(proposed: PatientPageLayout.defaultListWidth, total: 1100)
        XCTAssertEqual(list, 340)
        XCTAssertGreaterThan(1100 - 1 - list, 2 * list)
    }

    func testTheCompactListKeepsItsWidthAsTheWindowGrows() {
        for total: CGFloat in [1000, 1400, 2000] {
            XCTAssertEqual(PatientPageLayout.listWidth(proposed: PatientPageLayout.defaultListWidth, total: total), 340)
        }
    }

    func testABrokenStoredWidthFallsBackToTheDefault() {
        XCTAssertEqual(PatientPageLayout.listWidth(proposed: .nan, total: 1100), PatientPageLayout.defaultListWidth)
        XCTAssertEqual(PatientPageLayout.listWidth(proposed: .infinity, total: 1100), PatientPageLayout.defaultListWidth)
    }

    func testDividerGripIsWideEnoughToGrab() {
        XCTAssertGreaterThanOrEqual(PaneDivider.gripWidth, 12)
    }

    func testSessionKeepsItsMinimumInANarrowPage() {
        XCTAssertEqual(PatientPageLayout.listWidth(proposed: 600, total: 800), 800 - 1 - PatientPageLayout.sessionMinWidth)
    }

    func testAPageTooNarrowForBothIsSharedInProportionToTheirMinimums() {
        let room = PatientPageLayout.listMinWidth + PatientPageLayout.sessionMinWidth
        let width = PatientPageLayout.listWidth(proposed: 380, total: room / 2 + 1)
        XCTAssertEqual(width, PatientPageLayout.listMinWidth / 2, accuracy: 0.001)
    }

    func testDamagedRecordsTitle() {
        XCTAssertEqual(DamagedRecordsNotice.title(count: 1), "1 record couldn't be read")
        XCTAssertEqual(DamagedRecordsNotice.title(count: 3), "3 records couldn't be read")
    }
}
