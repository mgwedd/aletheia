@testable import Aletheia
import Foundation
import XCTest

// MARK: - Subjects

/// A patient's sessions as the list shows them, top to bottom.
struct SessionList {
    let sessions: [SessionRecord]
    var folderNames: [String] { sessions.map(\.folderName) }
}

/// What the session list on a patient's page shows.
struct SessionListPage {
    let showsEmptyState: Bool
    let title: String
    let button: String
    /// Whether the session pane sits beside the list.
    let showsSessionPane: Bool
}

/// The divider between a patient's session list and the open session, dragged.
struct ColumnDrag {
    let pageWidth: CGFloat
    let listBefore: CGFloat
    let listAfter: CGFloat
    let listMinimum: CGFloat
    let sessionMinimum: CGFloat
    var sessionAfter: CGFloat { pageWidth - listAfter - 1 }
}

/// The result of clicking **New session**.
struct NewSessionAttempt {
    let session: SessionRecord?
    let notice: FileVaultNotice?
    let savedCount: Int
}

/// What the session row's badges are driven by.
struct SessionBadges: Equatable {
    let transcript: Bool
    let note: Bool
}

/// What an app-wide surface (Shortcuts, Calendar, Reminders) is offered in a build.
struct BuildSurfaces {
    let shortcutsActions: Bool
    let calendarScheduling: Bool
    let remindMe: Bool
}

/// The calendar event "Schedule Next Session" would create and the file it would save.
struct ScheduledSession {
    let draft: EventDraft
    let icsFile: String
    let patientName: String
}

/// The reminder "Remind Me" would create.
struct FollowUpReminder {
    let now: Date
    let draft: ReminderDraft
    let patientName: String
}

/// The sessions the "Show Today's Sessions" action reads out, and whether it would answer.
struct TodaysSessionsAnswer {
    let labels: [String]
    let refuses: Bool
}

// MARK: - Given

extension Given {
    /// A session on `patient` with the given amount of work done on it.
    @discardableResult
    func sessionToday(for patient: Patient, minutesAgo: Int = 0) throws -> SessionRecord {
        let store = try XCTUnwrap(app.appModel.store)
        let session = try store.createSession(for: patient, on: app.clock.now.addingTimeInterval(-Double(minutesAgo) * 60))
        app.appModel.refreshPatients()
        return session
    }
}

// MARK: - When

extension When {
    /// Clicks **New session** on the patient's page.
    @discardableResult
    func clickNewSession(for patient: Patient) throws -> SessionRecord {
        try XCTUnwrap(app.appModel.startNewSession(for: patient), "New session did not create a session")
    }

    /// Waits until the clock has moved on to a later second than `session` began in,
    /// as it has between two human clicks. Waits on the condition, up to a deadline.
    func waitUntilALaterSecondThan(_ session: SessionRecord) async throws {
        try await eventually(within: 5, "the clock to pass the second \(session.date) began in") {
            Date().timeIntervalSince1970.rounded(.down) > session.date.timeIntervalSince1970.rounded(.down)
        }
    }

    /// Opens a patient page and reads what the empty session list says.
    func openPatientPage(of patient: Patient) throws -> SessionListPage {
        let count = try XCTUnwrap(app.appModel.store).listSessions(for: patient).count
        return SessionListPage(
            showsEmptyState: SessionListEmptyState.isShown(sessionCount: count),
            title: SessionListEmptyState.title,
            button: SessionListEmptyState.newSessionButton,
            showsSessionPane: PatientPageLayout.showsSessionPane(sessionCount: count))
    }

    /// Drags the divider on a patient page `pageWidth` points wide by `points`
    /// (positive to the right), starting from the list's default width.
    func dragColumnDivider(by points: CGFloat, pageWidth: CGFloat = 1100) -> ColumnDrag {
        let before = PatientPageLayout.listWidth(proposed: PatientPageLayout.listIdealWidth, total: pageWidth)
        return ColumnDrag(
            pageWidth: pageWidth,
            listBefore: before,
            listAfter: PatientPageLayout.listWidth(proposed: before + points, total: pageWidth),
            listMinimum: PatientPageLayout.listMinWidth,
            sessionMinimum: PatientPageLayout.sessionMinWidth)
    }

    func tryNewSession(for patient: Patient) -> NewSessionAttempt {
        app.appModel.fileVaultNotice = nil
        let session = app.appModel.startNewSession(for: patient)
        let count = (try? app.appModel.store?.listSessions(for: patient).count) ?? 0
        return NewSessionAttempt(session: session, notice: app.appModel.fileVaultNotice, savedCount: count)
    }

    func listSessions(of patient: Patient) throws -> SessionList {
        SessionList(sessions: try XCTUnwrap(app.appModel.store).listSessions(for: patient))
    }

    func saveTranscript(_ text: String, for patient: Patient, session: SessionRecord) throws {
        try XCTUnwrap(app.appModel.store).saveTranscript(text, for: patient, session: session)
    }

    func saveNote(_ text: String, for patient: Patient, session: SessionRecord) throws {
        try XCTUnwrap(app.appModel.store).saveNote(text, for: patient, session: session, format: .soap)
    }

    func lookAtBadges(of session: SessionRecord, patient: Patient) throws -> SessionBadges {
        let all = try XCTUnwrap(app.appModel.store).listSessions(for: patient)
        let fresh = try XCTUnwrap(
            all.first { $0.id == session.id },
            "session is not listed: want \(session.id) \(session.folderName); got \(all.map { "\($0.id) \($0.folderName)" })")
        return SessionBadges(transcript: fresh.hasTranscript, note: fresh.hasSummary)
    }

    /// Clicks **Review in Settings…** on the set-aside recordings strip and reads
    /// which Settings page opens.
    func clickReviewInSettings() -> SettingsPane? {
        AppNavigator.shared.requestSettings(.setAsideRecordings)
        return AppNavigator.shared.takeSettingsRequest()?.pane
    }

    func searchShortcutsForAletheia() -> BuildSurfaces {
        let registry = app.appModel.featureRegistry
        return BuildSurfaces(
            shortcutsActions: registry.contains(id: "appIntents"),
            calendarScheduling: registry.contains(id: EventKitSchedulingFeatureModule.id),
            remindMe: registry.contains(id: EventKitSchedulingFeatureModule.id))
    }

    /// Schedules the next session repeating every week, with "Save an .ics file" ticked.
    func scheduleWeeklyNextSession(for patient: Patient) -> ScheduledSession {
        let start = SessionEventBuilder.suggestedStart(from: app.clock.now)
        let draft = SessionEventBuilder.draft(start: start, recurrence: .weekly)
        return ScheduledSession(draft: draft, icsFile: ICSExporter.generate(for: draft), patientName: patient.name)
    }

    /// Clicks **Remind Me** > Tomorrow on a session.
    func remindMeTomorrow(about session: SessionRecord, patient: Patient) -> FollowUpReminder {
        FollowUpReminder(
            now: app.clock.now,
            draft: SessionReminderBuilder.draft(sessionDate: session.date, leadTime: .tomorrow, now: app.clock.now),
            patientName: patient.name)
    }

    /// Runs "Show Today's Sessions".
    func askShortcutsForTodaysSessions(whileLocked locked: Bool = false) -> TodaysSessionsAnswer {
        SessionSearch.setAppLocked(locked)
        defer { SessionSearch.setAppLocked(false) }
        let items = SessionQueries.todaysSessions(now: app.clock.now, store: app.appModel.store)
        return TodaysSessionsAnswer(labels: items.map(\.label.text), refuses: SystemSurfaceAccess.isLocked)
    }
}

// MARK: - Then

extension Then where Subject == SessionListPage {
    func saysNoSessionsYetWithANewSessionButton() {
        expect(subject.showsEmptyState, "the empty state is not shown for a patient with no sessions")
        expectEqual(subject.title, "No Sessions Yet", "the empty state title")
        expectEqual(subject.button, "New session", "the button")
    }

    func showsNoEmptySessionPaneBesideIt() {
        expect(!subject.showsSessionPane, "an empty session pane sits beside a list with no sessions")
    }

    func showsTheSessionBesideTheList() {
        expect(subject.showsSessionPane, "no session pane beside a list with sessions")
    }
}

extension Then where Subject == ColumnDrag {
    func movesTheListBy(_ points: CGFloat) {
        expectEqual(subject.listAfter - subject.listBefore, points, "how far the list's edge moved")
    }

    func stopsBeforeEitherSideIsTooNarrow() {
        expect(subject.listAfter >= subject.listMinimum,
               "the list narrowed to \(subject.listAfter), under its \(subject.listMinimum)")
        expect(subject.sessionAfter >= subject.sessionMinimum,
               "the session narrowed to \(subject.sessionAfter), under its \(subject.sessionMinimum)")
    }
}

extension Then where Subject == SessionList {
    func hasSessions(_ count: Int) { expectEqual(subject.sessions.count, count, "sessions listed") }

    func listsNewestFirst(_ newestToOldest: [SessionRecord]) {
        expectEqual(subject.sessions.map(\.id), newestToOldest.map(\.id), "the sessions, newest first")
    }

    func eachShowsDateAndTime() {
        for session in subject.sessions {
            expect(session.date.timeIntervalSince1970 > 0, "session \(session.folderName) has no date")
        }
        expect(Set(subject.sessions.map(\.date)).count == subject.sessions.count,
               "expected each session to carry its own time, found duplicates")
    }
}

extension Then where Subject == SessionBadges {
    func showsTranscriptOnly() { expectEqual(subject, SessionBadges(transcript: true, note: false), "the badges") }
    func showsTranscriptAndNote() { expectEqual(subject, SessionBadges(transcript: true, note: true), "the badges") }
}

extension Then where Subject == SettingsPane? {
    func opensSetAsideRecordings() {
        expectEqual(subject, .setAsideRecordings, "the Settings page that opens")
        expectEqual(subject?.title, Copy.setAsideRecordingsPage, "the Settings page's title")
    }
}

extension Then where Subject == BuildSurfaces {
    func offersNoActions() {
        expect(!subject.shortcutsActions, "expected Shortcuts to offer no Aletheia actions in this build")
        expect(!subject.calendarScheduling, "expected no calendar scheduling in this build")
        expect(!subject.remindMe, "expected no Remind Me in this build")
    }

    func offersShortcutsAndScheduling() {
        expect(subject.shortcutsActions, "expected Shortcuts actions in this build")
        expect(subject.calendarScheduling, "expected calendar scheduling in this build")
        expect(subject.remindMe, "expected Remind Me in this build")
    }
}

extension Then where Subject == ScheduledSession {
    func repeatsWeekly() {
        expectEqual(subject.draft.recurrence, .weekly, "the repeat")
        expect(subject.icsFile.contains("RRULE:FREQ=WEEKLY"), "expected the .ics file to repeat weekly")
    }

    func namesNoPatient() {
        let parts = subject.patientName.split(separator: " ").map(String.init)
        for text in [subject.draft.title, subject.draft.notes, subject.icsFile] {
            for part in parts {
                expect(!text.localizedCaseInsensitiveContains(part), "expected no \"\(part)\" in the event, found it in: \(text)")
            }
        }
        expectEqual(subject.draft.title, Copy.therapySessionTitle, "the event title")
    }

    func savesAnIcsFile() {
        expect(subject.icsFile.hasPrefix("BEGIN:VCALENDAR") && subject.icsFile.contains("BEGIN:VEVENT"),
               "expected a calendar file with an event")
    }
}

extension Then where Subject == FollowUpReminder {
    func isTitledFollowUp() {
        expectEqual(subject.draft.title, Copy.followUpReminderTitle, "the reminder title")
    }

    func namesNoPatient() {
        for part in subject.patientName.split(separator: " ").map(String.init) {
            expect(!subject.draft.title.localizedCaseInsensitiveContains(part), "reminder title names \(part)")
            expect(!subject.draft.notes.localizedCaseInsensitiveContains(part), "reminder notes name \(part)")
        }
    }

    func isDueTomorrowAt9am() {
        let calendar = Calendar.current
        let hour = 9
        let expected = calendar.date(byAdding: .day, value: 1, to: subject.now)!
        expect(calendar.isDate(subject.draft.dueDate, inSameDayAs: expected), "expected the reminder due tomorrow")
        expectEqual(calendar.component(.hour, from: subject.draft.dueDate), hour, "the reminder's hour")
    }
}

extension Then where Subject == TodaysSessionsAnswer {
    func listsByInitials(_ labels: [String]) { expectEqual(subject.labels, labels, "the sessions read out") }

    func neverReadsAName(_ names: [String]) {
        for label in subject.labels {
            for name in names {
                expect(!label.contains(name), "expected initials only, found \(label)")
            }
        }
    }

    func refuses() { expect(subject.refuses, "expected the action to refuse while Aletheia is locked") }
    func answers() { expect(!subject.refuses, "expected the action to answer while unlocked") }
}

extension Then where Subject == NewSessionAttempt {
    func wasBlockedByFileVault() {
        expect(subject.session == nil, "expected no session to be created while FileVault is off")
        expectEqual(subject.notice?.title, Copy.turnOnFileVault, "the alert title")
        expectEqual(subject.savedCount, 0, "sessions saved")
    }
}
