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
    var closeSession: XCUIElement { driver.element(id: "session-close") }
    var firstSessionRow: XCUIElement { driver.element(id: "session-row") }
    var window: XCUIElement { driver.app.windows.firstMatch }
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

    /// Hides the patients sidebar (View > Hide Sidebar, ⌃⌘S), so a small
    /// screen still leaves the page room to drag its divider.
    func hideSidebar() {
        let sidebar = app.element(id: "sidebar-settings")
        app.app.typeKey("s", modifierFlags: [.control, .command])
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false OR isHittable == false"), object: sidebar)
        guard XCTWaiter().wait(for: [gone], timeout: AppDriver.timeout) == .completed else {
            return app.fail("the patients sidebar did not hide")
        }
    }

    /// Clicks **Close Session** on the open session.
    func closeTheSession(on page: PatientPageOnScreen) {
        app.click(page.closeSession, "Close Session button")
        XCTAssertTrue(app.gone(page.sessionPane), "the session pane stayed after Close Session")
    }

    /// Clicks the newest session in the list.
    func openTheFirstSession(on page: PatientPageOnScreen) {
        app.click(page.firstSessionRow, "session in the list")
        XCTAssertTrue(app.exists(page.sessionPane), "the session did not open")
        // The pane exists as soon as it starts sliding in; wait for the list
        // to finish narrowing before anything measures it.
        let list = page.list
        let narrowed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in list.frame.width <= 370 }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [narrowed], timeout: AppDriver.timeout), .completed,
                       "the list did not narrow beside the open session")
    }

    /// Drags the divider between the session list and the session by `points`.
    func dragColumnDivider(on page: PatientPageOnScreen, by points: CGFloat) -> ColumnDragOnScreen {
        XCTAssertTrue(app.exists(page.divider), "no divider between the session list and the session")
        let before = page.list.frame.width
        let start = page.divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: points, dy: 0)))
        // A drag under the narrowest springs back once let go.
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        return ColumnDragOnScreen(before: before, after: page.list.frame.width, page: page)
    }
}

extension Then where Subject == PatientPageOnScreen {
    func saysNoSessionsYet() {
        expect(subject.driver.exists(subject.driver.text(containing: Copy.noSessionsYet)),
               "the list does not say \"\(Copy.noSessionsYet)\"")
    }

    /// The list is a compact column (about 300 to 360 points) and the
    /// session takes the rest of the page.
    func givesTheSessionMostOfThePage() {
        expect(subject.driver.exists(subject.sessionPane), "no session pane beside the list")
        let column = subject.list
        subject.driver.settles { (290...370).contains(column.frame.width) }
        let list = subject.list.frame.width
        let session = subject.sessionPane.frame.width
        expect(list >= 290 && list <= 370, "the list opens \(list) wide")
        expect(session > list, "the session opens \(session) wide beside a list \(list) wide")
    }

    /// With no session open, the list takes the whole page.
    func fillsThePageWithTheList() {
        let column = subject.list, frame = subject.window
        subject.driver.settles { column.frame.width >= 0.9 * frame.frame.width }
        let list = subject.list.frame.width
        let window = subject.window.frame.width
        expect(list >= 0.9 * window, "the list is \(list) wide in a window \(window) wide")
    }

    /// The divider's grab area is wide enough to catch with the mouse.
    func dividerIsEasyToGrab() {
        expect(subject.divider.frame.width >= 12, "the divider's grab area is \(subject.divider.frame.width) wide")
    }

    func showsNoEmptySessionPane() {
        expect(!subject.sessionPane.exists, "a session pane sits beside the list with no session open")
        expect(!subject.driver.text(containing: Copy.selectASession).exists,
               "\"\(Copy.selectASession)\" is shown with no session open")
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
