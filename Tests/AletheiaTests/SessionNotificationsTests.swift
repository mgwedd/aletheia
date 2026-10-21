import XCTest
@testable import Aletheia

final class SessionNotificationsTests: XCTestCase {
    private let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 9, day: 16))!

    // MARK: Private by default (lock-screen banners)

    func testGenericBannersCarryNoNameOrDate() {
        let all = [
            SessionNotifications.transcriptionComplete(patientName: "Jane Doe", date: date, showsName: false),
            SessionNotifications.transcriptionProblem(patientName: "Jane Doe", date: date, showsName: false),
            SessionNotifications.summaryReady(patientName: "Jane Doe", date: date, showsName: false),
            SessionNotifications.longRecordingReminder(patientName: "Jane Doe", showsName: false),
        ]
        for content in all {
            XCTAssertFalse(content.title.contains("Jane"), content.title)
            XCTAssertFalse(content.body.contains("Jane"), content.body)
            XCTAssertFalse(content.body.contains("2026"), content.body)
            XCTAssertFalse(content.body.contains("Sep"), content.body)
        }
    }

    func testIdentifiersNeverCarryTheName() {
        for showsName in [true, false] {
            let ids = [
                SessionNotifications.transcriptionComplete(patientName: "Jane Doe", date: date, showsName: showsName).identifier,
                SessionNotifications.transcriptionProblem(patientName: "Jane Doe", date: date, showsName: showsName).identifier,
                SessionNotifications.summaryReady(patientName: "Jane Doe", date: date, showsName: showsName).identifier,
                SessionNotifications.longRecordingReminder(patientName: "Jane Doe", showsName: showsName).identifier,
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
        let content = SessionNotifications.transcriptionComplete(patientName: "Jane Doe", date: date, showsName: true)
        XCTAssertEqual(content.title, "Transcript ready")
        XCTAssertTrue(content.body.contains("Jane Doe"))
        XCTAssertTrue(content.body.contains("2026"))
        XCTAssertTrue(content.identifier.hasPrefix("transcription-"))
    }

    func testTranscriptionProblemIsDistinctFromSuccess() {
        let content = SessionNotifications.transcriptionProblem(patientName: "Jane Doe", date: date, showsName: true)
        XCTAssertEqual(content.title, "Transcription needs attention")
        XCTAssertTrue(content.body.contains("Jane Doe"))
        XCTAssertNotEqual(
            content.identifier,
            SessionNotifications.transcriptionComplete(patientName: "Jane Doe", date: date, showsName: true).identifier
        )
    }

    func testSummaryReadyMentionsPatientWhenOptedIn() {
        let content = SessionNotifications.summaryReady(patientName: "John Smith", date: date, showsName: true)
        XCTAssertEqual(content.title, "Summary ready")
        XCTAssertTrue(content.body.contains("John Smith"))
        XCTAssertTrue(content.identifier.hasPrefix("summary-"))
    }

    func testIdentifiersAreStableForTheSameSession() {
        let a = SessionNotifications.transcriptionComplete(patientName: "Jane", date: date, showsName: false)
        let b = SessionNotifications.transcriptionComplete(patientName: "Jane", date: date, showsName: true)
        XCTAssertEqual(a.identifier, b.identifier)
    }

    // MARK: Call sites

    func testSystemNotificationsFollowTheSetting() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = [
            "Sources/App/Services/TranscriptionCoordinator.swift",
            "Sources/App/Views/SessionDetailView.swift",
            "Sources/App/AletheiaApp.swift",
        ]
        for path in files {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            XCTAssertTrue(source.contains("showsName: settings.notificationsShowPatientNames")
                          || source.contains("showsName: self.settings.notificationsShowPatientNames"), path)
            XCTAssertFalse(source.contains("showsName: true"), path)
        }
    }
}
