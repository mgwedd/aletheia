import XCTest

/// The consent sheets in the real app. Only steps that start no recording and
/// open no system panel are driven here; the rest is in the acceptance suite.
final class ConsentUITests: AcceptanceCase {
    func test_CONSENT_01() {
        given.janeAndAdamWithASessionEach()
        when.openFirstSession(of: "Jane Doe")

        let sheet = when.pressRecordSession()

        then(sheet).isShown()
        then(sheet).confirmIsEnabled(false)
        when.tickConfirmation(on: sheet)
        then(sheet).confirmIsEnabled(true)
        when.cancel(sheet)
        then(sheet).isClosed()
        then(app.probe).holdsNoConsent()
    }

    func test_CONSENT_05() {
        given.janeAndAdamWithASessionEach()
        when.openFirstSession(of: "Jane Doe")

        let sheet = when.pressImportAudio()

        then(sheet).isShown()
        then(sheet).confirmIsEnabled(false)
        when.cancel(sheet)
        then(sheet).isClosed()
        then(app.probe).holdsNoConsent()
    }

    func test_CONSENT_08() {
        given.janeAndAdamWithASessionEach()

        let sheet = when.openApplyToPatients()

        then(sheet).applyIsEnabled(false)
        when.applyEverySessionToAll(on: sheet)
        then(app.waitForProbe { $0.patients.allSatisfy { $0.consentPolicy == "everySession" } })
            .everyPatientHasPolicy("everySession")
    }

    func test_CONSENT_13_narrowWindowWrapsTheConsentLine() {
        given.janeWithConsentRecorded()
        let wide = when.readConsentLine()
        let wideHeight = wide.line.frame.height

        when.narrowWindow(to: 900)

        then(wide).wrapsOnto(moreLinesThan: wideHeight)
    }
}
