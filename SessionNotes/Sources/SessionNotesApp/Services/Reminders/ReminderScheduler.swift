import Foundation

/// Schedules a `ReminderDraft` into the user's Reminders. Thin by design; all
/// content/timing logic lives in the pure `SessionReminderBuilder`.
protocol ReminderScheduling {
    func schedule(_ draft: ReminderDraft) async throws
}

enum ReminderSchedulerError: LocalizedError {
    case accessDenied
    case unavailable

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Session Notes doesn't have permission to add Reminders. Turn it on in System Settings › Privacy & Security › Reminders."
        case .unavailable:
            return "Reminders aren't available on this system."
        }
    }
}

#if canImport(EventKit)
import EventKit

final class EventKitReminderScheduler: ReminderScheduling {
    private let store = EKEventStore()

    func schedule(_ draft: ReminderDraft) async throws {
        try await requestAccess()

        guard let calendar = store.defaultCalendarForNewReminders() else {
            throw ReminderSchedulerError.unavailable
        }

        let reminder = EKReminder(eventStore: store)
        reminder.calendar = calendar
        reminder.title = draft.title
        reminder.notes = draft.notes
        reminder.dueDateComponents = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: draft.dueDate
        )
        // An alarm makes it actually surface at the due time, not just appear
        // dated in the list.
        reminder.addAlarm(EKAlarm(absoluteDate: draft.dueDate))

        try store.save(reminder, commit: true)
    }

    private func requestAccess() async throws {
        let granted: Bool
        if #available(macOS 14.0, *) {
            granted = (try? await store.requestFullAccessToReminders()) ?? false
        } else {
            granted = await withCheckedContinuation { continuation in
                store.requestAccess(to: .reminder) { ok, _ in continuation.resume(returning: ok) }
            }
        }
        guard granted else { throw ReminderSchedulerError.accessDenied }
    }
}
#else
final class EventKitReminderScheduler: ReminderScheduling {
    func schedule(_ draft: ReminderDraft) async throws {
        throw ReminderSchedulerError.unavailable
    }
}
#endif
