import XCTest

extension Copy {
    static let oneRecordCouldntBeRead = "1 record couldn't be read"
}

/// The sidebar with a damaged record in the data folder.
struct DamagedRecordSidebar {
    let driver: AppDriver
    var notice: XCUIElement { driver.element(id: "sidebar-damaged-records") }
}

/// The review of a damaged record, opened from the sidebar.
struct DamagedRecordReview {
    let driver: AppDriver
    var done: XCUIElement { driver.button("Done") }
}

extension Given {
    /// Sam Lee readable with a session; Jane Doe's record file unreadable.
    func samLeeAndADamagedRecordForJaneDoe() {
        app.seed {
            $0.license = "test"
            $0.fileVault = "on"
            $0.patients = [.init(name: "Sam Lee", sessions: 1), .init(name: "Jane Doe", damaged: true)]
        }
    }
}

extension When {
    func lookAtTheSidebar() -> DamagedRecordSidebar {
        app.ensureLaunched()
        return DamagedRecordSidebar(driver: app)
    }

    /// Opens the damaged-record notice and presses Review on its one record.
    func reviewTheDamagedRecord(from sidebar: DamagedRecordSidebar) -> DamagedRecordReview {
        app.click(sidebar.notice, "the damaged-record notice")
        app.tap("Review")
        return DamagedRecordReview(driver: app)
    }
}

extension Then where Subject == DamagedRecordSidebar {
    func saysOneRecordCouldntBeRead() {
        expect(subject.driver.exists(subject.notice), "no damaged-record notice in the sidebar")
        expect(subject.notice.label.contains(Copy.oneRecordCouldntBeRead),
               "the notice reads \"\(subject.notice.label)\"")
    }

    func stillListsThePatient(_ name: String) {
        let row = subject.driver.text(containing: name)
        expect(subject.driver.exists(row) && row.isHittable, "\(name) is not visible in the sidebar")
    }
}

extension Then where Subject == DamagedRecordReview {
    func opensOnScreen() {
        expect(subject.driver.exists(subject.done), "the review did not open")
        let window = subject.driver.app.windows.firstMatch.frame
        expect(window.contains(subject.done.frame) && subject.done.isHittable,
               "the review's Done button at \(subject.done.frame) is outside the window \(window)")
    }
}
