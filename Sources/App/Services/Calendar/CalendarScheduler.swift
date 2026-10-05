import Foundation

/// Creates an `EventDraft` in the user's calendar. Thin by design; all
/// content/timing logic lives in the pure `SessionEventBuilder`.
protocol CalendarScheduling {
    func schedule(_ draft: EventDraft) async throws
}

enum CalendarSchedulerError: LocalizedError {
    case accessDenied
    case unavailable

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Aletheia doesn't have permission to add Calendar events. Turn it on in System Settings › Privacy & Security › Calendars."
        case .unavailable:
            return "No calendar is available to add the event to."
        }
    }
}

#if canImport(EventKit)
import EventKit

final class EventKitCalendarScheduler: CalendarScheduling {
    private let store = EKEventStore()

    func schedule(_ draft: EventDraft) async throws {
        try await requestAccess()

        guard let calendar = store.defaultCalendarForNewEvents else {
            throw CalendarSchedulerError.unavailable
        }

        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = draft.title
        event.notes = draft.notes
        event.startDate = draft.startDate
        event.endDate = draft.endDate

        try store.save(event, span: .thisEvent, commit: true)
    }

    private func requestAccess() async throws {
        let granted: Bool
        if #available(macOS 14.0, *) {
            granted = (try? await store.requestFullAccessToEvents()) ?? false
        } else {
            granted = await withCheckedContinuation { continuation in
                store.requestAccess(to: .event) { ok, _ in continuation.resume(returning: ok) }
            }
        }
        guard granted else { throw CalendarSchedulerError.accessDenied }
    }
}
#else
final class EventKitCalendarScheduler: CalendarScheduling {
    func schedule(_ draft: EventDraft) async throws {
        throw CalendarSchedulerError.unavailable
    }
}
#endif
