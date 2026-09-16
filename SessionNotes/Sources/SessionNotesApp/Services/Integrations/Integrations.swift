import Foundation

/// The single place the app decides which concrete integration backs each
/// adapter. Views ask this registry for a `Transcribing` engine or an
/// `AssistantService`; they never construct `WhisperTranscriber` or
/// `OllamaClient` directly. Swapping an integration — a different LLM
/// backend, a different transcription engine — means changing one factory
/// method here, not hunting through the UI.
///
/// It reads current configuration from `AppSettings` at call time, so a
/// changed model name or server URL takes effect on the next request without
/// rebuilding anything.
@MainActor
final class Integrations: ObservableObject {
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    /// Speech-to-text. Currently whisper.cpp via SwiftWhisper.
    func makeTranscriber() -> Transcribing {
        WhisperTranscriber(modelPath: settings.whisperModelPath)
    }

    /// Low-level LLM adapter. Currently a local Ollama server.
    func makeAssistant() -> Assistant {
        OllamaClient(baseURL: settings.ollamaBaseURL)
    }

    /// The use-case layer over the LLM adapter, preconfigured with the
    /// currently selected model. This is what summary/chat call sites use.
    func makeAssistantService() -> AssistantService {
        AssistantService(assistant: makeAssistant(), model: settings.ollamaModelName)
    }
}
