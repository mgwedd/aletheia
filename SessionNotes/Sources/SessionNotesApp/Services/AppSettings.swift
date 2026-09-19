import Foundation

/// Whisper model choices, ordered smallest/fastest to largest/most accurate.
/// SwiftWhisper runs entirely on-device (no network, no CLI); on an Apple
/// Silicon MacBook Air, `small.en` is a good balance of speed and accuracy
/// for CPU-only inference. Larger models are slower per minute of audio.
enum WhisperModel: String, CaseIterable, Identifiable, Codable, Hashable {
    case baseEn = "base.en"
    case smallEn = "small.en"
    case mediumEn = "medium.en"
    case largeV3 = "large-v3"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .baseEn: return "Base (English) — fastest, least accurate"
        case .smallEn: return "Small (English) — recommended"
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

    var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-\(rawValue).bin")!
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

    /// 15 minutes: short enough to matter for a clinician stepping away
    /// mid-session, long enough not to interrupt writing a note.
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
        static let ollamaModelName = "ollamaModelName"
        static let systemPrompt = "systemPrompt"
        static let ollamaBaseURL = "ollamaBaseURL"
        static let hasCompletedFirstRun = "hasCompletedFirstRun"
        static let updateFeedURL = "updateFeedURL"
        static let spotlightIndexingEnabled = "spotlightIndexingEnabled"
        static let appLockEnabled = "appLockEnabled"
        static let idleAutoLockMinutes = "idleAutoLockMinutes"
        static let acceptedLegalVersion = "acceptedLegalVersion"
        static let acceptedLegalDate = "acceptedLegalDate"
        static let progressNoteFormat = "progressNoteFormat"
        static let localEncryptedBackupEnabled = "localEncryptedBackupEnabled"
        static let iCloudEncryptedBackupEnabled = "iCloudEncryptedBackupEnabled"
    }

    /// Where the app looks for its update manifest. Defaults to the
    /// `appcast.json` asset of the repo's latest GitHub release; until a
    /// release publishes one, the check just finds nothing (no error shown).
    static let defaultUpdateFeedURL = URL(string: "https://github.com/mgwedd/aletheia/releases/latest/download/appcast.json")!

    private let defaults = UserDefaults.standard

    @Published var dataRootURL: URL?
    @Published var whisperModel: WhisperModel {
        didSet { defaults.set(whisperModel.rawValue, forKey: Keys.whisperModel) }
    }
    @Published var assistantBackend: AssistantBackend {
        didSet { defaults.set(assistantBackend.rawValue, forKey: Keys.assistantBackend) }
    }
    @Published var llamaModel: LlamaModel {
        didSet { defaults.set(llamaModel.rawValue, forKey: Keys.llamaModel) }
    }
    @Published var ollamaModelName: String {
        didSet { defaults.set(ollamaModelName, forKey: Keys.ollamaModelName) }
    }
    /// The system prompt prepended to every LLM request. Defaults to
    /// `Prompts.defaultSystemPrompt`; fully editable (and resettable) in Settings.
    @Published var systemPrompt: String {
        didSet { defaults.set(systemPrompt, forKey: Keys.systemPrompt) }
    }
    @Published var ollamaBaseURL: URL {
        didSet { defaults.set(ollamaBaseURL.absoluteString, forKey: Keys.ollamaBaseURL) }
    }
    @Published var hasCompletedFirstRun: Bool {
        didSet { defaults.set(hasCompletedFirstRun, forKey: Keys.hasCompletedFirstRun) }
    }
    @Published var updateFeedURL: URL {
        didSet { defaults.set(updateFeedURL.absoluteString, forKey: Keys.updateFeedURL) }
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
    /// HIPAA §164.312(a)(2)(iii) "automatic logoff": how many minutes of
    /// inactivity before `AppLock` re-engages, one of `IdleAutoLockTimeout`'s
    /// `allCases` values. `0` means "Never" (idle auto-lock off). Only takes
    /// effect while `appLockEnabled` is on — locking requires the Touch ID /
    /// password gate to exist in the first place.
    @Published var idleAutoLockMinutes: Int {
        didSet { defaults.set(idleAutoLockMinutes, forKey: Keys.idleAutoLockMinutes) }
    }
    /// The clinical documentation format the "Generate note" action defaults to.
    /// Free text out of the box (`ProgressNoteFormat.default`); a therapist who
    /// wants a payer-ready structure picks SOAP/DAP/BIRP here or per session.
    @Published var progressNoteFormat: ProgressNoteFormat {
        didSet { defaults.set(progressNoteFormat.rawValue, forKey: Keys.progressNoteFormat) }
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

    private init() {
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
        if let raw = defaults.string(forKey: Keys.assistantBackend), let backend = AssistantBackend(rawValue: raw) {
            assistantBackend = backend
        } else {
            assistantBackend = .automatic
        }
        if let raw = defaults.string(forKey: Keys.llamaModel), let model = LlamaModel(rawValue: raw) {
            llamaModel = model
        } else {
            llamaModel = .llama32_3b
        }
        ollamaModelName = defaults.string(forKey: Keys.ollamaModelName) ?? recommendation.ollamaModel
        let savedPrompt = defaults.string(forKey: Keys.systemPrompt)
        systemPrompt = (savedPrompt?.isEmpty == false) ? savedPrompt! : Prompts.defaultSystemPrompt
        if let raw = defaults.string(forKey: Keys.ollamaBaseURL), let url = URL(string: raw) {
            ollamaBaseURL = url
        } else {
            ollamaBaseURL = URL(string: "http://127.0.0.1:11434")!
        }
        hasCompletedFirstRun = defaults.bool(forKey: Keys.hasCompletedFirstRun)
        localEncryptedBackupEnabled = defaults.bool(forKey: Keys.localEncryptedBackupEnabled)
        iCloudEncryptedBackupEnabled = defaults.bool(forKey: Keys.iCloudEncryptedBackupEnabled)
        spotlightIndexingEnabled = defaults.bool(forKey: Keys.spotlightIndexingEnabled)
        appLockEnabled = defaults.bool(forKey: Keys.appLockEnabled)
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
        acceptedLegalVersion = defaults.string(forKey: Keys.acceptedLegalVersion) ?? ""
        let acceptedInterval = defaults.double(forKey: Keys.acceptedLegalDate)
        acceptedLegalDate = acceptedInterval > 0 ? Date(timeIntervalSince1970: acceptedInterval) : nil
        if let raw = defaults.string(forKey: Keys.updateFeedURL), let url = URL(string: raw) {
            updateFeedURL = url
        } else {
            updateFeedURL = AppSettings.defaultUpdateFeedURL
        }
        dataRootURL = SecurityScopedBookmark.resolve(key: Keys.dataRootBookmark)
    }

    /// Called after the user picks (or creates) the data folder via NSOpenPanel.
    /// Persists a security-scoped bookmark so the sandboxed app can keep
    /// reading/writing that folder on future launches without re-prompting.
    func setDataRoot(_ url: URL) throws {
        try SecurityScopedBookmark.save(url: url, key: Keys.dataRootBookmark)
        dataRootURL = url
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
            .appendingPathComponent("SessionNotes", isDirectory: true)
            .appendingPathComponent(whisperModel.fileName)
    }
}
