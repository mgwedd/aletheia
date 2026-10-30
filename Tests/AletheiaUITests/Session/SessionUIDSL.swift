import XCTest

extension Copy {
    static let noSessionsYet = "No Sessions Yet"
    static let selectASession = "Select a Session"
}

/// A patient's page as it sits on screen.
struct PatientPageOnScreen {
    let driver: AppDriver
    var list: XCUIElement { driver.element(id: "patient-session-list-column") }
    var sessionPane: XCUIElement { driver.element(id: "patient-session-pane") }
    var divider: XCUIElement { driver.element(id: "patient-page-divider") }
}

/// The session list's width before and after its divider was dragged.
struct ColumnDragOnScreen {
    let before: CGFloat
    let after: CGFloat
    let page: PatientPageOnScreen
}

extension Given {
    func patient(named name: String, sessions: Int) {
        app.seed {
            $0.license = "test"
            $0.fileVault = "on"
            $0.patients = [.init(name: name, sessions: sessions)]
        }
    }
}

extension When {
    /// Puts the patient's page on screen (the scenario's `open`).
    func showPatientPage(of name: String) -> PatientPageOnScreen {
        app.seed { $0.open = name }
        app.ensureLaunched()
        hideSidebar()
        let page = PatientPageOnScreen(driver: app)
        XCTAssertTrue(app.exists(page.list), "\(name)'s page is not on screen")
        return page
    }

    /// Hides the patients sidebar (View > Hide Sidebar), so a small screen
    /// still leaves the page room to drag its divider.
    private func hideSidebar() {
        app.click(app.app.menuBars.menuBarItems["View"], "View menu")
        app.click(app.app.menuItems["Hide Sidebar"], "View > Hide Sidebar")
    }

    /// Drags the divider between the session list and the session by `points`.
    func dragColumnDivider(on page: PatientPageOnScreen, by points: CGFloat) -> ColumnDragOnScreen {
        XCTAssertTrue(app.exists(page.divider), "no divider between the session list and the session")
        let before = page.list.frame.width
        let start = page.divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: points, dy: 0)))
        return ColumnDragOnScreen(before: before, after: page.list.frame.width, page: page)
    }
}

extension Then where Subject == PatientPageOnScreen {
    func saysNoSessionsYet() {
        expect(subject.driver.exists(subject.driver.text(containing: Copy.noSessionsYet)),
               "the list does not say \"\(Copy.noSessionsYet)\"")
    }

    func splitsEvenly() {
        let list = subject.list.frame.width
        let session = subject.sessionPane.frame.width
        expect(abs(list - session) <= 0.05 * (list + session),
               "the list opens \(list) wide beside a session \(session) wide")
    }

    /// The divider's grab area is wide enough to catch with the mouse.
    func dividerIsEasyToGrab() {
        expect(subject.divider.frame.width >= 12, "the divider's grab area is \(subject.divider.frame.width) wide")
    }

    func showsNoEmptySessionPane() {
        expect(!subject.sessionPane.exists, "a session pane sits beside a list with no sessions")
        expect(!subject.driver.text(containing: Copy.selectASession).exists,
               "\"\(Copy.selectASession)\" is shown for a patient with no sessions")
    }
}

extension Then where Subject == ColumnDragOnScreen {
    func widenedTheList() {
        expect(subject.after > subject.before + 40, "the list went from \(subject.before) to \(subject.after) wide")
    }

    func narrowedTheList() {
        expect(subject.after < subject.before - 40, "the list went from \(subject.before) to \(subject.after) wide")
    }

    func leftBothSidesUsable() {
        expect(subject.after >= 300, "the list narrowed to \(subject.after)")
        expect(subject.page.sessionPane.frame.width >= 360,
               "the session narrowed to \(subject.page.sessionPane.frame.width)")
    }
}
