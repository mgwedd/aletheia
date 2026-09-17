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

    /// Low-level LLM adapter, chosen by the resolved backend (see
    /// `effectiveAssistantBackend`). Apple Intelligence is preferred where it's
    /// supported because it needs no install or model download; otherwise the
    /// app uses Ollama. The embedded llama.cpp runtime is staged and, until it
    /// ships, resolves back to Ollama here.
    func makeAssistant() -> Assistant {
        switch effectiveAssistantBackend {
        case .appleIntelligence:
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) { return FoundationModelsAssistant() }
            #endif
            return OllamaClient(baseURL: settings.ollamaBaseURL)
        case .localLlama:
            #if canImport(llama)
            if LlamaRuntime.isAvailable(model: settings.llamaModel) {
                return LlamaAssistant(modelURL: LlamaRuntime.modelURL(for: settings.llamaModel))
            }
            #endif
            // Runtime not linked (default today) or model not downloaded: fall
            // back to Ollama. Flipping this on is just adding the pinned
            // llama.cpp package — see README › Embedded llama.cpp.
            return OllamaClient(baseURL: settings.ollamaBaseURL)
        case .ollama, .automatic:
            return OllamaClient(baseURL: settings.ollamaBaseURL)
        }
    }

    /// The backend that `makeAssistant()` will actually use, after resolving the
    /// user's preference against what this Mac supports. The Settings and setup
    /// screens read this so they describe (and troubleshoot) the real backend.
    var effectiveAssistantBackend: AssistantBackend {
        AssistantBackendResolver(
            appleIntelligenceAvailable: Self.appleIntelligenceAvailable,
            localLlamaAvailable: LlamaRuntime.isAvailable(model: settings.llamaModel)
        ).resolve(settings.assistantBackend)
    }

    /// Whether Apple's Foundation Models are usable on this machine right now.
    /// False on any toolchain/SDK without the framework (so it's false in CI).
    static var appleIntelligenceAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return FoundationModelsAssistant.isAvailable }
        #endif
        return false
    }

    /// The use-case layer over the LLM adapter, preconfigured with the
    /// currently selected model. This is what summary/chat call sites use.
    func makeAssistantService() -> AssistantService {
        AssistantService(assistant: makeAssistant(), model: settings.ollamaModelName, systemPrompt: settings.systemPrompt)
    }

    /// System notifications (transcript/summary ready). Created once so the
    /// same authorization state is reused.
    private let notifier: AppNotifying = UserNotificationService()

    func makeNotifier() -> AppNotifying {
        notifier
    }

    /// Follow-up reminders into the user's Reminders app (EventKit).
    func makeReminderScheduler() -> ReminderScheduling {
        EventKitReminderScheduler()
    }

    /// Next-session events into the user's Calendar (EventKit).
    func makeCalendarScheduler() -> CalendarScheduling {
        EventKitCalendarScheduler()
    }
}
