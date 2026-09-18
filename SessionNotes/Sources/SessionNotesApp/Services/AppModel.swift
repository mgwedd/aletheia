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
    /// Local SQLite store for the therapist's own annotations (inline comments
    /// and freeform session notes), living inside the chosen data folder.
    private(set) var commentStore: CommentStore?
    private let settings: AppSettings
    /// Supplies the `FileProtector` the stores read/write through. When
    /// encryption is off or locked it's a passthrough, so the stores behave as
    /// they always have.
    private let encryption: EncryptionManager
    private let spotlightIndexer: SpotlightIndexing

    init(settings: AppSettings, encryption: EncryptionManager, spotlightIndexer: SpotlightIndexing = SpotlightIndexer.shared) {
        self.settings = settings
        self.encryption = encryption
        self.spotlightIndexer = spotlightIndexer
        rebuildStore()
        // Rebuild the stores with a fresh protector whenever encryption is
        // enabled, unlocked, or locked, so reads/writes pick up the key change.
        encryption.onProtectionChanged = { [weak self] in self?.rebuildStore() }
    }

    /// The protector the stores are currently using — for callers that seal or
    /// open PHI outside the stores (the recorder's audio; transcription's
    /// decrypt-to-temp).
    var currentProtector: FileProtector { encryption.protector }

    func rebuildStore() {
        // Recompute encryption state first (the data folder may have just
        // changed), then build the stores around the resulting protector.
        encryption.refresh()
        guard let root = settings.dataRootURL else {
            store = nil
            commentStore = nil
            patients = []
            schemaWarning = nil
            return
        }
        let protector = encryption.protector
        let newStore = Store(root: root, protector: protector)
        store = newStore
        commentStore = CommentStore(root: root, protector: protector)
        if case let .needsNewerApp(dataVersion, appVersion) = newStore.schemaCompatibility {
            schemaWarning = """
            This folder's data was created by a newer version of Aletheia \
            (data format v\(dataVersion); this copy understands v\(appVersion)). \
            Please update Aletheia before adding or changing anything here, \
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
            reindexSpotlight()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Rebuilds the Spotlight index from the current patients/sessions when the
    /// user has opted in, or clears it when they haven't. Metadata only — see
    /// `SpotlightItemBuilder`. Safe to call often; it's a no-op off macOS.
    func reindexSpotlight() {
        guard settings.spotlightIndexingEnabled else {
            spotlightIndexer.clear()
            return
        }
        guard let store else { return }
        let patients = self.patients
        var entries: [SpotlightEntry] = []
        for patient in patients {
            let sessions = (try? store.listSessions(for: patient)) ?? []
            entries += SpotlightItemBuilder.entries(for: patient, sessions: sessions)
        }
        spotlightIndexer.replaceIndex(with: entries)
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

    /// Create a fresh session for a patient — used by the menu-bar quick-start,
    /// which records into a brand-new session rather than an existing one.
    /// Returns the created session, or nil on error (surfaced via errorMessage).
    @discardableResult
    func startNewSession(for patient: Patient) -> SessionRecord? {
        guard let store else { return nil }
        do {
            let session = try store.createSession(for: patient)
            refreshPatients()
            return session
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
