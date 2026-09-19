import Foundation

/// A calendar event to create for a session, ready for EventKit. Framework-free
/// so the title/timing logic is unit-tested without touching the real calendar.
struct EventDraft: Equatable {
    let title: String
    let notes: String
    let startDate: Date
    let endDate: Date
}

enum SessionEventBuilder {
    /// A standard therapy hour.
    static let defaultDurationMinutes = 50

    /// A sensible default for a "next session" the user then adjusts: one week
    /// out at 9:00 AM.
    static func suggestedStart(from now: Date = Date(), calendar: Calendar = .current) -> Date {
        let nextWeek = calendar.date(byAdding: .day, value: 7, to: now) ?? now
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: nextWeek) ?? nextWeek
    }

    static func draft(
        patientName: String,
        start: Date,
        durationMinutes: Int = defaultDurationMinutes,
        calendar: Calendar = .current
    ) -> EventDraft {
        let end = calendar.date(byAdding: .minute, value: durationMinutes, to: start) ?? start
        return EventDraft(
            title: "Session with \(patientName)",
            notes: "Therapy session.",
            startDate: start,
            endDate: end
        )
    }
}
