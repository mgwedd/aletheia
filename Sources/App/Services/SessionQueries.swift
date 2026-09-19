import Foundation

struct SessionSummaryItem: Equatable {
    let patientName: String
    let date: Date
}

/// Read-only queries used by App Intents (and available for reuse). Kept
/// separate from the store so the date logic is testable with an injected
/// store, and so the intent layer stays thin.
enum SessionQueries {
    /// Sessions dated today, across all patients, newest first.
    static func todaysSessions(now: Date = Date(), store: Store?) -> [SessionSummaryItem] {
        guard let store else { return [] }
        let calendar = Calendar.current
        var items: [SessionSummaryItem] = []
        for patient in (try? store.listPatients()) ?? [] {
            for session in (try? store.listSessions(for: patient)) ?? [] where calendar.isDate(session.date, inSameDayAs: now) {
                items.append(SessionSummaryItem(patientName: patient.name, date: session.date))
            }
        }
        return items.sorted { $0.date > $1.date }
    }

    /// Builds a store from the currently configured data folder, if any.
    static func currentStore() -> Store? {
        guard let root = AppSettings.shared.dataRootURL else { return nil }
        return Store(root: root)
    }
}
