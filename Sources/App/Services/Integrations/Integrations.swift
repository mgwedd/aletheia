import Foundation

/// The single place the app decides which concrete integration backs each
/// adapter. Views ask this registry for a `Transcribing` engine or an
/// `AssistantService`; they never construct `WhisperTranscriber` or
/// `LlamaAssistant` directly. Swapping an integration — a different LLM
/// backend, a different transcription engine — means changing one factory
/// method here, not hunting through the UI.
///
/// It reads current configuration from `AppSettings` at call time, so a
/// changed model choice takes effect on the next request without
/// rebuilding anything.
@MainActor
final class Integrations: ObservableObject {
    private let settings: AppSettings
    /// Serializes every LLM generation (notes and both chats) so a new request
    /// waits for the running one instead of hanging behind it in the model.
    let inferenceQueue = InferenceQueue()
    /// Builds session digests in the background, at low priority on the queue.
    let digests: DigestBuilder
    /// Decides which sessions get a summary, and when (`DigestScheduler`).
    let digestScheduler: DigestScheduler

    init(settings: AppSettings) {
        self.settings = settings
        self.digests = DigestBuilder(queue: inferenceQueue)
        self.digestScheduler = DigestScheduler(builder: digests, queue: inferenceQueue, settings: settings)
    }

    /// Speech-to-text: whisper.cpp with Metal (see `WhisperTranscriber`).
    func makeTranscriber() -> Transcribing {
        WhisperTranscriber(modelPath: settings.whisperModelPath)
    }

    /// Low-level LLM adapter, chosen by the resolved backend (see
    /// `effectiveAssistantBackend`): the built-in llama.cpp engine, or, in a
    /// build without it, an assistant that reports the model as unavailable.
    func makeAssistant() -> Assistant {
        switch effectiveAssistantBackend {
        case .appleIntelligence:
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) { return FoundationModelsAssistant() }
            #endif
            return builtInAssistant()
        case .localLlama, .automatic:
            return builtInAssistant()
        }
    }

    private func builtInAssistant() -> Assistant {
        #if canImport(llama)
        return LlamaAssistant(modelURL: llamaModelURL)
        #else
        return UnavailableAssistant()
        #endif
    }

    /// The active backend's model name.
    /// Keys measured speeds and names the model in status and support text.
    var activeModelName: String { EngineStatusProbe.modelName(for: effectiveAssistantBackend, settings: settings) }

    /// The built-in model the user chose, and where its weights live.
    var llamaModel: LlamaModel { settings.llamaModel }
    var llamaModelURL: URL { LlamaRuntime.modelURL(for: settings.llamaModel) }

    /// Downloads the chosen built-in model (joining a download already running).
    func downloadBuiltInModel(onProgress: @escaping (Double) -> Void = { _ in }) async throws {
        try await LlamaModelDownloader.shared.download(settings.llamaModel, to: llamaModelURL, onProgress: onProgress)
    }

    /// Measured speeds for the active model, once it has run here.
    var modelSpeed: ModelSpeed { settings.speed(for: activeModelName) }

    /// The backend that `makeAssistant()` will actually use, after resolving the
    /// user's preference against what this Mac supports. The Settings and setup
    /// screens read this so they describe (and troubleshoot) the real backend.
    var effectiveAssistantBackend: AssistantBackend {
        AssistantBackendResolver(
            appleIntelligenceAvailable: Self.appleIntelligenceAvailable
        ).resolve(settings.assistantBackend)
    }

    /// Apple Intelligence is intentionally disabled for now. Apple is moving Siri
    /// / system intelligence toward a Google Gemini backhaul, and for PHI this app
    /// only uses a backend it can prove stays on this Mac (the built-in
    /// llama.cpp engine). The on-device Foundation Models API doesn't itself use that
    /// cloud path, but we keep the guarantee simple and provable by not depending
    /// on Apple's stack. Set this to `false` to re-enable the on-device path.
    static let appleIntelligenceBlocked = true

    /// Whether Apple's Foundation Models are usable on this machine right now.
    /// False on any toolchain/SDK without the framework (so it's false in CI),
    /// and false whenever `appleIntelligenceBlocked` is set — so the resolver
    /// never selects it and `Automatic` stays fully local.
    static var appleIntelligenceAvailable: Bool {
        if appleIntelligenceBlocked { return false }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return FoundationModelsAssistant.isAvailable }
        #endif
        return false
    }

    /// The use-case layer over the LLM adapter, preconfigured with the
    /// currently selected model. This is what summary/chat call sites use.
    /// `report` hears about the run (see `ChatStreamRunner.reporter`); a finished
    /// run also updates this model's measured speeds.
    func makeAssistantService(report: (@Sendable (AIRunEvent) -> Void)? = nil, clientName: String = "") -> AssistantService {
        let settings = settings
        let model = activeModelName
        var service = AssistantService(assistant: makeAssistant(), model: model, systemPrompt: settings.systemPrompt)
        service.clientName = clientName
        service.report = { event in
            if case .finished(let stats) = event {
                Task { @MainActor in settings.recordSpeeds(model: model, from: stats) }
            }
            report?(event)
        }
        return service
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
