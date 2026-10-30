import XCTest
@testable import Aletheia

final class SessionNotificationsTests: XCTestCase {
    private let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 9, day: 16))!

    private let optedIn = PatientLabel.Policy(showFullName: true, isLocked: false)
    private let standard = PatientLabel.Policy(showFullName: false, isLocked: false)
    private let locked = PatientLabel.Policy(showFullName: true, isLocked: true)

    // MARK: Private by default (lock-screen banners)

    private func everyNotification(_ policy: PatientLabel.Policy, name: String = "Jane Doe") -> [AppNotificationContent] {
        [
            SessionNotifications.transcriptionComplete(patientName: name, date: date, policy: policy),
            SessionNotifications.transcriptionProblem(patientName: name, date: date, policy: policy),
            SessionNotifications.recordingNotDeleted(patientName: name, date: date, policy: policy),
            SessionNotifications.summaryReady(patientName: name, date: date, policy: policy),
            SessionNotifications.longRecordingReminder(patientName: name, policy: policy),
            SessionNotifications.exportReady(),
            SessionNotifications.exportFailed(),
        ]
    }

    private func assertIdentifiesNobody(_ content: AppNotificationContent, file: StaticString = #filePath, line: UInt = #line) {
        let text = [content.identifier, content.title, content.body].joined(separator: "\n")
        for token in ["Jane", "Doe", "J.D.", "J. D.", "JD", "2026", "Sep"] {
            XCTAssertFalse(text.contains(token), "\"\(content.title)\" contains \(token): \(text)", file: file, line: line)
        }
    }

    func testDefaultBannersNameNobodyNotEvenByInitials() {
        for content in everyNotification(standard) { assertIdentifiesNobody(content) }
    }

    func testTranscriptReadyCarriesNoInitialsByDefault() {
        let content = SessionNotifications.transcriptionComplete(patientName: "Jane Doe", date: date, policy: standard)
        XCTAssertEqual(content.title, "Transcript ready")
        XCTAssertEqual(content.body, "Your session has finished transcribing.")
    }

    func testLockedAppNamesNobodyEvenWhenOptedIn() {
        for content in everyNotification(locked) { assertIdentifiesNobody(content) }
    }

    func testBlankNameReadsAsClientWhenNamesAreOn() {
        let content = SessionNotifications.summaryReady(patientName: "  ", date: date, policy: optedIn)
        XCTAssertTrue(content.body.contains("Client"), content.body)
    }

    func testIdentifiersNeverCarryTheName() {
        for policy in [optedIn, standard, locked] {
            let ids = [
                SessionNotifications.transcriptionComplete(patientName: "Jane Doe", date: date, policy: policy).identifier,
                SessionNotifications.transcriptionProblem(patientName: "Jane Doe", date: date, policy: policy).identifier,
                SessionNotifications.recordingNotDeleted(patientName: "Jane Doe", date: date, policy: policy).identifier,
                SessionNotifications.summaryReady(patientName: "Jane Doe", date: date, policy: policy).identifier,
                SessionNotifications.longRecordingReminder(patientName: "Jane Doe", policy: policy).identifier,
            ]
            for id in ids { XCTAssertFalse(id.contains("Jane"), id) }
        }
    }

    func testTheSettingIsOffByDefault() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/App/Services/AppSettings.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains(
            "notificationsShowPatientNames = defaults.object(forKey: Keys.notificationsShowPatientNames) as? Bool ?? false"
        ))
    }

    // MARK: Names when the user opts in

    func testTranscriptionCompleteMentionsPatientAndDateWhenOptedIn() {
        let content = SessionNotifications.transcriptionComplete(patientName: "Jane Doe", date: date, policy: optedIn)
        XCTAssertEqual(content.title, "Transcript ready")
        XCTAssertTrue(content.body.contains("Jane Doe"))
        XCTAssertTrue(content.body.contains("2026"))
        XCTAssertTrue(content.identifier.hasPrefix("transcription-"))
    }

    func testTranscriptionProblemIsDistinctFromSuccess() {
        let content = SessionNotifications.transcriptionProblem(patientName: "Jane Doe", date: date, policy: optedIn)
        XCTAssertEqual(content.title, "Transcription needs attention")
        XCTAssertTrue(content.body.contains("Jane Doe"))
        XCTAssertNotEqual(
            content.identifier,
            SessionNotifications.transcriptionComplete(patientName: "Jane Doe", date: date, policy: optedIn).identifier
        )
    }

    func testSummaryReadyMentionsPatientWhenOptedIn() {
        let content = SessionNotifications.summaryReady(patientName: "John Smith", date: date, policy: optedIn)
        XCTAssertEqual(content.title, "Summary ready")
        XCTAssertTrue(content.body.contains("John Smith"))
        XCTAssertTrue(content.identifier.hasPrefix("summary-"))
    }

    func testIdentifiersAreStableForTheSameSession() {
        let a = SessionNotifications.transcriptionComplete(patientName: "Jane", date: date, policy: standard)
        let b = SessionNotifications.transcriptionComplete(patientName: "Jane", date: date, policy: optedIn)
        XCTAssertEqual(a.identifier, b.identifier)
    }

    // MARK: Call sites

    func testSystemNotificationsFollowTheSetting() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = [
            "Sources/App/Services/TranscriptionCoordinator.swift",
            "Sources/App/Services/SessionAI/SessionNoteModel.swift",
            "Sources/App/AletheiaApp.swift",
        ]
        for path in files {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            XCTAssertTrue(source.contains("showFullName: settings.notificationsShowPatientNames")
                          || source.contains("showFullName: self.settings.notificationsShowPatientNames"), path)
            XCTAssertFalse(source.contains("showFullName: true"), path)
        }
    }

    func testRecordingNotDeletedSaysTheTranscriptIsSaved() {
        let content = SessionNotifications.recordingNotDeleted(patientName: "Jane Doe", date: date, policy: optedIn)
        XCTAssertTrue(content.body.contains("Jane Doe"))
        XCTAssertTrue(content.body.contains("was transcribed"))
        XCTAssertFalse(content.body.contains("wasn't transcribed"))
    }

    func testPausedSummariesAlertNamesNoOne() {
        let content = SessionNotifications.transcriptionPausedWithWorkPending()
        XCTAssertTrue(content.title.localizedCaseInsensitiveContains("transcription"))
        XCTAssertTrue(content.title.localizedCaseInsensitiveContains("paused"))
        XCTAssertFalse((content.title + content.body).contains("Jane"))
    }
}
