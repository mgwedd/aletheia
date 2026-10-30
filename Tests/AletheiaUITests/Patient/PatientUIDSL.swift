import XCTest

/// The patients sidebar and its draggable edge, as they sit on screen.
struct SidebarOnScreen {
    let driver: AppDriver
    var edge: XCUIElement { driver.element(id: "sidebar-divider") }
    /// The strip at the window's left edge while the sidebar is hidden.
    var revealEdge: XCUIElement { driver.element(id: "sidebar-reveal-edge") }
    var window: XCUIElement { driver.app.windows.firstMatch }
    /// From the window's left edge to the sidebar's edge.
    var width: CGFloat { edge.frame.midX - window.frame.minX }
}

/// The sidebar's width before and after its edge was dragged.
struct SidebarDragOnScreen {
    let before: CGFloat
    /// 0 when the sidebar collapsed.
    let after: CGFloat
    let sidebar: SidebarOnScreen
}

extension When {
    /// Opens the patient's page with the patients sidebar showing.
    func showSidebar(beside name: String) -> SidebarOnScreen {
        app.seed { $0.open = name }
        app.ensureLaunched()
        let sidebar = SidebarOnScreen(driver: app)
        XCTAssertTrue(app.exists(sidebar.edge), "no draggable edge between the sidebar and the page")
        return sidebar
    }

    func dragSidebarEdge(of sidebar: SidebarOnScreen, by points: CGFloat) -> SidebarDragOnScreen {
        let before = sidebar.width
        let start = sidebar.edge.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: points, dy: 0)))
        return SidebarDragOnScreen(before: before, after: sidebar.edge.exists ? sidebar.width : 0, sidebar: sidebar)
    }
}

extension When {
    /// Drags from the window's left edge while the sidebar is hidden.
    func dragFromWindowEdge(of sidebar: SidebarOnScreen, by points: CGFloat) -> SidebarOnScreen {
        XCTAssertTrue(app.exists(sidebar.revealEdge), "no strip at the window's edge to drag the sidebar back")
        let start = sidebar.revealEdge.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: points, dy: 0)))
        return sidebar
    }
}

extension Then where Subject == SidebarOnScreen {
    func isBack() {
        expect(subject.driver.exists(subject.edge), "the sidebar stayed hidden after a drag from the window's edge")
        expect(subject.width >= 200, "the sidebar came back \(subject.width) wide")
    }
}

/// The sidebar after Aletheia was quit and reopened.
struct ReopenedSidebarOnScreen {
    let sidebar: SidebarOnScreen
    /// The sidebar's footer, under its patients list.
    var footer: XCUIElement { sidebar.driver.element(id: "sidebar-settings") }
}

extension When {
    func reopenApp(showing sidebar: SidebarOnScreen) -> ReopenedSidebarOnScreen {
        app.relaunch()
        return ReopenedSidebarOnScreen(sidebar: sidebar)
    }
}

extension Then where Subject == ReopenedSidebarOnScreen {
    func showsThePatientsList(at width: CGFloat) {
        let driver = subject.sidebar.driver
        expect(driver.exists(subject.sidebar.edge), "no sidebar edge after reopening")
        expect(driver.exists(subject.footer) && subject.footer.isHittable,
               "the sidebar reopened without its patients list")
        expect(abs(subject.sidebar.width - width) <= 2,
               "the sidebar reopened \(subject.sidebar.width) wide, not \(width)")
    }

    func staysHidden() {
        let driver = subject.sidebar.driver
        expect(driver.app.windows.firstMatch.waitForExistence(timeout: 5), "no window after reopening")
        expect(!subject.sidebar.edge.exists, "the hidden sidebar came back after reopening")
    }
}

extension Then where Subject == SidebarOnScreen {
    /// The edge's grab area is as wide as every other pane divider.
    func edgeIsEasyToGrab() {
        expect(subject.edge.frame.width >= 12, "the sidebar edge's grab area is \(subject.edge.frame.width) wide")
    }
}

extension Then where Subject == SidebarDragOnScreen {
    func widenedTheSidebar() {
        expect(subject.after > subject.before + 30, "the sidebar went from \(subject.before) to \(subject.after) wide")
    }

    func narrowedTheSidebar() {
        expect(subject.after > 0 && subject.after < subject.before - 30, "the sidebar went from \(subject.before) to \(subject.after) wide")
    }

    func leftTheSidebarUsable() {
        expect(subject.after >= 200, "the sidebar narrowed to \(subject.after)")
        expect(subject.after <= 480, "the sidebar widened to \(subject.after)")
    }

    func collapsedTheSidebar() {
        expect(subject.sidebar.edge.waitForNonExistence(timeout: AppDriver.timeout),
               "the sidebar stayed open after its edge was dragged far past its narrowest width")
    }
}
