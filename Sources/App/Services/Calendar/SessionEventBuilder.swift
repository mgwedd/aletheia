import Foundation

/// Recurrence cadence for scheduling repeating therapy sessions.
enum EventRecurrence: String, CaseIterable, Identifiable, Equatable {
    case never
    case weekly
    case everyTwoWeeks
    case everyFourWeeks
    case monthly

    var id: Self { self }

    var displayName: String {
        switch self {
        case .never: return "Never"
        case .weekly: return "Every week"
        case .everyTwoWeeks: return "Every 2 weeks"
        case .everyFourWeeks: return "Every 4 weeks"
        case .monthly: return "Every month"
        }
    }

    /// The iCalendar (RFC 5545) RRULE value, or nil if non-repeating.
    var rruleString: String? {
        switch self {
        case .never: return nil
        case .weekly: return "FREQ=WEEKLY"
        case .everyTwoWeeks: return "FREQ=WEEKLY;INTERVAL=2"
        case .everyFourWeeks: return "FREQ=WEEKLY;INTERVAL=4"
        case .monthly: return "FREQ=MONTHLY"
        }
    }
}

/// A calendar event to create for a session, ready for EventKit. Framework-free
/// so the title/timing logic is unit-tested without touching the real calendar.
struct EventDraft: Equatable {
    let title: String
    let notes: String
    let startDate: Date
    let endDate: Date
    var recurrence: EventRecurrence = .never
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
        recurrence: EventRecurrence = .never,
        calendar: Calendar = .current
    ) -> EventDraft {
        let end = calendar.date(byAdding: .minute, value: durationMinutes, to: start) ?? start
        return EventDraft(
            title: "Session with \(patientName)",
            notes: "Therapy session.",
            startDate: start,
            endDate: end,
            recurrence: recurrence
        )
    }
}

/// Generates standard iCalendar (.ics, RFC 5545) text for an `EventDraft`.
enum ICSExporter {
    static func escapeText(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\n")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    static func formatDate(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    static func generate(for draft: EventDraft, uid: String = UUID().uuidString, now: Date = Date()) -> String {
        var lines: [String] = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//Aletheia//Aletheia//EN",
            "CALSCALE:GREGORIAN",
            "METHOD:PUBLISH",
            "BEGIN:VEVENT",
            "UID:\(uid)@aletheia",
            "DTSTAMP:\(formatDate(now))",
            "DTSTART:\(formatDate(draft.startDate))",
            "DTEND:\(formatDate(draft.endDate))",
            "SUMMARY:\(escapeText(draft.title))"
        ]

        if !draft.notes.isEmpty {
            lines.append("DESCRIPTION:\(escapeText(draft.notes))")
        }

        if let rrule = draft.recurrence.rruleString {
            lines.append("RRULE:\(rrule)")
        }

        lines.append("END:VEVENT")
        lines.append("END:VCALENDAR")

        return lines.joined(separator: "\r\n") + "\r\n"
    }
}
