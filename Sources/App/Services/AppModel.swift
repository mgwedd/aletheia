import Foundation

/// Thin coordinator between AppSettings (where is the data?) and Store (the
/// actual file I/O). Views read `patients` and call the mutating methods;
/// nothing here does its own persistence beyond what Store already does.
final class AppModel: ObservableObject {
    @Published var patients: [Patient] = []
    /// Patient records (`patient.json`) that couldn't be read at the last
    /// refresh. Not in `patients`, but never deleted or rewritten; the sidebar
    /// shows them so they don't vanish silently. Session-level damage lives on
    /// `Store.unreadableEntries` / `Store.sessionListing(for:)`.
    @Published var unreadablePatients: [UnreadableEntry] = []
    /// Encrypted database payloads that could not be opened at the last refresh.
    @Published var unreadableDatabaseRecords: [UnreadableEntry] = []
    @Published var errorMessage: String?
    /// Whether the data folder's volume is encrypted (nil = unknown). Refreshed
    /// when the folder changes and before each new-record action.
    @Published private(set) var diskEncrypted: Bool?
    /// Set when a new-record action was blocked, or went ahead with an unconfirmed
    /// disk state; the main window shows it with a link to System Settings.
    @Published var fileVaultNotice: FileVaultNotice?
    var diskProbe: DiskEncryptionProbing = DiskEncryptionProbe()
    private var warnedUnknownDisk = false
    /// Set when the chosen data folder was written by a newer app version, so
    /// this build shouldn't modify it. Surfaced to the user as a warning.
    @Published var schemaWarning: String?
    /// Whether the SQLite database (notes, comments, chat) opened. When it
    /// didn't, `.unavailable` carries the typed reason and the main window shows
    /// an unmissable error with diagnosing steps instead of silently carrying on
    /// while nothing saves. See `DatabaseUnavailableBanner` and `DoctorFeatureModule`.
    @Published private(set) var databaseState: DatabaseState = .noDataFolder
    /// Set when a save reached for the database (chat, notes) failed, so the UI
    /// can show a small "couldn't save" notice rather than dropping it silently.
    /// `saveFailureSubject` is what failed ("chat", "note"), so a later
    /// successful save of the same thing clears it.
    @Published private(set) var saveFailureSubject: String?
    /// Tells an open search that the index changed (see `SearchIndexMonitor`).
    /// Separate from this object so indexing doesn't redraw every view.
    let searchIndexMonitor = SearchIndexMonitor()
    /// Recording, transcription and model use, reported by the views; the
    /// background index sweep waits while any is going on.
    let searchActivity = SearchIndexActivity()

    private(set) var store: Store?
    /// Local SQLite store for the therapist's own annotations (inline comments
    /// and freeform session notes), living inside the chosen data folder.
    private(set) var commentStore: CommentStore?
    /// On-device, append-only audit log of ePHI-affecting actions (HIPAA
    /// §164.312(b)), living in the data folder beside the stores.
    private(set) var audit: AuditLog?
    /// True while the last attempt to write an activity-log entry failed; shown
    /// in the security overview and as a banner so a broken log isn't silent.
    @Published private(set) var auditWriteFailed = false
    /// Conditions to tell the user about (repeated failed unlocks, a broken
    /// activity log), shown as banners until dismissed.
    @Published private(set) var securityAlerts: [SecurityAlert] = []
    private var failedUnlocks = FailedUnlockMonitor()
    private var didRunLaunchIntegrityCheck = false
    private var lastDataRootPath: String?
    /// The persistent search index (`<dataRoot>/search.sqlite`), reused while the data folder is unchanged.
    private var searchIndex: SearchIndex?
    private var searchSync: Task<Void, Never>?
    // Previous encryption on/unlocked state, so `rebuildStore` (which fires on
    // every protection change) can derive what changed and record it. Both are
    // `nil` until the first build, so launching the app isn't logged as a change.
    private var lastEncryptionEnabled: Bool?
    private var lastEncryptionUnlocked: Bool?
    private let settings: AppSettings
    /// Supplies the `FileProtector` the stores read/write through. When
    /// encryption is locked it rejects access, including writes.
    private let encryption: EncryptionManager
    private let spotlightIndexer: SpotlightIndexing
    /// The feature modules this build ships, composed once at launch from the
    /// full catalog. See `FeatureRegistry`.
    let featureRegistry: FeatureRegistry

    init(
        settings: AppSettings,
        encryption: EncryptionManager,
        spotlightIndexer: SpotlightIndexing = SpotlightIndexerFactory.make(),
        featureRegistry: FeatureRegistry = .compose(tier: .current, from: FeatureRegistry.allModules)
    ) {
        self.settings = settings
        self.encryption = encryption
        self.spotlightIndexer = spotlightIndexer
        self.featureRegistry = featureRegistry
        rebuildStore()
        encryption.recordAudit = { [weak self] action, detail in
            self?.recordAudit(action, detail: detail)
        }
        runLaunchIntegrityCheck()
        // Rebuild the stores with a fresh protector whenever encryption is
        // enabled, unlocked, or locked, so reads/writes pick up the key change.
        encryption.onProtectionChanged = { [weak self] in self?.rebuildStore() }
        encryption.onPassphraseChanged = { [weak self] in self?.recordAudit(.encryptionPassphraseChanged) }
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
    var encryptionRequiresAppLock: Bool { encryption.requiresAppLock }

    /// Whether at-rest encryption is set up *and* unlocked this session. Read by
    /// Doctor to describe the keystore's state.
    var isEncryptionUnlocked: Bool { encryption.isUnlocked }

    func rebuildStore() {
        searchSync?.cancel()
        searchSync = nil
        if let root = settings.dataRootURL, DataFolderPolicy.verdict(for: root) != .ok {
            store = nil
            commentStore = nil
            audit = nil
            searchIndex = nil
            SessionSearch.index = SearchIndex()
            databaseState = .noDataFolder
            patients = []
            unreadablePatients = []
            schemaWarning = nil
            return
        }
        // Recompute encryption state first (the data folder may have just
        // changed), then build the stores around the resulting protector.
        encryption.refreshState()
        refreshDiskEncryption()
        let dataRoot = settings.dataRootURL
        let previousAudit = audit
        attachAudit(dataRoot.map { root in
            AuditLog(root: root, keyProvider: auditKeyProvider, dekProvider: { [weak self] in self?.encryption.protector.heldKey })
        })
        logDataFolderChangeIfNeeded(from: previousAudit, to: dataRoot)
        logEncryptionTransitionIfNeeded()
        saveFailureSubject = nil
        guard let root = dataRoot else {
            store = nil
            commentStore = nil
            databaseState = .noDataFolder
            patients = []
            unreadablePatients = []
            unreadableDatabaseRecords = []
            schemaWarning = nil
            return
        }
        let protector = encryption.protector
        // Build the DB store once and share it with the file Store, so chat
        // threads (now DB-backed) and comments/notes all go through one
        // connection rather than two pointed at the same file.
        let newCommentStore: CommentStore?
        do {
            newCommentStore = try CommentStore(opening: root, protector: protector)
            databaseState = .available
        } catch let failure as DatabaseOpenFailure {
            newCommentStore = nil
            databaseState = .unavailable(failure)
        } catch {
            newCommentStore = nil
            databaseState = .unavailable(DatabaseOpenFailure(
                kind: .unknown,
                reason: "Unexpected error while opening the database."
            ))
        }
        commentStore = newCommentStore
        let auditSink: (AuditAction, String?, String?) -> Void = { [weak self] action, subject, detail in
            self?.recordAudit(action, subjectID: subject, detail: detail)
        }
        newCommentStore?.onAudit = auditSink
        let indexURL = root.appendingPathComponent("search.sqlite")
        let index = searchIndex?.url == indexURL ? searchIndex! : SearchIndex(url: indexURL)
        searchIndex = index
        index.mayOpen = { SessionSearch.mayOpenIndex }
        index.onReopen = { [weak self] in DispatchQueue.main.async { self?.startSearchSync() } }
        // A damaged or outdated file was thrown away: sweep again to refill it.
        index.onReset = { [weak self] in DispatchQueue.main.async { self?.startSearchSync() } }
        let monitor = searchIndexMonitor
        index.progress.onChange { monitor.noteChange() }
        // The file is a plaintext copy: not to be left behind while the folder is locked (e.g. from the last session).
        if encryption.isEnabled && !encryption.isUnlocked { index.destroy() }
        SessionSearch.index = index
        let newStore = Store(
            root: root, protector: protector, commentStore: newCommentStore, openDatabaseIfMissing: false, searchIndex: index)
        newStore.onAudit = auditSink
        store = newStore
        startSearchSync()
        if case let .needsNewerApp(dataVersion, appVersion) = newStore.schemaCompatibility {
            schemaWarning = """
            This folder's data was created by a newer version of Aletheia \
            (data format v\(dataVersion); this copy understands v\(appVersion)). \
            Please update Aletheia before adding or changing anything here, \
            so none of your notes are lost.
            """
        } else if case .migrationFailed = newStore.schemaCompatibility {
            schemaWarning = "The patient folder upgrade could not finish. The original records and migration backup were kept. Resolve the folder issue and reopen Aletheia before editing records."
        } else {
            schemaWarning = nil
        }
        refreshPatients()
    }

    /// Brings the index up to date in the background (launch, unlock, folder change, the index starting
    /// over). Not while either lock is engaged, when no transcript may be read, and it stops as soon as one
    /// engages. It pauses while a recording, a transcription or the AI model is running (`searchActivity`).
    private func startSearchSync() {
        searchSync?.cancel()
        searchSync = nil
        guard let store, let index = searchIndex, !index.isBlocked else { return }
        let activity = searchActivity
        searchSync = Task.detached(priority: .utility) {
            await SearchIndexSweep.run(
                store: store, index: index,
                isBusy: { activity.isBusy },
                shouldContinue: { !Task.isCancelled && !index.isBlocked })
        }
    }

    /// Quitting: stops the background index sweep and closes the index, off the
    /// main thread (closing waits for an index write in progress).
    func stopSearchSync() async {
        searchSync?.cancel()
        searchSync = nil
        guard let index = searchIndex else { return }
        // The index file holds transcript text in the clear: when the folder is
        // encrypted, don't leave it behind. The next launch's sweep rebuilds it.
        let destroy = encryption.isEnabled
        await Task.detached(priority: .userInitiated) {
            if destroy { index.destroy() } else { index.close() }
        }.value
    }

    /// Runs a save that goes to the database and, if it throws, raises the
    /// "couldn't save" notice instead of discarding the failure (views used to
    /// call these with `try?`). A later success for the same `subject` clears it.
    /// - Returns: whether the save succeeded.
    @discardableResult
    func attemptSave(_ subject: String, _ work: () throws -> Void) -> Bool {
        do {
            try work()
            if saveFailureSubject == subject { saveFailureSubject = nil }
            return true
        } catch {
            reportSaveFailure(subject)
            return false
        }
    }

    /// Saves a session's freeform note, surfacing a failure (see `attemptSave`).
    func saveNote(sessionID: UUID, text: String) {
        attemptSave("note") {
            guard let commentStore else { throw DatabaseWriteError.databaseUnavailable }
            guard commentStore.saveNote(sessionID: sessionID, text: text) else { throw DatabaseWriteError.writeFailed }
        }
    }

    /// Adds an inline comment, surfacing a failure (see `attemptSave`).
    func addComment(sessionID: UUID, quotedText: String, body: String, anchorSeconds: Double?, quoteStart: Int?) -> SessionComment? {
        var added: SessionComment?
        attemptSave("comment") {
            guard let commentStore else { throw DatabaseWriteError.databaseUnavailable }
            added = commentStore.addComment(
                sessionID: sessionID, quotedText: quotedText, body: body,
                anchorSeconds: anchorSeconds, quoteStart: quoteStart
            )
            guard added != nil else { throw DatabaseWriteError.writeFailed }
        }
        return added
    }

    /// Edits a comment's body, surfacing a failure (see `attemptSave`).
    @discardableResult
    func updateComment(id: String, body: String) -> Bool {
        attemptSave("comment") {
            guard let commentStore else { throw DatabaseWriteError.databaseUnavailable }
            guard commentStore.updateComment(id: id, body: body) else { throw DatabaseWriteError.writeFailed }
        }
    }

    /// Resolves or reopens a comment, surfacing a failure (see `attemptSave`).
    @discardableResult
    func setCommentResolved(id: String, resolved: Bool) -> Bool {
        attemptSave("comment") {
            guard let commentStore else { throw DatabaseWriteError.databaseUnavailable }
            guard commentStore.setCommentResolved(id: id, resolved: resolved) else { throw DatabaseWriteError.writeFailed }
        }
    }

    /// Records that saving `subject` failed. See `attemptSave`.
    func reportSaveFailure(_ subject: String) {
        saveFailureSubject = subject
    }

    func dismissSaveFailure() {
        saveFailureSubject = nil
    }

    /// Re-attempts opening the database and store with the current configuration.
    func reopenDatabase() {
        rebuildStore()
    }

    /// Re-attempts opening the database and store with the current configuration.
    func reopenStore() {
        rebuildStore()
    }

    /// Prompts the user with a folder chooser panel to pick another data folder,
    /// sets it as the active data root, and rebuilds the store.
    /// The data folder was copied to a new location. The held key belongs to the
    /// old location, so it's dropped on rebuild; a key remembered on this Mac
    /// unlocks the copy again (it carries the same keystore) instead of asking
    /// for the passphrase.
    func dataFolderMoved() {
        rebuildStore()
        encryption.autoUnlockFromDevice()
    }

    @discardableResult
    func chooseDataFolder() -> Bool {
        guard let url = FolderPicker.choose() else { return false }
        do {
            try settings.setDataRoot(url)
            rebuildStore()
            return true
        } catch {
            databaseState = .unavailable(DatabaseOpenFailure(
                kind: .cannotOpen,
                reason: error.localizedDescription
            ))
            return false
        }
    }

    /// How a candidate backup folder is judged. Injectable so tests stay off the
    /// real filesystem facts (iCloud, volumes).
    var backupFolderVerdict: (URL) -> DataFolderPolicy.Verdict = { DataFolderPolicy.verdict(for: $0) }

    /// Writes an encrypted archive of the database into `folder` (a folder the
    /// user chose), sealed with the folder key, and records the backup once on
    /// success. Nothing is recorded when the backup is refused or fails.
    /// Runs on the main actor: it updates published settings, which the menu
    /// bar and windows observe; the archive itself is written off the main thread.
    @MainActor func backUpNow(to folder: URL) async -> BackupOutcome {
        guard let root = settings.dataRootURL, let comments = commentStore else {
            return .failed("Choose a data folder first.")
        }
        guard let key = encryption.protector.heldKey else {
            return .failed("Turn on and unlock encryption first. Backups are sealed with your encryption key.")
        }
        let verdict = backupFolderVerdict(folder)
        guard verdict == .ok else { return .failed(verdict.explanation) }
        let dataPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let folderPath = folder.standardizedFileURL.resolvingSymlinksInPath().path
        guard folderPath != dataPath, !folderPath.hasPrefix(dataPath + "/") else {
            return .failed("Choose a folder outside your data folder, ideally on another disk.")
        }
        var service = LocalEncryptedBackupService(root: root, key: key)
        service.destinationOverride = folder
        let outcome = await BackupCoordinator(store: comments, destination: service).backUpNow(reason: "manual")
        if case .success = outcome {
            // The key wrapper is passphrase-protected; keeping it beside the
            // archive lets the backup be opened without the original data folder.
            if !Keystore.exists(at: folder), let keystore = Keystore.load(from: root) { try? keystore.write(to: folder) }
            settings.localEncryptedBackupEnabled = true
            recordAudit(.backupRun)
        }
        return outcome
    }

    /// Record an ePHI-affecting action, if a data folder (and thus a log) exists.
    /// The thin seam call sites use so they don't reach into `audit` directly.
    func recordAudit(_ action: AuditAction, subjectID: String? = nil, detail: String? = nil) {
        _ = try? audit?.record(action, subjectID: subjectID, detail: detail)
    }

    /// Makes `log` the current activity log and mirrors its write-failure state
    /// into `auditWriteFailed`.
    func attachAudit(_ log: AuditLog?) {
        audit = log
        auditWriteFailed = log?.lastWriteFailed ?? false
        log?.onWriteStateChanged = { [weak self] failed in
            if Thread.isMainThread {
                self?.auditWriteFailed = failed
            } else {
                DispatchQueue.main.async { self?.auditWriteFailed = failed }
            }
        }
    }

    /// A different data folder than the last build's: noted in the log it left
    /// and in the one it opened. The first build (launch) is only a baseline.
    private func logDataFolderChangeIfNeeded(from previous: AuditLog?, to root: URL?) {
        let path = root?.standardizedFileURL.path
        defer { lastDataRootPath = path }
        guard let last = lastDataRootPath, let path, last != path else { return }
        _ = try? previous?.record(.dataFolderChanged, detail: "Moved away from this folder")
        recordAudit(.dataFolderChanged, detail: "Opened this folder")
    }

    // MARK: - Alerts

    /// A failed unlock attempt: recorded, and counted toward a repeated-failure alert.
    func noteUnlockFailure(_ reason: String, now: Date = Date()) {
        recordAudit(.appUnlockFailed, detail: reason)
        guard failedUnlocks.recordFailure(at: now) else { return }
        let attempts = failedUnlocks.threshold
        let minutes = Int(failedUnlocks.window / 60)
        recordAudit(.repeatedUnlockFailures, detail: "\(attempts) failed unlocks within \(minutes) minutes")
        raise(.repeatedUnlockFailures(attempts: attempts, minutes: minutes))
    }

    func noteUnlockSuccess() {
        failedUnlocks.recordSuccess()
    }

    /// Checks the activity log's chain once, in the background, at launch.
    private func runLaunchIntegrityCheck() {
        guard !didRunLaunchIntegrityCheck, let log = audit else { return }
        didRunLaunchIntegrityCheck = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = log.verifyIntegrity()
            DispatchQueue.main.async { self?.applyIntegrityResult(result) }
        }
    }

    /// A broken chain is recorded (once per break) and raised as an alert.
    func applyIntegrityResult(_ result: IntegrityVerificationResult) {
        guard case let .broken(seq, _) = result else { return }
        let detail = "Chain broken at entry #\(seq)"
        let alreadyRecorded = audit?.entries().last { $0.action == .integrityCheckFailed }?.detail == detail
        if !alreadyRecorded { recordAudit(.integrityCheckFailed, detail: detail) }
        raise(.auditLogBroken(entry: seq))
    }

    private func raise(_ alert: SecurityAlert) {
        securityAlerts.removeAll { $0.id == alert.id }
        securityAlerts.append(alert)
    }

    /// A recording problem the user must hear about (raised by the recorder).
    func noteRecordingProblem(_ alert: SecurityAlert) { raise(alert) }

    func dismissSecurityAlert(_ alert: SecurityAlert) {
        securityAlerts.removeAll { $0.id == alert.id }
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
            _ = try? audit?.record(.encryptionEnabled)
        } else if wasEnabled, !enabled {
            _ = try? audit?.record(.encryptionDisabled)
        } else if wasEnabled, enabled, !wasUnlocked, unlocked {
            // Unlocking an already-enabled folder (a fresh enable already logs
            // .encryptionEnabled, so it isn't double-counted as an unlock).
            _ = try? audit?.record(.encryptionUnlocked)
        }
    }

    func refreshPatients() {
        guard let store else { return }
        do {
            let listing = try store.patientListing()
            patients = listing.patients
            unreadablePatients = listing.unreadable + store.unreadableEntries.filter { $0.kind == .storedRecord }
            unreadableDatabaseRecords = commentStore?.unreadableEntries ?? []
            reindexSpotlight()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Rebuilds the Spotlight index from the current patients/sessions when the
    /// build ships Spotlight indexing and the user has opted in, or clears it
    /// otherwise (including while the app or data folder is locked). Metadata only — see `SpotlightItemBuilder`. Safe to call
    /// often; it's a no-op off macOS.
    func reindexSpotlight() {
        guard featureRegistry.contains(id: SpotlightFeatureModule.id) else {
            spotlightIndexer.clear()
            return
        }
        guard settings.spotlightIndexingEnabled, !SystemSurfaceAccess.isLocked else {
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

    /// Re-reads the disk state for the data folder.
    func refreshDiskEncryption() {
        diskEncrypted = settings.dataRootURL.flatMap { diskProbe.isDataVolumeEncrypted($0) }
    }

    /// The gate for creating a patient, starting a session or starting a
    /// recording. False (with `fileVaultNotice` set) only when the disk is known
    /// to be unencrypted; an unknown state proceeds, warning once per launch.
    func authorizeNewPHI() -> Bool {
        refreshDiskEncryption()
        if !PHIEntryGate.allowsNewPHI(diskEncrypted: diskEncrypted) {
            fileVaultNotice = .blocked
            return false
        }
        if PHIEntryGate.warnsUnknown(diskEncrypted: diskEncrypted), !warnedUnknownDisk {
            warnedUnknownDisk = true
            fileVaultNotice = .unknown
        }
        return true
    }

    @discardableResult
    func addPatient(name: String) -> Patient? {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard authorizeNewPHI() else { return nil }
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
        guard authorizeNewPHI() else { return nil }
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

    /// Applies a field-level change to the *current* stored copy of a patient
    /// (looked up by id) and saves it. Views hold a snapshot of the patient that
    /// can be older than what's on disk; saving that snapshot whole would roll
    /// back every field except the one just edited, so each edit goes through
    /// here and only changes what `mutate` touches. Failures surface the same
    /// way as `savePatientNotes`.
    func updatePatient(id: UUID, _ mutate: (inout Patient) -> Void) {
        guard var current = patients.first(where: { $0.id == id }) else { return }
        mutate(&current)
        savePatientNotes(current)
    }

    /// Deletes a patient and all of their associated records from disk and the
    /// database, writes an audit log entry (HIPAA §164.312(b)), refreshes the
    /// patient list, and reindexes Spotlight.
    func deletePatient(_ patient: Patient) throws {
        guard let store else { throw StoreError.noDataRoot }
        try store.deletePatient(patient)
        refreshPatients()
        reindexSpotlight()
    }

    /// Supplies the key that signs the activity log's entries. Defaults to the
    /// Keychain key; tests swap it (then call `rebuildStore()`) so the log is
    /// signed and verifiable without touching the real Keychain.
    var auditKeyProvider: AuditKeyProvider = AuditKeyManager.loadOrCreateKeychainKey

    /// What "Verify integrity & export audit report" shows and saves: the
    /// chain check's one-line result and the full report. A broken chain is
    /// recorded and raised first, so the report lists it.
    struct AuditVerification: Equatable {
        let message: String
        let report: String
    }

    func verifyAuditLog() -> AuditVerification? {
        guard let audit else { return nil }
        let result = audit.verifyIntegrity()
        let message = result.statusMessage
        applyIntegrityResult(result)
        return AuditVerification(message: message, report: audit.generateReport(status: message))
    }
}


/// A FileVault message shown from the main window.
enum FileVaultNotice {
    case blocked, unknown

    var title: String {
        self == .blocked ? PHIEntryGate.blockedTitle : PHIEntryGate.unknownTitle
    }

    var message: String {
        self == .blocked ? PHIEntryGate.blockedMessage : PHIEntryGate.unknownMessage
    }
}
