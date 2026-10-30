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
        XCTAssertEqual(PatientPageLayout.listWidth(proposed: 2000, total: 1200), 1200 - 1 - PatientPageLayout.sessionMinWidth)
    }

    func testOpensSplitEvenly() {
        XCTAssertEqual(PatientPageLayout.listWidth(share: PatientPageLayout.defaultListShare, total: 1101), 550)
    }

    func testABrokenShareFallsBackToAnEvenSplit() {
        XCTAssertEqual(PatientPageLayout.listWidth(share: .nan, total: 1001), 500)
        XCTAssertEqual(PatientPageLayout.listWidth(share: 7, total: 1001), 500)
    }

    func testADraggedWidthIsKeptAsAShareOfThePage() {
        let share = PatientPageLayout.share(listWidth: 400, total: 1001)
        XCTAssertEqual(PatientPageLayout.listWidth(share: share, total: 1001), 400, accuracy: 0.001)
        XCTAssertEqual(PatientPageLayout.listWidth(share: share, total: 1501), 600, accuracy: 0.001)
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
