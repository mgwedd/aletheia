import AVFoundation
import Foundation

struct ToolHealthCheck: Identifiable {
    enum Status {
        case ok
        case warning
        case failed
    }

    let id = UUID()
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
    static func runAllChecks(settings: AppSettings) async -> [ToolHealthCheck] {
        async let mic = microphoneCheck()
        async let screen = screenRecordingCheck()
        async let whisperModel = whisperModelCheck(settings: settings)
        async let ollama = ollamaCheck(settings: settings)
        async let dataFolder = dataFolderCheck(settings: settings)
        return await [dataFolder, mic, screen, whisperModel, ollama]
    }

    static func dataFolderCheck(settings: AppSettings) -> ToolHealthCheck {
        if let url = settings.dataRootURL {
            return ToolHealthCheck(title: "Data folder", status: .ok, detail: url.path)
        }
        return ToolHealthCheck(title: "Data folder", status: .failed, detail: "No folder chosen yet. Open Settings to pick one.")
    }

    static func microphoneCheck() -> ToolHealthCheck {
        switch MicRecorder.permissionStatus {
        case .authorized:
            return ToolHealthCheck(title: "Microphone access", status: .ok, detail: "Session Notes can record your voice.")
        case .notDetermined:
            return ToolHealthCheck(title: "Microphone access", status: .warning, detail: "You'll be asked to allow this the first time you record.")
        default:
            return ToolHealthCheck(title: "Microphone access", status: .failed, detail: "Turn this on in System Settings > Privacy & Security > Microphone.")
        }
    }

    static func screenRecordingCheck() async -> ToolHealthCheck {
        let granted = await SystemAudioCapture.checkPermission()
        if granted {
            return ToolHealthCheck(title: "Call audio capture", status: .ok, detail: "Session Notes can capture the other side of your call.")
        }
        return ToolHealthCheck(
            title: "Call audio capture",
            status: .failed,
            detail: "Turn this on in System Settings > Privacy & Security > Screen & System Audio Recording, then relaunch Session Notes."
        )
    }

    static func whisperModelCheck(settings: AppSettings) -> ToolHealthCheck {
        let path = settings.whisperModelPath
        if FileManager.default.fileExists(atPath: path.path) {
            return ToolHealthCheck(title: "Transcription model", status: .ok, detail: "\(settings.whisperModel.displayName) is ready.")
        }
        return ToolHealthCheck(title: "Transcription model", status: .failed, detail: "Not downloaded yet. Open Settings to download it (about \(settings.whisperModel.approximateSizeMB) MB).")
    }

    static func ollamaCheck(settings: AppSettings) async -> ToolHealthCheck {
        let client = OllamaClient(baseURL: settings.ollamaBaseURL)
        guard await client.isReachable() else {
            return ToolHealthCheck(title: "AI summaries & chat", status: .failed, detail: "Can't reach Ollama. Open the Ollama app first, then reload this screen.")
        }
        let hasModel = await client.hasModel(settings.ollamaModelName)
        if hasModel {
            return ToolHealthCheck(title: "AI summaries & chat", status: .ok, detail: "\(settings.ollamaModelName) is ready.")
        }
        return ToolHealthCheck(title: "AI summaries & chat", status: .warning, detail: "Ollama is running, but \(settings.ollamaModelName) isn't downloaded yet. Open Settings to download it.")
    }
}
