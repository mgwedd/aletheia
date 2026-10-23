import Foundation

/// Whisper model choices, ordered smallest/fastest to largest/most accurate.
/// whisper.cpp runs entirely on-device (no network, no CLI), on the GPU via
/// Metal. Larger models are slower per minute of audio and more accurate.
enum WhisperModel: String, CaseIterable, Identifiable, Codable, Hashable {
    case baseEn = "base.en"
    case smallEn = "small.en"
    case mediumEn = "medium.en"
    case largeV3 = "large-v3"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .baseEn: return "Base (English) — fastest, least accurate"
        case .smallEn: return "Small (English) — fast, good accuracy"
        case .mediumEn: return "Medium (English) — slower, more accurate"
        case .largeV3: return "Large v3 (multilingual) — slowest, most accurate"
        }
    }

    var approximateSizeMB: Int {
        switch self {
        case .baseEn: return 148
        case .smallEn: return 488
        case .mediumEn: return 1530
        case .largeV3: return 3100
        }
    }

    var fileName: String { "ggml-\(rawValue).bin" }

    var shortName: String {
        switch self {
        case .baseEn: return "Base"
        case .smallEn: return "Small"
        case .mediumEn: return "Medium"
        case .largeV3: return "Large v3"
        }
    }

    /// Whisper's weights are released by OpenAI under the MIT License.
    var licenseName: String { "MIT License" }

    /// Where that license can be read (opened in the user's browser).
    var licenseURL: URL { URL(string: "https://github.com/openai/whisper/blob/main/LICENSE")! }
}

/// Idle auto-lock choices offered in Settings (HIPAA §164.312(a)(2)(iii)
/// "automatic logoff"). The raw value is the timeout in minutes; `.off` (0)
/// disables idle auto-lock regardless of how long the app sits untouched.
enum IdleAutoLockTimeout: Int, CaseIterable, Identifiable, Codable, Hashable {
    case off = 0
    case oneMinute = 1
    case fiveMinutes = 5
    case fifteenMinutes = 15
    case thirtyMinutes = 30
    case sixtyMinutes = 60

    var id: Int { rawValue }

    /// New installs lock after 15 minutes of inactivity. An explicit Never
    /// choice remains available and persists.
    static let defaultTimeout: IdleAutoLockTimeout = .fifteenMinutes

    var displayName: String {
        switch self {
        case .off: return "Never"
        case .oneMinute: return "1 minute"
        default: return "\(rawValue) minutes"
        }
    }
}

/// All persisted app preferences. Backed by UserDefaults; nothing here is
/// sensitive (no credentials — everything the app talks to is local).
///
/// Not actor-isolated: every mutation here happens synchronously in
/// response to a direct user action (a button, a picker), so it follows
/// SwiftUI's usual "UI state changes happen on the main thread by
/// convention" pattern rather than opting into strict actor checking.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Keys {
        static let dataRootBookmark = "dataRootBookmark"
        static let whisperModel = "whisperModel"
        static let assistantBackend = "assistantBackend"
        static let llamaModel = "llamaModel"
        static let systemPrompt = "systemPrompt"
        static let hasCompletedFirstRun = "hasCompletedFirstRun"
        static let autoCheckForUpdates = "autoCheckForUpdates"
        static let spotlightIndexingEnabled = "spotlightIndexingEnabled"
        static let appLockEnabled = "appLockEnabled"
        static let idleAutoLockMinutes = "idleAutoLockMinutes"
        static let lockWhenHidden = "lockWhenHidden"
        static let hideFromScreenSharing = "hideFromScreenSharing"
        static let acceptedLegalVersion = "acceptedLegalVersion"
        static let acceptedLegalDate = "acceptedLegalDate"
        static let progressNoteFormat = "progressNoteFormat"
        static let summaryVerbosity = "summaryVerbosity"
        static let includeCommentsInDrafts = "includeCommentsInDrafts"
        static let notificationsShowPatientNames = "notificationsShowPatientNames"
        static let transcriptSplitRatio = "transcriptSplitRatio"
        static let includePatientBackground = "includePatientBackground"
        static let noteInstructions = "noteInstructions"
        static let modelSpeeds = "modelSpeeds"
        static let noteEffort = "noteEffort"
        static let riskPhrases = "riskPhrases"
        static let sessionChatEffort = "sessionChatEffort"
        static let patientChatEffort = "patientChatEffort"
        static let summariesPaused = "summariesPaused"
        static let prepareSummariesOnBattery = "prepareSummariesOnBattery"
        static let localEncryptedBackupEnabled = "localEncryptedBackupEnabled"
        static let iCloudEncryptedBackupEnabled = "iCloudEncryptedBackupEnabled"
        static let keepAudioRecordings = "keepAudioRecordings"
        static let autoTranscribeAfterRecording = "autoTranscribeAfterRecording"
        static let appearance = "appearance"
        static let debugDiagnosticsEnabled = "debugDiagnosticsEnabled"
        static let keepDataOutOfSystemBackups = BackupExclusion.defaultsKey
        static let dismissedDamagedRecordIDs = "dismissedDamagedRecordIDs"
    }

    private let defaults: UserDefaults

    @Published var dataRootURL: URL?
    @Published var whisperModel: WhisperModel {
        didSet { defaults.set(whisperModel.rawValue, forKey: Keys.whisperModel) }
    }
    @Published var assistantBackend: AssistantBackend {
        didSet {
            defaults.set(assistantBackend.rawValue, forKey: Keys.assistantBackend)
            if assistantBackend != oldValue { LlamaRuntime.unloadAll() }
        }
    }
    @Published var llamaModel: LlamaModel {
        didSet {
            defaults.set(llamaModel.rawValue, forKey: Keys.llamaModel)
            if llamaModel != oldValue { LlamaRuntime.unloadAll() }
        }
    }
    /// The system prompt prepended to every LLM request. Defaults to
    /// `Prompts.defaultSystemPrompt`; fully editable (and resettable) in Settings.
    @Published var systemPrompt: String {
        didSet { defaults.set(systemPrompt, forKey: Keys.systemPrompt) }
    }
    @Published var hasCompletedFirstRun: Bool {
        didSet { defaults.set(hasCompletedFirstRun, forKey: Keys.hasCompletedFirstRun) }
    }
    /// Whether to check for software updates automatically on launch and when the app
    /// becomes active. On by default. When off, updates are only checked when the
    /// user clicks "Check for Updates" in Settings.
    @Published var autoCheckForUpdates: Bool {
        didSet { defaults.set(autoCheckForUpdates, forKey: Keys.autoCheckForUpdates) }
    }
    /// Off by default: putting patient names into system-wide Spotlight is a
    /// privacy trade-off (anyone at the Mac can see them), so the user opts in.
    @Published var spotlightIndexingEnabled: Bool {
        didSet { defaults.set(spotlightIndexingEnabled, forKey: Keys.spotlightIndexingEnabled) }
    }
    /// Require Touch ID / the login password to open the app (see `AppLock`).
    @Published var appLockEnabled: Bool {
        didSet { defaults.set(appLockEnabled, forKey: Keys.appLockEnabled) }
    }
    @Published var lockWhenHidden: Bool {
        didSet { defaults.set(lockWhenHidden, forKey: Keys.lockWhenHidden) }
    }
    @Published var hideFromScreenSharing: Bool {
        didSet { defaults.set(hideFromScreenSharing, forKey: Keys.hideFromScreenSharing) }
    }
    /// Temporary exception; always resets at launch.
    @Published var allowScreenSharingThisSession = false
    /// HIPAA §164.312(a)(2)(iii) "automatic logoff": how many minutes of
    /// inactivity before `AppLock` re-engages, one of `IdleAutoLockTimeout`'s
    /// `allCases` values. `0` means "Never" (idle auto-lock off). Only takes
    /// effect while `appLockEnabled` is on — locking requires the Touch ID /
    /// password gate to exist in the first place.
    @Published var idleAutoLockMinutes: Int {
        didSet { defaults.set(idleAutoLockMinutes, forKey: Keys.idleAutoLockMinutes) }
    }
    /// The clinical documentation format the "Generate note" action defaults to.
    /// A plain summary out of the box (`ProgressNoteFormat.default`); a therapist who
    /// wants a payer-ready structure picks SOAP/DAP/BIRP here or per session.
    @Published var progressNoteFormat: ProgressNoteFormat {
        didSet { defaults.set(progressNoteFormat.rawValue, forKey: Keys.progressNoteFormat) }
    }
    /// How long a generated Summary runs (`SummaryVerbosity`). Natural by default.
    @Published var summaryVerbosity: SummaryVerbosity {
        didSet { defaults.set(summaryVerbosity.rawValue, forKey: Keys.summaryVerbosity) }
    }
    /// Whether transcript margin comments are included when drafting progress notes.
    /// On by default.
    @Published var includeCommentsInDrafts: Bool {
        didSet { defaults.set(includeCommentsInDrafts, forKey: Keys.includeCommentsInDrafts) }
    }
    /// Whether system notifications name the patient and session date. Off by
    /// default: banners show on the lock screen and macOS keeps them.
    @Published var notificationsShowPatientNames: Bool {
        didSet { defaults.set(notificationsShowPatientNames, forKey: Keys.notificationsShowPatientNames) }
    }
    /// The share of the session pane the transcript takes beside its comments
    /// (the rest is the comments). Where the divider was last dragged.
    @Published var transcriptSplitRatio: Double {
        didSet { defaults.set(transcriptSplitRatio, forKey: Keys.transcriptSplitRatio) }
    }
    /// Whether the patient's clinical history, profile notes, and medications are included in AI context.
    /// On by default.
    @Published var includePatientBackground: Bool {
        didSet { defaults.set(includePatientBackground, forKey: Keys.includePatientBackground) }
    }
    /// Per-format replacements for the note prompt's instruction text, keyed by
    /// `ProgressNoteFormat.rawValue`. A missing key means the default.
    @Published var noteInstructions: [String: String] {
        didSet { defaults.set(noteInstructions, forKey: Keys.noteInstructions) }
    }
    /// Per-model read and write speeds measured on this Mac (tokens a second, a
    /// moving average), keyed by model tag. They give the progress line its
    /// "about 1 min left" once a model has run here.
    @Published var modelSpeeds: [String: [String: Double]] {
        didSet { defaults.set(modelSpeeds, forKey: Keys.modelSpeeds) }
    }
    func speed(for model: String) -> ModelSpeed {
        ModelSpeed(stored: modelSpeeds[model] ?? [:])
    }
    func recordSpeeds(model: String, from stats: AIRunStats) {
        let updated = speed(for: model).folding(stats)
        if updated != speed(for: model) { modelSpeeds[model] = updated.stored }
    }
    /// How much effort each feature puts in (`AnswerEffort`). Stored per
    /// feature; no control or behaviour reads them yet.
    @Published var noteEffort: AnswerEffort {
        didSet { defaults.set(noteEffort.rawValue, forKey: Keys.noteEffort) }
    }
    @Published var sessionChatEffort: AnswerEffort {
        didSet { defaults.set(sessionChatEffort.rawValue, forKey: Keys.sessionChatEffort) }
    }
    @Published var patientChatEffort: AnswerEffort {
        didSet { defaults.set(patientChatEffort.rawValue, forKey: Keys.patientChatEffort) }
    }
    /// The user paused background summaries (`DigestScheduler`); they stay
    /// paused across launches until resumed.
    @Published var summariesPaused: Bool {
        didSet { defaults.set(summariesPaused, forKey: Keys.summariesPaused) }
    }
    /// Whether background summaries may be prepared while the Mac runs on
    /// battery. Off by default: they use the local model and drain it. Low
    /// Power Mode still pauses them either way.
    @Published var prepareSummariesOnBattery: Bool {
        didSet { defaults.set(prepareSummariesOnBattery, forKey: Keys.prepareSummariesOnBattery) }
    }
    /// Phrases whose lines a long session's note always includes first (and warns
    /// about if they don't fit). Plain text, not PHI. Never set means the built-in
    /// defaults; an empty list is the user's own choice of none. A list equal to the
    /// defaults is stored as "never set", so a later change to the defaults reaches
    /// anyone who hasn't edited them.
    @Published var riskPhrases: [String] {
        didSet {
            if riskPhrases == LongSessionNote.defaultRiskPhrases {
                defaults.removeObject(forKey: Keys.riskPhrases)
            } else {
                defaults.set(riskPhrases, forKey: Keys.riskPhrases)
            }
        }
    }
    /// Adds a phrase (trimmed; ignored if empty or already listed, ignoring case).
    func addRiskPhrase(_ text: String) {
        let phrase = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = RiskPhraseMatcher.normalized(phrase)
        guard !key.isEmpty, !riskPhrases.contains(where: { RiskPhraseMatcher.normalized($0) == key }) else { return }
        riskPhrases.append(phrase)
    }
    func resetRiskPhrases() { riskPhrases = LongSessionNote.defaultRiskPhrases }
    /// Saves custom instructions for a format; text that is empty or equal to
    /// the default removes the override.
    func setNoteInstructions(_ text: String, for format: ProgressNoteFormat) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == Prompts.defaultInstructions(for: format) {
            noteInstructions[format.rawValue] = nil
        } else {
            noteInstructions[format.rawValue] = trimmed
        }
    }
    /// Opt-in: keep an end-to-end-encrypted backup copy of the database on this
    /// Mac (in addition to whatever Time Machine already does). The default is
    /// off — Time Machine of the data folder is the baseline local backup.
    @Published var localEncryptedBackupEnabled: Bool {
        didSet { defaults.set(localEncryptedBackupEnabled, forKey: Keys.localEncryptedBackupEnabled) }
    }
    /// Opt-in: also upload the end-to-end-encrypted backup to the user's private
    /// iCloud (CloudKit). The blob is encrypted with the user's key before it
    /// leaves the Mac, so Apple only ever stores ciphertext. Off by default.
    @Published var iCloudEncryptedBackupEnabled: Bool {
        didSet { defaults.set(iCloudEncryptedBackupEnabled, forKey: Keys.iCloudEncryptedBackupEnabled) }
    }
    /// Opt-in: keep a session's raw audio (`mic.caf` / `call.caf`) on disk after
    /// it has been transcribed. Off by default (transcript-only) — the recording
    /// is the most sensitive artifact a session produces, so it is discarded once
    /// the transcript exists. Kept audio is only ever retained as ciphertext:
    /// `AudioRetentionPolicy` requires at-rest encryption to also be on, so this
    /// toggle has no effect while encryption is off (see `SettingsView` and
    /// `SessionDetailView.transcribe()`).
    @Published var keepAudioRecordings: Bool {
        didSet { defaults.set(keepAudioRecordings, forKey: Keys.keepAudioRecordings) }
    }
    /// Start transcribing a session as soon as its recording is stopped, so the
    /// transcript is ready without pressing Transcribe. On unless turned off.
    @Published var autoTranscribeAfterRecording: Bool {
        didSet { defaults.set(autoTranscribeAfterRecording, forKey: Keys.autoTranscribeAfterRecording) }
    }
    /// Light, Dark, or follow the system. Applied app-wide as soon as it changes
    /// (and at launch, by `AppDelegate`).
    @Published var appearance: AppearancePreference {
        didSet {
            defaults.set(appearance.rawValue, forKey: Keys.appearance)
            appearance.apply()
        }
    }
    /// Shows the call-audio triage readout on the recording screen
    /// (`CallAudioDebugView`). Off by default; permission and stream state only.
    @Published var debugDiagnosticsEnabled: Bool {
        didSet { defaults.set(debugDiagnosticsEnabled, forKey: Keys.debugDiagnosticsEnabled) }
    }
    /// Keep the data folder out of Time Machine and iCloud's device backup (via
    /// `isExcludedFromBackup`). Off by default: the app writes no backup of its
    /// own unless opted in, so Time Machine is the baseline copy and excluding
    /// the folder would leave exactly one copy of everything. The key is only
    /// written when the user flips the toggle, so an unset key means "use the
    /// default" (`BackupExclusion.resolvedExclusion`). Applied to the folder
    /// whenever this changes, at launch, or when the data root is set.
    @Published var keepDataOutOfSystemBackups: Bool {
        didSet {
            defaults.set(keepDataOutOfSystemBackups, forKey: Keys.keepDataOutOfSystemBackups)
            applyBackupExclusion()
        }
    }
    /// IDs of damaged or unreadable records explicitly dismissed by the user from notices.
    @Published var dismissedDamagedRecordIDs: Set<String> {
        didSet {
            defaults.set(Array(dismissedDamagedRecordIDs), forKey: Keys.dismissedDamagedRecordIDs)
        }
    }
    func isDamagedRecordDismissed(id: String) -> Bool {
        dismissedDamagedRecordIDs.contains(id)
    }
    func dismissDamagedRecord(id: String) {
        dismissedDamagedRecordIDs.insert(id)
    }
    func undismissDamagedRecord(id: String) {
        dismissedDamagedRecordIDs.remove(id)
    }
    /// The version of the Terms/Privacy Policy the user accepted (see `Legal`).
    /// Empty until accepted. Persisted locally so the practice has a record that
    /// the terms were accepted, and which version, before the app could be used.
    @Published private(set) var acceptedLegalVersion: String {
        didSet { defaults.set(acceptedLegalVersion, forKey: Keys.acceptedLegalVersion) }
    }
    /// When the current terms were accepted, recorded locally alongside the
    /// version. `nil` until accepted. Never leaves this Mac.
    @Published private(set) var acceptedLegalDate: Date? {
        didSet { defaults.set(acceptedLegalDate?.timeIntervalSince1970 ?? 0, forKey: Keys.acceptedLegalDate) }
    }

    /// What this Mac can comfortably run, and the model sizes recommended for
    /// it. Computed once at launch and surfaced in setup so defaults match the
    /// hardware instead of a one-size-fits-all guess.
    let hardware: HardwareCapabilities
    let recommendation: ModelRecommendation

    /// Settings from an older version that no longer exist; cleared on load.
    static let retiredKeys = [
        "ollamaModelName", // legacy-key
        "ollamaBaseURL", // legacy-key
    ]

    private static func removeRetiredKeys(from defaults: UserDefaults) {
        for key in retiredKeys { defaults.removeObject(forKey: key) }
    }

    private convenience init() { self.init(defaults: .standard) }

    /// Test seam: the shared instance uses `UserDefaults.standard`.
    init(defaults: UserDefaults) {
        self.defaults = defaults
        let hardware = HardwareCapabilities.current()
        let recommendation = ModelAdvisor.recommend(for: hardware)
        self.hardware = hardware
        self.recommendation = recommendation

        // First launch picks defaults that fit the hardware; once the user has
        // chosen, their choice always wins.
        if let raw = defaults.string(forKey: Keys.whisperModel), let model = WhisperModel(rawValue: raw) {
            whisperModel = model
        } else {
            whisperModel = recommendation.whisperModel
        }
        // An unrecognised stored value (including one from an older version that
        // offered another engine) means the built-in engine.
        let storedBackend = defaults.string(forKey: Keys.assistantBackend)
        let backend = AssistantBackendResolver.preference(fromStored: storedBackend)
        if let storedBackend, storedBackend != backend.rawValue {
            defaults.set(backend.rawValue, forKey: Keys.assistantBackend)
        }
        assistantBackend = backend
        Self.removeRetiredKeys(from: defaults)
        if let raw = defaults.string(forKey: Keys.llamaModel), let model = LlamaModel(rawValue: raw) {
            llamaModel = model
        } else {
            llamaModel = .recommended(for: hardware)
        }
        let savedPrompt = defaults.string(forKey: Keys.systemPrompt)
        systemPrompt = (savedPrompt?.isEmpty == false) ? savedPrompt! : Prompts.defaultSystemPrompt
        hasCompletedFirstRun = defaults.bool(forKey: Keys.hasCompletedFirstRun)
        localEncryptedBackupEnabled = defaults.bool(forKey: Keys.localEncryptedBackupEnabled)
        iCloudEncryptedBackupEnabled = defaults.bool(forKey: Keys.iCloudEncryptedBackupEnabled)
        keepAudioRecordings = defaults.bool(forKey: Keys.keepAudioRecordings)
        autoTranscribeAfterRecording = Self.resolvedAutoTranscribe(in: defaults)
        appearance = defaults.string(forKey: Keys.appearance)
            .flatMap(AppearancePreference.init(rawValue:)) ?? .default
        // Default off when never set; an explicit stored choice is respected.
        // Assigning in `init` doesn't fire `didSet`, so this never writes the key.
        keepDataOutOfSystemBackups = BackupExclusion.resolvedExclusion(in: defaults)
        debugDiagnosticsEnabled = defaults.bool(forKey: Keys.debugDiagnosticsEnabled)
        spotlightIndexingEnabled = defaults.bool(forKey: Keys.spotlightIndexingEnabled)
        appLockEnabled = defaults.object(forKey: Keys.appLockEnabled) as? Bool ?? true
        lockWhenHidden = defaults.object(forKey: Keys.lockWhenHidden) as? Bool ?? false
        hideFromScreenSharing = defaults.object(forKey: Keys.hideFromScreenSharing) as? Bool ?? true
        if let stored = defaults.object(forKey: Keys.idleAutoLockMinutes) as? Int,
           IdleAutoLockTimeout.allCases.map(\.rawValue).contains(stored) {
            idleAutoLockMinutes = stored
        } else {
            idleAutoLockMinutes = IdleAutoLockTimeout.defaultTimeout.rawValue
        }
        if let raw = defaults.string(forKey: Keys.progressNoteFormat), let format = ProgressNoteFormat(rawValue: raw) {
            progressNoteFormat = format
        } else {
            progressNoteFormat = .default
        }
        summaryVerbosity = defaults.string(forKey: Keys.summaryVerbosity)
            .flatMap(SummaryVerbosity.init(rawValue:)) ?? .default
        includeCommentsInDrafts = defaults.object(forKey: Keys.includeCommentsInDrafts) as? Bool ?? true
        notificationsShowPatientNames = defaults.object(forKey: Keys.notificationsShowPatientNames) as? Bool ?? false
        transcriptSplitRatio = TranscriptSplit.sanitized(
            ratio: defaults.object(forKey: Keys.transcriptSplitRatio) as? Double ?? TranscriptSplit.defaultRatio
        )
        includePatientBackground = defaults.object(forKey: Keys.includePatientBackground) as? Bool ?? true
        noteInstructions = defaults.dictionary(forKey: Keys.noteInstructions) as? [String: String] ?? [:]
        modelSpeeds = defaults.dictionary(forKey: Keys.modelSpeeds) as? [String: [String: Double]] ?? [:]
        riskPhrases = Self.loadRiskPhrases(from: defaults)
        noteEffort = defaults.string(forKey: Keys.noteEffort).flatMap(AnswerEffort.init(rawValue:)) ?? .default
        sessionChatEffort = defaults.string(forKey: Keys.sessionChatEffort).flatMap(AnswerEffort.init(rawValue:)) ?? .default
        patientChatEffort = defaults.string(forKey: Keys.patientChatEffort).flatMap(AnswerEffort.init(rawValue:)) ?? .default
        summariesPaused = defaults.bool(forKey: Keys.summariesPaused)
        prepareSummariesOnBattery = defaults.bool(forKey: Keys.prepareSummariesOnBattery)
        acceptedLegalVersion = defaults.string(forKey: Keys.acceptedLegalVersion) ?? ""
        let acceptedInterval = defaults.double(forKey: Keys.acceptedLegalDate)
        acceptedLegalDate = acceptedInterval > 0 ? Date(timeIntervalSince1970: acceptedInterval) : nil
        autoCheckForUpdates = defaults.object(forKey: Keys.autoCheckForUpdates) as? Bool ?? true
        if let savedDismissed = defaults.stringArray(forKey: Keys.dismissedDamagedRecordIDs) {
            dismissedDamagedRecordIDs = Set(savedDismissed)
        } else {
            dismissedDamagedRecordIDs = []
        }
        dataRootURL = SecurityScopedBookmark.resolve(key: Keys.dataRootBookmark)
        // Re-assert the backup-exclusion policy on the resolved folder each launch
        // (best-effort: the folder may not be accessible yet this early).
        applyBackupExclusion()
    }

    /// The stored risk phrases; the built-in ones when the key was never set (an
    /// empty stored list stays empty).
    static func loadRiskPhrases(from defaults: UserDefaults) -> [String] {
        defaults.stringArray(forKey: Keys.riskPhrases) ?? LongSessionNote.defaultRiskPhrases
    }

    /// On when never chosen; an explicit stored choice is respected.
    static func resolvedAutoTranscribe(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: Keys.autoTranscribeAfterRecording) as? Bool ?? true
    }

    /// Called after the user picks (or creates) the data folder via NSOpenPanel.
    /// Persists a security-scoped bookmark so the sandboxed app can keep
    /// reading/writing that folder on future launches without re-prompting.
    func setDataRoot(_ url: URL) throws {
        try SecurityScopedBookmark.save(url: url, key: Keys.dataRootBookmark)
        dataRootURL = url
        applyBackupExclusion()
    }

    /// Applies the current `keepDataOutOfSystemBackups` choice to the data folder,
    /// so it's kept out of (or allowed back into) Time Machine and iCloud's device
    /// backup. Best-effort — a failure to write the flag never blocks the app.
    ///
    /// For an install that never chose (key absent) the default applies, so a
    /// folder excluded under the previous "on by default" policy is cleared back
    /// into Time Machine; an explicit stored choice is always respected.
    private func applyBackupExclusion() {
        guard let root = dataRootURL else { return }
        // Skip the write when the folder already matches the policy.
        guard BackupExclusion.isExcluded(at: root) != keepDataOutOfSystemBackups else { return }
        try? BackupExclusion.setExcluded(keepDataOutOfSystemBackups, at: root)
    }

    /// Whether the user has accepted the current version of the Terms/Privacy
    /// Policy. The first-run flow blocks on this, so the app can't be used
    /// without it (and re-appears when the terms version changes).
    var hasAcceptedCurrentLegal: Bool {
        Legal.isAccepted(acceptedLegalVersion)
    }

    /// Record acceptance of the current terms locally: the version and the
    /// moment it was accepted. Writes both to UserDefaults (the gate) and an
    /// append-only receipt in the data folder (`LegalReceipt`). This is a
    /// good-faith on-device record, not tamper-proof proof and not tied to a
    /// person's identity. Defaults are injectable for tests.
    func recordLegalAcceptance(version: String = Legal.currentVersion, at date: Date = Date()) {
        acceptedLegalVersion = version
        acceptedLegalDate = date
        LegalReceipt.append(version: version, at: date, root: dataRootURL, appVersion: Self.appVersionString)
    }

    /// The app's marketing version (CFBundleShortVersionString), for stamping
    /// records. Falls back to "unknown" outside a bundle (e.g. tests).
    static var appVersionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    var whisperModelPath: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aletheia", isDirectory: true)
            .appendingPathComponent(whisperModel.fileName)
    }
}
