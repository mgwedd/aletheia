import XCTest

extension Copy {
    static let consentSheetTitle = "Record consent"
    static let consentConfirmation = "I obtained consent from everyone in this session to record it and to process the recording with AI."
    static let consentStartRecording = "Start recording"
    static let consentChooseAudio = "Choose Audio File…"
    static let consentRecordSession = "Record Session"
    static let consentImportAudio = "Import Audio…"
    static let consentApplyToPatients = "Apply to Patients…"
    static let consentSelectAll = "Select All"
    static let consentEverySession = "Every session"
    static let consentFileName = "consent.json"
}

/// The consent sheet on screen.
struct ConsentSheetOnScreen {
    let driver: AppDriver
    let confirmTitle: String

    /// The title is a header, which macOS may not report as a plain static
    /// text, and its words may sit in its value rather than its label.
    var title: XCUIElement {
        driver.app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR value == %@", Copy.consentSheetTitle, Copy.consentSheetTitle))
            .firstMatch
    }
    var confirmation: XCUIElement { driver.app.checkBoxes[Copy.consentConfirmation].firstMatch }
    var confirmButton: XCUIElement { driver.button(confirmTitle) }
}

/// The Apply to Patients… sheet on screen.
struct ApplyToPatientsOnScreen {
    let driver: AppDriver
    var applyButton: XCUIElement { driver.button("Apply") }
}

extension Given {
    /// Jane Doe and Adam Lee, each with one session, on a licensed app with
    /// FileVault on. Without a license the app refuses before asking for consent.
    func janeAndAdamWithASessionEach() {
        app.seed {
            $0.license = "on"
            $0.fileVault = "on"
            $0.patients = [.init(name: "Jane Doe", sessions: 1), .init(name: "Adam Lee", sessions: 1)]
        }
    }
}

extension When {
    /// Puts the patient's newest session on screen (the scenario's `open`).
    /// Finding rows in the sidebar is not what these checks are about.
    func openFirstSession(of name: String) {
        app.seed { $0.open = name }
        app.ensureLaunched()
        XCTAssertTrue(app.exists(app.button(Copy.consentRecordSession)), "\(name)'s session is not on screen")
    }

    func pressRecordSession() -> ConsentSheetOnScreen {
        app.tap(Copy.consentRecordSession)
        return ConsentSheetOnScreen(driver: app, confirmTitle: Copy.consentStartRecording)
    }

    func pressImportAudio() -> ConsentSheetOnScreen {
        app.tap(Copy.consentImportAudio)
        return ConsentSheetOnScreen(driver: app, confirmTitle: Copy.consentChooseAudio)
    }

    func tickConfirmation(on sheet: ConsentSheetOnScreen) {
        XCTAssertTrue(app.exists(sheet.confirmation), "no confirmation checkbox")
        sheet.confirmation.click()
    }

    func cancel(_ sheet: ConsentSheetOnScreen) { app.tap("Cancel") }

    func openApplyToPatients() -> ApplyToPatientsOnScreen {
        app.ensureLaunched()
        app.app.typeKey(",", modifierFlags: .command)
        app.tap(Copy.consentApplyToPatients)
        return ApplyToPatientsOnScreen(driver: app)
    }

    func applyEverySessionToAll(on sheet: ApplyToPatientsOnScreen) {
        let selectAll = app.app.checkBoxes[Copy.consentSelectAll].firstMatch
        XCTAssertTrue(app.exists(selectAll), "no Select All toggle")
        selectAll.click()
        let every = app.app.radioButtons[Copy.consentEverySession].firstMatch
        if app.exists(every) { every.click() } else { app.tap(Copy.consentEverySession) }
        app.tap("Apply")
    }
}

extension Then where Subject == ConsentSheetOnScreen {
    func isShown() {
        expect(subject.driver.exists(subject.title), "no \(Copy.consentSheetTitle) sheet")
        expect(subject.driver.exists(subject.confirmButton), "no \(subject.confirmTitle) button")
    }

    func confirmIsEnabled(_ enabled: Bool) {
        expect(subject.driver.becomesEnabled(subject.confirmButton, enabled),
               "\(subject.confirmTitle) is \(enabled ? "disabled" : "enabled")")
    }

    func isClosed() { expect(subject.driver.gone(subject.title), "the sheet is still open") }
}

extension Then where Subject == ApplyToPatientsOnScreen {
    func applyIsEnabled(_ enabled: Bool) {
        expect(subject.driver.becomesEnabled(subject.applyButton, enabled), "Apply is \(enabled ? "disabled" : "enabled")")
    }
}

extension Then where Subject == ProbeSnapshot {
    func holdsNoConsent() {
        expect(!subject.files.contains { $0.hasSuffix(Copy.consentFileName) }, "a consent record was saved")
    }

    func everyPatientHasPolicy(_ policy: String) {
        for patient in subject.patients {
            expectEqual(patient.consentPolicy, policy, "\(patient.name)'s consent policy")
        }
    }
}
