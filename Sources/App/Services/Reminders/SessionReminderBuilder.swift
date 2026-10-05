import Foundation

/// The content of a follow-up reminder, ready to hand to EventKit. Framework-
/// free so the "what does the reminder say / when is it due" logic is
/// unit-tested without touching the user's real Reminders database.
struct ReminderDraft: Equatable {
    let title: String
    let notes: String
    let dueDate: Date
}

/// How far out to schedule a session follow-up. Kept small and concrete so the
/// therapist picks from plain choices rather than a date picker.
enum ReminderLeadTime: String, CaseIterable, Identifiable {
    case tomorrow
    case inThreeDays
    case nextWeek

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tomorrow: return "Tomorrow"
        case .inThreeDays: return "In 3 days"
        case .nextWeek: return "Next week"
        }
    }

    private var dayOffset: Int {
        switch self {
        case .tomorrow: return 1
        case .inThreeDays: return 3
        case .nextWeek: return 7
        }
    }

    /// The due moment: 9:00 AM on the offset day, in the given calendar.
    func dueDate(from now: Date, calendar: Calendar = .current) -> Date {
        let day = calendar.date(byAdding: .day, value: dayOffset, to: now) ?? now
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
    }
}

enum SessionReminderBuilder {
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        return f
    }()

    /// A follow-up reminder for a session. The title names the patient (this
    /// goes into the user's own Reminders, at their request); the notes carry
    /// the session date for context.
    static func draft(
        patientName: String,
        sessionDate: Date,
        leadTime: ReminderLeadTime,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ReminderDraft {
        ReminderDraft(
            title: "Follow up: \(patientName)",
            notes: "Re: therapy session on \(dateFormatter.string(from: sessionDate)).",
            dueDate: leadTime.dueDate(from: now, calendar: calendar)
        )
    }
}
