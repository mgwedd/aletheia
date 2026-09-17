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

    static func summaryReady(patientName: String, date: Date) -> AppNotificationContent {
        AppNotificationContent(
            identifier: "summary-\(patientName)-\(date.timeIntervalSince1970)",
            title: "Summary ready",
            body: "The AI summary for \(patientName)'s \(dateFormatter.string(from: date)) session is ready to review."
        )
    }
}
