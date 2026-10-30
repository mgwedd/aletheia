import XCTest

/// The patients sidebar beside a patient's page.
final class PatientUITests: AcceptanceCase {
    func test_PATIENT_13() {
        given.patient(named: "Jane Doe", sessions: 1)
        let sidebar = when.showSidebar(beside: "Jane Doe")
        then(sidebar).edgeIsEasyToGrab()

        then(when.dragSidebarEdge(of: sidebar, by: 80)).widenedTheSidebar()
        then(when.dragSidebarEdge(of: sidebar, by: -60)).narrowedTheSidebar()
        then(when.dragSidebarEdge(of: sidebar, by: 3000)).leftTheSidebarUsable()
        then(when.dragSidebarEdge(of: sidebar, by: -80)).leftTheSidebarUsable()
        then(when.dragSidebarEdge(of: sidebar, by: -3000)).collapsedTheSidebar()
        then(when.dragFromWindowEdge(of: sidebar, by: 300)).isBack()
    }

    func test_PATIENT_14() {
        given.patient(named: "Jane Doe", sessions: 1)
        let sidebar = when.showSidebar(beside: "Jane Doe")
        let dragged = when.dragSidebarEdge(of: sidebar, by: 70)

        then(when.reopenApp(showing: sidebar)).showsThePatientsList(at: dragged.after)

        when.hideSidebar()
        then(when.reopenApp(showing: sidebar)).staysHidden()
    }
}
