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
            return "Aletheia doesn't have permission to add Reminders. Turn it on in System Settings › Privacy & Security › Reminders."
        case .unavailable:
            return "Reminders aren't available on this system."
        }
    }
}

/// Where reminders actually land: the user's Reminders in production, a fake
/// in tests.
protocol ReminderStore {
    /// Whether the user has let Aletheia add reminders (asking if undecided).
    func requestAccess() async -> Bool
    /// Adds the reminder; throws `ReminderSchedulerError.unavailable` if there
    /// is nowhere to put it.
    func add(_ draft: ReminderDraft) throws
}

final class EventKitReminderScheduler: ReminderScheduling {
    private let store: ReminderStore

    init(store: ReminderStore = EventKitReminderStore()) {
        self.store = store
    }

    func schedule(_ draft: ReminderDraft) async throws {
        guard await store.requestAccess() else { throw ReminderSchedulerError.accessDenied }
        try store.add(draft)
    }
}

#if canImport(EventKit)
import EventKit

final class EventKitReminderStore: ReminderStore {
    private let store = EKEventStore()

    func requestAccess() async -> Bool {
        if #available(macOS 14.0, *) {
            return (try? await store.requestFullAccessToReminders()) ?? false
        }
        return await withCheckedContinuation { continuation in
            store.requestAccess(to: .reminder) { ok, _ in continuation.resume(returning: ok) }
        }
    }

    func add(_ draft: ReminderDraft) throws {
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
}
#else
final class EventKitReminderStore: ReminderStore {
    func requestAccess() async -> Bool { false }
    func add(_ draft: ReminderDraft) throws { throw ReminderSchedulerError.unavailable }
}
#endif
