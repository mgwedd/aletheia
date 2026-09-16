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
        static let ollamaModelName = "ollamaModelName"
        static let ollamaBaseURL = "ollamaBaseURL"
        static let hasCompletedFirstRun = "hasCompletedFirstRun"
        static let updateFeedURL = "updateFeedURL"
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
    @Published var ollamaModelName: String {
        didSet { defaults.set(ollamaModelName, forKey: Keys.ollamaModelName) }
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

    private init() {
        if let raw = defaults.string(forKey: Keys.whisperModel), let model = WhisperModel(rawValue: raw) {
            whisperModel = model
        } else {
            whisperModel = .smallEn
        }
        ollamaModelName = defaults.string(forKey: Keys.ollamaModelName) ?? "llama3.1:8b"
        if let raw = defaults.string(forKey: Keys.ollamaBaseURL), let url = URL(string: raw) {
            ollamaBaseURL = url
        } else {
            ollamaBaseURL = URL(string: "http://127.0.0.1:11434")!
        }
        hasCompletedFirstRun = defaults.bool(forKey: Keys.hasCompletedFirstRun)
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

    var whisperModelPath: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SessionNotes", isDirectory: true)
            .appendingPathComponent(whisperModel.fileName)
    }
}
