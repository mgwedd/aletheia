import XCTest

final class SessionSpec: AcceptanceCase {
    func test_SESSION_01() async throws {
        let jane = try await given.patient(named: "Jane Doe")

        then(try when.openPatientPage(of: jane)).saysNoSessionsYetWithANewSessionButton()
    }

    func test_SESSION_02() async throws {
        let jane = try await given.patient(named: "Jane Doe")

        let first = try when.clickNewSession(for: jane)
        try await when.waitUntilALaterSecondThan(first)
        let second = try when.clickNewSession(for: jane)

        let list = try when.listSessions(of: jane)
        then(list).hasSessions(2)
        then(list).listsNewestFirst([second, first])
        then(list).eachShowsDateAndTime()
    }

    func test_SESSION_03() async throws {
        // The "Recording in progress" and "Transcribing…" row text comes from live view state
        // (private SessionRow); this drives the Transcript and Note badges.
        let jane = try await given.patient(named: "Jane Doe")
        let session = try when.clickNewSession(for: jane)

        try when.saveTranscript("Hello, how have you been this week?", for: jane, session: session)
        then(try when.lookAtBadges(of: session, patient: jane)).showsTranscriptOnly()

        try when.saveNote("Client reports improved mood.", for: jane, session: session)
        then(try when.lookAtBadges(of: session, patient: jane)).showsTranscriptAndNote()
    }

    func test_SESSION_04() async throws {
        then(when.clickReviewInSettings()).opensSetAsideRecordings()
    }

    func test_SESSION_05() async throws {
        given.buildIs(.release)

        then(when.searchShortcutsForAletheia()).offersNoActions()
    }

    func test_SESSION_06() async throws {
        given.buildIs(.dev)
        let jane = try await given.patient(named: "Jane Doe")

        let scheduled = when.scheduleWeeklyNextSession(for: jane)

        then(when.searchShortcutsForAletheia()).offersShortcutsAndScheduling()
        then(scheduled).repeatsWeekly()
        then(scheduled).namesNoPatient()
        then(scheduled).savesAnIcsFile()
    }

    func test_SESSION_07() async throws {
        given.buildIs(.dev)
        let jane = try await given.patient(named: "Jane Doe")
        let session = try when.clickNewSession(for: jane)

        let reminder = when.remindMeTomorrow(about: session, patient: jane)

        then(when.searchShortcutsForAletheia()).offersShortcutsAndScheduling()
        then(reminder).isTitledFollowUp()
        then(reminder).namesNoPatient()
        then(reminder).isDueTomorrowAt9am()
    }

    func test_SESSION_08() async throws {
        given.buildIs(.dev)
        let jane = try await given.patient(named: "Jane Doe")
        let adam = try await given.patient(named: "Adam Lee")
        try given.sessionToday(for: jane, minutesAgo: 5)
        try given.sessionToday(for: adam)

        let answer = when.askShortcutsForTodaysSessions()
        then(answer).listsByInitials(["A.L.", "J.D."])
        then(answer).neverReadsAName(["Jane", "Doe", "Adam", "Lee"])
        then(answer).answers()

        then(when.askShortcutsForTodaysSessions(whileLocked: true)).refuses()
    }

    func test_SESSION_09() async throws {
        let jane = try await given.patient(named: "Jane Doe")

        given.fileVaultIsOff()

        let attempt = when.tryNewSession(for: jane)

        then(attempt).wasBlockedByFileVault()
    }
}
