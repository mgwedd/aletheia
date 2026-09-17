import AppIntents

/// "Show today's sessions" — read-only, returns spoken/displayed dialog.
struct ShowTodaysSessionsIntent: AppIntent {
    static var title: LocalizedStringResource = "Show Today's Sessions"
    static var description = IntentDescription("Lists the therapy sessions recorded today.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let items = SessionQueries.todaysSessions(store: SessionQueries.currentStore())
        guard !items.isEmpty else {
            return .result(dialog: "You have no sessions recorded today.")
        }
        let names = items.map(\.patientName).joined(separator: ", ")
        let count = items.count
        return .result(dialog: "You have \(count) session\(count == 1 ? "" : "s") today: \(names).")
    }
}

/// "Open [patient]" — brings the app forward on that patient.
struct OpenPatientIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Patient"
    static var description = IntentDescription("Opens Aletheia to a patient.")
    static var openAppWhenRun = true

    @Parameter(title: "Patient")
    var patient: PatientEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        AppNavigator.shared.requestOpen(patientID: patient.id)
        return .result()
    }
}

/// "New session for [patient]" — creates the session folder and opens the
/// patient so she just has to press Record.
struct NewSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "New Session"
    static var description = IntentDescription("Starts a new session for a patient.")
    static var openAppWhenRun = true

    @Parameter(title: "Patient")
    var patient: PatientEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let store = SessionQueries.currentStore() else {
            return .result(dialog: "Open Aletheia and choose a data folder first.")
        }
        let patients = (try? store.listPatients()) ?? []
        guard let match = patients.first(where: { $0.id == patient.id }) else {
            return .result(dialog: "I couldn't find that patient.")
        }
        _ = try store.createSession(for: match)
        AppNavigator.shared.requestOpen(patientID: match.id)
        return .result(dialog: "Started a new session for \(match.name).")
    }
}

struct SessionNotesShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ShowTodaysSessionsIntent(),
            phrases: [
                "Show today's sessions in \(.applicationName)",
                "What sessions do I have today in \(.applicationName)"
            ],
            shortTitle: "Today's Sessions",
            systemImageName: "calendar"
        )
    }
}
