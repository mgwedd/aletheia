import Foundation

/// Builds the notification content for the app's completion events. Pure
/// functions so the wording and identifiers are unit-testable without the
/// UserNotifications framework.
///
/// Banners show on the lock screen and are kept by macOS, so by default they
/// carry no patient name or session date (`showsName: false`). Names appear
/// only when the user turns on "Show patient names in notifications".
/// Identifiers never carry a name, whatever the setting.
enum SessionNotifications {
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    static func transcriptionComplete(patientName: String, date: Date, showsName: Bool) -> AppNotificationContent {
        AppNotificationContent(
            identifier: "transcription-\(date.timeIntervalSince1970)",
            title: "Transcript ready",
            body: showsName
                ? "\(patientName)'s session from \(dateFormatter.string(from: date)) has finished transcribing."
                : "A session has finished transcribing. Open Aletheia to see it."
        )
    }

    /// A transcription that failed or found no speech, so someone who stepped
    /// away isn't left assuming the transcript is on its way.
    static func transcriptionProblem(patientName: String, date: Date, showsName: Bool) -> AppNotificationContent {
        AppNotificationContent(
            identifier: "transcription-problem-\(date.timeIntervalSince1970)",
            title: "Transcription needs attention",
            body: showsName
                ? "\(patientName)'s session from \(dateFormatter.string(from: date)) wasn't transcribed. Open the session to see why."
                : "A session wasn't transcribed. Open Aletheia to see why."
        )
    }

    static func summaryReady(patientName: String, date: Date, showsName: Bool) -> AppNotificationContent {
        AppNotificationContent(
            identifier: "summary-\(date.timeIntervalSince1970)",
            title: "Summary ready",
            body: showsName
                ? "The AI summary for \(patientName)'s \(dateFormatter.string(from: date)) session is ready to review."
                : "An AI summary is ready to review in Aletheia."
        )
    }

    static func longRecordingReminder(patientName: String, showsName: Bool) -> AppNotificationContent {
        AppNotificationContent(
            identifier: "long-recording",
            title: "Still recording",
            body: showsName
                ? "\(patientName)'s session has been recording for over 90 minutes. Did you forget to end it?"
                : "A session has been recording for over 90 minutes. Did you forget to end it?"
        )
    }
}
