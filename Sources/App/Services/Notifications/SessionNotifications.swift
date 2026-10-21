import Foundation

/// Builds the notification content for the app's completion events. Pure
/// functions so the wording and identifiers are unit-testable without the
/// UserNotifications framework.
enum SessionNotifications {
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    static func transcriptionComplete(patientName: String, date: Date) -> AppNotificationContent {
        AppNotificationContent(
            identifier: "transcription-\(patientName)-\(date.timeIntervalSince1970)",
            title: "Transcript ready",
            body: "\(patientName)'s session from \(dateFormatter.string(from: date)) has finished transcribing."
        )
    }

    /// A transcription that failed or found no speech, so someone who stepped
    /// away isn't left assuming the transcript is on its way.
    static func transcriptionProblem(patientName: String, date: Date) -> AppNotificationContent {
        AppNotificationContent(
            identifier: "transcription-problem-\(patientName)-\(date.timeIntervalSince1970)",
            title: "Transcription needs attention",
            body: "\(patientName)'s session from \(dateFormatter.string(from: date)) wasn't transcribed. Open the session to see why."
        )
    }

    static func summaryReady(patientName: String, date: Date) -> AppNotificationContent {
        AppNotificationContent(
            identifier: "summary-\(patientName)-\(date.timeIntervalSince1970)",
            title: "Summary ready",
            body: "The AI summary for \(patientName)'s \(dateFormatter.string(from: date)) session is ready to review."
        )
    }

    static func longRecordingReminder(patientName: String) -> AppNotificationContent {
        AppNotificationContent(
            identifier: "long-recording-\(patientName)",
            title: "Still recording",
            body: "\(patientName)'s session has been recording for over 90 minutes. Did you forget to end it?"
        )
    }

    /// The records export finished. Deliberately generic: a notification can show
    /// on a locked screen, so it never names the patient or the contents.
    static func exportReady() -> AppNotificationContent {
        AppNotificationContent(
            identifier: "records-export",
            title: "Export ready",
            body: "Your records export is ready in Aletheia."
        )
    }

    static func exportFailed() -> AppNotificationContent {
        AppNotificationContent(
            identifier: "records-export",
            title: "Export didn't finish",
            body: "Open Aletheia to see why."
        )
    }
}
