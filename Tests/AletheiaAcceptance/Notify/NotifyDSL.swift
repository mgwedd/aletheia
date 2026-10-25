@testable import Aletheia
import Foundation
import XCTest

// MARK: - Subjects

/// A notification as it would be shown.
struct ShownNotification {
    let content: AppNotificationContent
    var everything: String { [content.identifier, content.title, content.body].joined(separator: "\n") }
}

// MARK: - Given

extension Given {
    func showPatientNamesInNotifications(_ on: Bool) { app.settings.notificationsShowPatientNames = on }
    func appIsLocked() { SessionSearch.setAppLocked(true) }
    func appIsUnlocked() { SessionSearch.setAppLocked(false) }
}

// MARK: - When

extension When {
    private var notificationPolicy: PatientLabel.Policy {
        PatientLabel.Policy.current(showFullName: app.settings.notificationsShowPatientNames)
    }

    func transcriptionFinishes(for patientName: String) -> ShownNotification {
        ShownNotification(content: SessionNotifications.transcriptionComplete(
            patientName: patientName, date: app.clock.now, policy: notificationPolicy))
    }

    func transcriptionOfSilenceFinishes(for patientName: String) -> ShownNotification {
        ShownNotification(content: SessionNotifications.transcriptionProblem(
            patientName: patientName, date: app.clock.now, policy: notificationPolicy))
    }

    func noteIsGenerated(for patientName: String) -> ShownNotification {
        ShownNotification(content: SessionNotifications.summaryReady(
            patientName: patientName, date: app.clock.now, policy: notificationPolicy))
    }

    /// Every notification the app shows for one patient: transcript ready, needs attention, note ready, export ready.
    func everyNotificationIsShown(for patientName: String) async throws -> [ShownNotification] {
        let exported = try await exportFinishes()
        return [transcriptionFinishes(for: patientName), transcriptionOfSilenceFinishes(for: patientName),
                noteIsGenerated(for: patientName), exported]
    }

    /// Runs a real export to completion and returns what it asked the system to show.
    func exportFinishes() async throws -> ShownNotification {
        let run = try exportAllRecords()
        await waitForExport(run)
        return ShownNotification(content: try XCTUnwrap(run.postedNotifications.first, "no notification was posted"))
    }
}

// MARK: - Then

extension Then where Subject == ShownNotification {
    func isTitled(_ title: String) { expectEqual(subject.content.title, title, "the notification title") }

    func namesNoPatient(_ name: String) {
        subject.expectIdentifiesNobody(name)
    }

    func namesPatientInFull(_ name: String) {
        expect(subject.content.body.contains(name), "expected \"\(name)\" in the body, it reads:\n\(subject.content.body)")
    }
}

extension ShownNotification {
    /// No part of the name, and no initials, appear anywhere in the notification.
    func expectIdentifiesNobody(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let parts = name.split(separator: " ").map(String.init)
        let initials = parts.compactMap(\.first).map { "\($0)." }
        let spelled = [initials.joined(), initials.joined(separator: " "), parts.compactMap(\.first).map(String.init).joined()]
        for token in parts + spelled where everything.contains(token) {
            XCTFail("\"\(content.title)\" identifies the patient (contains \"\(token)\"):\n\(everything)", file: file, line: line)
            return
        }
    }
}

extension Then where Subject == [ShownNotification] {
    func namePatientNowhere(_ name: String) {
        for shown in subject { shown.expectIdentifiesNobody(name) }
    }
}
