import XCTest

/// A patient's page: its session list and the session beside it.
final class SessionUITests: AcceptanceCase {
    func test_SESSION_01() {
        given.patient(named: "Jane Doe", sessions: 0)

        let page = when.showPatientPage(of: "Jane Doe")

        then(page).saysNoSessionsYet()
        then(page).showsNoEmptySessionPane()
    }

    func test_SESSION_10() {
        given.patient(named: "Jane Doe", sessions: 1)
        let page = when.showPatientPage(of: "Jane Doe")
        then(page).givesTheSessionMostOfThePage()
        then(page).dividerIsEasyToGrab()

        then(when.dragColumnDivider(on: page, by: 150)).widenedTheList()
        then(when.dragColumnDivider(on: page, by: -100)).narrowedTheList()
        then(when.dragColumnDivider(on: page, by: 3000)).leftBothSidesUsable()
        then(when.dragColumnDivider(on: page, by: -3000)).leftBothSidesUsable()
    }

    func test_SESSION_11() {
        given.patient(named: "Jane Doe", sessions: 1)
        let page = when.showPatientPage(of: "Jane Doe")
        then(page).givesTheSessionMostOfThePage()

        when.closeTheSession(on: page)
        then(page).showsNoEmptySessionPane()
        then(page).fillsThePageWithTheList()

        when.openTheFirstSession(on: page)
        then(page).givesTheSessionMostOfThePage()
    }
}
