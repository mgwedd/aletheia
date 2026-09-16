import Foundation

/// Thin coordinator between AppSettings (where is the data?) and Store (the
/// actual file I/O). Views read `patients` and call the mutating methods;
/// nothing here does its own persistence beyond what Store already does.
final class AppModel: ObservableObject {
    @Published var patients: [Patient] = []
    @Published var errorMessage: String?

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
            return
        }
        store = Store(root: root)
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
