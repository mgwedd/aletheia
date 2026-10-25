import XCTest

final class NotifySpec: AcceptanceCase {
    func test_NOTIFY_01() async throws {
        try pending("Transcription runs through the concrete Integrations notifier and Whisper with no injection seam; the permission prompt is an OS dialog that needs a UI driver")
    }

    func test_NOTIFY_02() async throws {
        let shown = when.transcriptionFinishes(for: "Jane Doe")

        then(shown).isTitled(Copy.notifyTranscriptReady)
        then(shown).namesNoPatient("Jane Doe")
    }

    func test_NOTIFY_03() async throws {
        let shown = when.transcriptionOfSilenceFinishes(for: "Jane Doe")

        then(shown).isTitled(Copy.notifyNeedsAttention)
    }

    func test_NOTIFY_04() async throws {
        let shown = when.noteIsGenerated(for: "Jane Doe")

        then(shown).isTitled(Copy.notifySummaryReady)
    }

    func test_NOTIFY_05() async throws {
        let jane = try await given.patient(named: "Jane Doe")
        try given.exportSession(for: jane)

        let shown = try await when.exportFinishes()

        then(shown).isTitled(Copy.notifyExportReady)
        then(shown).namesNoPatient("Jane Doe")
    }

    func test_NOTIFY_06() async throws {
        given.showPatientNamesInNotifications(true)

        let shown = when.transcriptionFinishes(for: "Jane Doe")

        then(shown).namesPatientInFull("Jane Doe")
    }

    func test_NOTIFY_07() async throws {
        let jane = try await given.patient(named: "Jane Doe")
        try given.exportSession(for: jane)

        let shown = try await when.everyNotificationIsShown(for: "Jane Doe")

        then(shown).namePatientNowhere("Jane Doe")
    }

    func test_NOTIFY_08() async throws {
        addTeardownBlock { @MainActor in self.given.appIsUnlocked() }
        given.showPatientNamesInNotifications(true)
        given.appIsLocked()

        let shown = when.transcriptionFinishes(for: "Jane Doe")

        then([shown]).namePatientNowhere("Jane Doe")
    }
}
