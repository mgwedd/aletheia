import AletheiaCore
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
    /// On-device, append-only audit log of ePHI-affecting actions (HIPAA
    /// §164.312(b)), living in the data folder beside the stores.
    private(set) var audit: AuditLog?
    // Previous encryption on/unlocked state, so `rebuildStore` (which fires on
    // every protection change) can derive what changed and record it. Both are
    // `nil` until the first build, so launching the app isn't logged as a change.
    private var lastEncryptionEnabled: Bool?
    private var lastEncryptionUnlocked: Bool?
    private let settings: AppSettings
    /// Supplies the `FileProtector` the stores read/write through. When
    /// encryption is off or locked it's a passthrough, so the stores behave as
    /// they always have.
    private let encryption: EncryptionManager
    private let spotlightIndexer: SpotlightIndexing
    /// The feature modules this build ships, composed once at launch from the
    /// full catalog. See `FeatureRegistry`.
    let featureRegistry: FeatureRegistry

    init(
        settings: AppSettings,
        encryption: EncryptionManager,
        spotlightIndexer: SpotlightIndexing = SpotlightIndexer.shared,
        featureRegistry: FeatureRegistry = .compose(tier: .current, from: FeatureRegistry.allModules)
    ) {
        self.settings = settings
        self.encryption = encryption
        self.spotlightIndexer = spotlightIndexer
        self.featureRegistry = featureRegistry
        rebuildStore()
        // Rebuild the stores with a fresh protector whenever encryption is
        // enabled, unlocked, or locked, so reads/writes pick up the key change.
        encryption.onProtectionChanged = { [weak self] in self?.rebuildStore() }
    }

    /// The protector the stores are currently using — for callers that seal or
    /// open PHI outside the stores (the recorder's audio; transcription's
    /// decrypt-to-temp).
    var currentProtector: FileProtector { encryption.protector }

    /// Whether at-rest encryption is set up (a keystore exists on disk),
    /// regardless of whether it's currently unlocked. Audio retention is gated on
    /// this so kept recordings are only ever stored as ciphertext
    /// (`AudioRetentionPolicy.keepsAudio`).
    var isEncryptionEnabled: Bool { encryption.isEnabled }

    func rebuildStore() {
        // Recompute encryption state first (the data folder may have just
        // changed), then build the stores around the resulting protector.
        encryption.refresh()
        let dataRoot = settings.dataRootURL
        audit = dataRoot.map(AuditLog.init)
        logEncryptionTransitionIfNeeded()
        guard let root = dataRoot else {
            store = nil
            commentStore = nil
            patients = []
            schemaWarning = nil
            return
        }
        let protector = encryption.protector
        // Build the DB store once and share it with the file Store, so chat
        // threads (now DB-backed) and comments/notes all go through one
        // connection rather than two pointed at the same file.
        let newCommentStore = CommentStore(root: root, protector: protector)
        commentStore = newCommentStore
        let newStore = Store(root: root, protector: protector, commentStore: newCommentStore)
        store = newStore
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

    /// Record an ePHI-affecting action, if a data folder (and thus a log) exists.
    /// The thin seam call sites use so they don't reach into `audit` directly.
    func recordAudit(_ action: AuditAction, subjectID: String? = nil, detail: String? = nil) {
        audit?.record(action, subjectID: subjectID, detail: detail)
    }

    /// Compares the current encryption on/unlocked state against the last build's
    /// and records any transition. `rebuildStore` fires on enable, disable,
    /// unlock and lock, but can't itself say which happened — this derives it.
    private func logEncryptionTransitionIfNeeded() {
        let enabled = encryption.isEnabled
        let unlocked = encryption.isUnlocked
        defer {
            lastEncryptionEnabled = enabled
            lastEncryptionUnlocked = unlocked
        }
        // First build (launch): record the baseline, don't log it as a change.
        guard let wasEnabled = lastEncryptionEnabled,
              let wasUnlocked = lastEncryptionUnlocked else { return }
        if !wasEnabled, enabled {
            audit?.record(.encryptionEnabled)
        } else if wasEnabled, !enabled {
            audit?.record(.encryptionDisabled)
        } else if wasEnabled, enabled, !wasUnlocked, unlocked {
            // Unlocking an already-enabled folder (a fresh enable already logs
            // .encryptionEnabled, so it isn't double-counted as an unlock).
            audit?.record(.encryptionUnlocked)
        }
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
    /// build ships Spotlight indexing and the user has opted in, or clears it
    /// otherwise. Metadata only — see `SpotlightItemBuilder`. Safe to call
    /// often; it's a no-op off macOS.
    func reindexSpotlight() {
        guard featureRegistry.contains(id: SpotlightFeatureModule.id) else {
            spotlightIndexer.clear()
            return
        }
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
