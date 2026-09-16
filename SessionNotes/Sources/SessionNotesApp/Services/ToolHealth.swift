import AVFoundation
import Foundation

struct ToolHealthCheck: Identifiable {
    enum Status {
        case ok
        case warning
        case failed
    }

    /// Stable identity of what's being checked, so the guided setup flow can
    /// map a check to a one-click fix without matching on display strings.
    enum Kind {
        case dataFolder
        case microphone
        case screenRecording
        case whisperModel
        case ollama
        case appleIntelligence
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let status: Status
    let detail: String
}

/// Everything the Settings screen (and first-run flow) needs to tell the
/// therapist whether the app is actually ready to record/transcribe/
/// summarize, in plain language, with no assumption she knows what any of
/// these tools are.
@MainActor
enum ToolHealth {
    static func runAllChecks(settings: AppSettings, backend: AssistantBackend, assistant: Assistant) async -> [ToolHealthCheck] {
        async let mic = microphoneCheck()
        async let screen = screenRecordingCheck()
        async let whisperModel = whisperModelCheck(settings: settings)
        async let ai = assistantCheck(settings: settings, backend: backend, assistant: assistant)
        async let dataFolder = dataFolderCheck(settings: settings)
        return await [dataFolder, mic, screen, whisperModel, ai]
    }

    static func dataFolderCheck(settings: AppSettings) -> ToolHealthCheck {
        if let url = settings.dataRootURL {
            return ToolHealthCheck(kind: .dataFolder, title: "Data folder", status: .ok, detail: url.path)
        }
        return ToolHealthCheck(kind: .dataFolder, title: "Data folder", status: .failed, detail: "No folder chosen yet. Open Settings to pick one.")
    }

    static func microphoneCheck() -> ToolHealthCheck {
        switch MicRecorder.permissionStatus {
        case .authorized:
            return ToolHealthCheck(kind: .microphone, title: "Microphone access", status: .ok, detail: "Session Notes can record your voice.")
        case .notDetermined:
            return ToolHealthCheck(kind: .microphone, title: "Microphone access", status: .warning, detail: "You'll be asked to allow this the first time you record.")
        default:
            return ToolHealthCheck(kind: .microphone, title: "Microphone access", status: .failed, detail: "Turn this on in System Settings > Privacy & Security > Microphone.")
        }
    }

    static func screenRecordingCheck() async -> ToolHealthCheck {
        let granted = await SystemAudioCapture.checkPermission()
        if granted {
            return ToolHealthCheck(kind: .screenRecording, title: "Call audio capture", status: .ok, detail: "Session Notes can capture the other side of your call.")
        }
        return ToolHealthCheck(
            kind: .screenRecording,
            title: "Call audio capture",
            status: .failed,
            detail: "Turn this on in System Settings > Privacy & Security > Screen & System Audio Recording, then relaunch Session Notes."
        )
    }

    static func whisperModelCheck(settings: AppSettings) -> ToolHealthCheck {
        let path = settings.whisperModelPath
        if FileManager.default.fileExists(atPath: path.path) {
            return ToolHealthCheck(kind: .whisperModel, title: "Transcription model", status: .ok, detail: "\(settings.whisperModel.displayName) is ready.")
        }
        return ToolHealthCheck(kind: .whisperModel, title: "Transcription model", status: .failed, detail: "Not downloaded yet. Open Settings to download it (about \(settings.whisperModel.approximateSizeMB) MB).")
    }

    /// Reports on whichever backend will actually run (see
    /// `Integrations.effectiveAssistantBackend`), so the guidance matches what
    /// the user needs to do — nothing at all on Apple Intelligence, or the
    /// Ollama install/model steps otherwise.
    static func assistantCheck(settings: AppSettings, backend: AssistantBackend, assistant: Assistant) async -> ToolHealthCheck {
        switch backend {
        case .appleIntelligence:
            if Integrations.appleIntelligenceAvailable {
                return ToolHealthCheck(kind: .appleIntelligence, title: "AI summaries & chat", status: .ok, detail: "Apple Intelligence is ready — nothing to install.")
            }
            // Shouldn't normally happen (the backend only resolves to Apple
            // Intelligence when it's available), but guard the race anyway.
            return ToolHealthCheck(kind: .appleIntelligence, title: "AI summaries & chat", status: .failed, detail: "Turn on Apple Intelligence in System Settings › Apple Intelligence & Siri, then reload this screen.")
        case .ollama, .automatic, .localLlama:
            return await ollamaCheck(settings: settings, assistant: assistant)
        }
    }

    static func ollamaCheck(settings: AppSettings, assistant: Assistant) async -> ToolHealthCheck {
        guard await assistant.isReachable() else {
            return ToolHealthCheck(kind: .ollama, title: "AI summaries & chat", status: .failed, detail: "Can't reach Ollama. Open the Ollama app first, then reload this screen.")
        }
        let hasModel = await assistant.hasModel(settings.ollamaModelName)
        if hasModel {
            return ToolHealthCheck(kind: .ollama, title: "AI summaries & chat", status: .ok, detail: "\(settings.ollamaModelName) is ready.")
        }
        return ToolHealthCheck(kind: .ollama, title: "AI summaries & chat", status: .warning, detail: "Ollama is running, but \(settings.ollamaModelName) isn't downloaded yet. Open Settings to download it.")
    }
}
