import Foundation
#if canImport(EventKit)
import EventKit
#endif

/// Calendar/Reminders access, checked without prompting and requested with a
/// single prompt — the same shape as the Screen Recording helper. Setup uses
/// this to ask up front (so the therapist grants everything once), and the
/// checklist reads the status without nagging. These features are optional:
/// declining only turns off "Schedule Next Session" / "Remind Me".
enum EventKitAccess {
    enum Feature {
        case calendar
        case reminders
    }

    enum Status: Equatable {
        case granted
        case notDetermined
        case denied
        case unavailable
    }

    /// Current authorization, without ever showing a prompt.
    static func status(_ feature: Feature) -> Status {
        #if canImport(EventKit)
        switch EKEventStore.authorizationStatus(for: entityType(feature)) {
        case .notDetermined:
            return .notDetermined
        case .denied, .restricted:
            return .denied
        case .authorized, .fullAccess, .writeOnly:
            return .granted
        @unknown default:
            return .denied
        }
        #else
        return .unavailable
        #endif
    }

    /// Ask for access with a single system prompt (only shown when the state is
    /// undetermined; a prior denial returns false without re-prompting, and the
    /// caller falls back to opening System Settings).
    @discardableResult
    static func request(_ feature: Feature) async -> Bool {
        #if canImport(EventKit)
        let store = EKEventStore()
        if #available(macOS 14.0, *) {
            switch feature {
            case .calendar:
                return (try? await store.requestFullAccessToEvents()) ?? false
            case .reminders:
                return (try? await store.requestFullAccessToReminders()) ?? false
            }
        } else {
            return await withCheckedContinuation { continuation in
                store.requestAccess(to: entityType(feature)) { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
        }
        #else
        return false
        #endif
    }

    #if canImport(EventKit)
    private static func entityType(_ feature: Feature) -> EKEntityType {
        feature == .calendar ? .event : .reminder
    }
    #endif
}
