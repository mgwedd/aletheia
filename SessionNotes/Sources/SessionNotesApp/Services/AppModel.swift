import Foundation

/// Thin coordinator between AppSettings (where is the data?) and Store (the
/// actual file I/O). Views read `patients` and call the mutating methods;
/// nothing here does its own persistence beyond what Store already does.
final class AppModel: ObservableObject {
    @Published var patients: [Patient] = []
    @Published var errorMessage: String?
    /// Set when the chosen data folder was written by a newer app version, so
    /// this build shouldn't modify it. Surfaced to the user as a warning.
    @Published var schemaWarning: String?

    private(set) var store: Store?
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
        rebuildStore()
    }

    func rebuildStore() {
        guard let root = settings.dataRootURL else {
            store = nil
            patients = []
            schemaWarning = nil
            return
        }
        let newStore = Store(root: root)
        store = newStore
        if case let .needsNewerApp(dataVersion, appVersion) = newStore.schemaCompatibility {
            schemaWarning = """
            This folder's data was created by a newer version of Session Notes \
            (data format v\(dataVersion); this copy understands v\(appVersion)). \
            Please update Session Notes before adding or changing anything here, \
            so none of your notes are lost.
            """
        } else {
            schemaWarning = nil
        }
        refreshPatients()
    }

    func refreshPatients() {
        guard let store else { return }
        do {
            patients = try store.listPatients()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func addPatient(name: String) -> Patient? {
        guard let store else { return nil }
        do {
            let patient = try store.createPatient(name: name)
            refreshPatients()
            return patient
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func savePatientNotes(_ patient: Patient) {
        guard let store else { return }
        do {
            try store.save(patient)
            refreshPatients()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
