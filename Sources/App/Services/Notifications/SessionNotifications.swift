import Foundation

/// Builds the notification content for the app's completion events. Pure
/// functions so the wording and identifiers are unit-testable without the
/// UserNotifications framework.
///
/// Banners show on the lock screen and are kept by macOS, so by default they
/// say only "your session": no name, no initials, no session date. The full name and date
/// appear only when the user turns on "Show patient names in notifications" and
/// the app is unlocked; `PatientLabel` makes that call. Identifiers never carry
/// a name, whatever the setting.
enum SessionNotifications {
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    /// The label for `patientName` and whether it is the full name (so the date
    /// may be shown too).
    private static func label(_ name: String, _ policy: PatientLabel.Policy) -> (text: String, full: Bool) {
        (PatientLabel.text(forName: name, surface: .notification, policy: policy),
         PatientLabel.showsFullName(surface: .notification, policy: policy))
    }

    private static func sessionPhrase(_ name: String, date: Date, _ policy: PatientLabel.Policy) -> String {
        let l = label(name, policy)
        return l.full ? "\(l.text)'s session from \(dateFormatter.string(from: date))" : "Your session"
    }

    static func transcriptionComplete(patientName: String, date: Date, policy: PatientLabel.Policy) -> AppNotificationContent {
        AppNotificationContent(
            identifier: "transcription-\(date.timeIntervalSince1970)",
            title: "Transcript ready",
            body: "\(sessionPhrase(patientName, date: date, policy)) has finished transcribing."
        )
    }

    /// A transcription that failed or found no speech, so someone who stepped
    /// away isn't left assuming the transcript is on its way.
    static func transcriptionProblem(patientName: String, date: Date, policy: PatientLabel.Policy) -> AppNotificationContent {
        AppNotificationContent(
            identifier: "transcription-problem-\(date.timeIntervalSince1970)",
            title: "Transcription needs attention",
            body: "\(sessionPhrase(patientName, date: date, policy)) wasn't transcribed. Open the session to see why."
        )
    }

    /// The transcript was saved, but the recording that should have been
    /// deleted afterwards is still on disk.
    static func recordingNotDeleted(patientName: String, date: Date, policy: PatientLabel.Policy) -> AppNotificationContent {
        AppNotificationContent(
            identifier: "recording-kept-\(date.timeIntervalSince1970)",
            title: "Recording still on disk",
            body: "\(sessionPhrase(patientName, date: date, policy)) was transcribed, but its recording couldn't be deleted. Open the session to see why."
        )
    }

    static func summaryReady(patientName: String, date: Date, policy: PatientLabel.Policy) -> AppNotificationContent {
        AppNotificationContent(
            identifier: "summary-\(date.timeIntervalSince1970)",
            title: "Summary ready",
            body: "The AI summary for \(label(patientName, policy).full ? sessionPhrase(patientName, date: date, policy) : "your session") is ready to review in Aletheia."
        )
    }

    static func longRecordingReminder(patientName: String, policy: PatientLabel.Policy) -> AppNotificationContent {
        AppNotificationContent(
            identifier: "long-recording",
            title: "Still recording",
            body: "\(label(patientName, policy).full ? "\(label(patientName, policy).text)'s session" : "Your session") has been recording for over 90 minutes. Did you forget to end it?"
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

    /// A recording ended while the user's own pause on summaries is still on and
    /// summaries are waiting. Generic: it never names the patient.
    static func transcriptionPausedWithWorkPending() -> AppNotificationContent {
        AppNotificationContent(
            identifier: "digest-paused",
            title: "Transcription is paused with summaries waiting",
            body: "You paused summaries, so they stay paused. Press Resume on the patient's page to prepare them."
        )
    }
}
