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
        case calendar
        case reminders
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
    /// - Parameter authoritative: when true (an explicit refresh, first appear,
    ///   or an app-activation refresh), the Screen Recording check confirms a
    ///   live grant with `SCShareableContent` so a permission just toggled on is
    ///   seen without relaunch. The fast background poll passes `false` to stay
    ///   on the cheap, never-prompting preflight.
    static func runAllChecks(
        settings: AppSettings,
        backend: AssistantBackend,
        assistant: Assistant,
        authoritative: Bool = true,
        includeScheduling: Bool = true
    ) async -> [ToolHealthCheck] {
        // The AI check hits the network; run it concurrently with the (also
        // async) screen-recording probe. The rest are cheap local reads.
        async let ai = assistantCheck(settings: settings, backend: backend, assistant: assistant)
        let mic = microphoneCheck()
        let whisperModel = whisperModelCheck(settings: settings)
        let dataFolder = dataFolderCheck(settings: settings)
        let screen = await screenRecordingCheck(authoritative: authoritative)
        var checks = await [dataFolder, mic, screen, whisperModel, ai]
        // Calendar/Reminders belong to the `.dev`-tier EventKit scheduling
        // module. When that module isn't in the build, don't surface (or ask
        // for) their permissions at all. See `EventKitSchedulingFeatureModule`.
        if includeScheduling {
            checks.append(calendarCheck())
            checks.append(remindersCheck())
        }
        return checks
    }

    static func dataFolderCheck(settings: AppSettings) -> ToolHealthCheck {
        if let url = settings.dataRootURL {
            return ToolHealthCheck(kind: .dataFolder, title: "Data folder", status: .ok, detail: url.path)
        }
        return ToolHealthCheck(kind: .dataFolder, title: "Data folder", status: .failed, detail: "No folder chosen yet. Open Settings to pick one.")
    }

    static func microphoneCheck() -> ToolHealthCheck {
        classifyMicrophone(MicRecorder.permissionStatus)
    }

    /// Pure mapping from the raw microphone authorization to a check row, split
    /// out so the granted→OK / denied→failed logic is unit-testable without the
    /// system permission API.
    static func classifyMicrophone(_ status: AVAuthorizationStatus) -> ToolHealthCheck {
        switch status {
        case .authorized:
            return ToolHealthCheck(kind: .microphone, title: "Microphone access", status: .ok, detail: "Aletheia can record your voice.")
        case .notDetermined:
            return ToolHealthCheck(kind: .microphone, title: "Microphone access", status: .warning, detail: "You'll be asked to allow this the first time you record.")
        default:
            return ToolHealthCheck(kind: .microphone, title: "Microphone access", status: .failed, detail: "Turn this on in System Settings > Privacy & Security > Microphone.")
        }
    }

    static func screenRecordingCheck(authoritative: Bool) async -> ToolHealthCheck {
        // Cheap non-prompting preflight first; only fall back to the live,
        // possibly-prompting SCShareableContent probe on an authoritative refresh
        // (which is exactly when the user has just come back from granting it).
        var granted = SystemAudioCapture.checkPermission()
        if !granted && authoritative {
            granted = await SystemAudioCapture.verifyAccessGranted()
        }
        return classifyScreenRecording(granted: granted)
    }

    /// Pure mapping from "is call-audio capture granted?" to a check row.
    static func classifyScreenRecording(granted: Bool) -> ToolHealthCheck {
        if granted {
            return ToolHealthCheck(kind: .screenRecording, title: "Call audio capture", status: .ok, detail: "Aletheia can capture the other side of your call.")
        }
        return ToolHealthCheck(
            kind: .screenRecording,
            title: "Call audio capture",
            status: .failed,
            detail: "Click Allow to grant Screen & System Audio Recording. This updates here as soon as you approve — no restart needed."
        )
    }

    /// Calendar and Reminders are optional conveniences ("Schedule Next Session"
    /// and "Remind Me"). They never block readiness — an unmet one is a warning,
    /// not a failure — but surfacing them in setup lets the therapist grant
    /// access once, up front, instead of being interrupted mid-task later.
    static func calendarCheck() -> ToolHealthCheck {
        optionalAccessCheck(
            kind: .calendar,
            title: "Calendar (optional)",
            feature: .calendar,
            grantedDetail: "Can add “Schedule Next Session” events to your calendar.",
            featureName: "Schedule Next Session"
        )
    }

    static func remindersCheck() -> ToolHealthCheck {
        optionalAccessCheck(
            kind: .reminders,
            title: "Reminders (optional)",
            feature: .reminders,
            grantedDetail: "Can add session follow-ups to your Reminders.",
            featureName: "Remind Me"
        )
    }

    private static func optionalAccessCheck(
        kind: ToolHealthCheck.Kind,
        title: String,
        feature: EventKitAccess.Feature,
        grantedDetail: String,
        featureName: String
    ) -> ToolHealthCheck {
        switch EventKitAccess.status(feature) {
        case .granted:
            return ToolHealthCheck(kind: kind, title: title, status: .ok, detail: grantedDetail)
        case .unavailable:
            return ToolHealthCheck(kind: kind, title: title, status: .warning, detail: "Not available on this Mac — “\(featureName)” will stay off.")
        case .notDetermined, .denied:
            return ToolHealthCheck(kind: kind, title: title, status: .warning, detail: "Optional. Allow to use “\(featureName).” If you skip it, that feature stays off — you can turn it on anytime.")
        }
    }

    static func whisperModelCheck(settings: AppSettings) -> ToolHealthCheck {
        classifyWhisperModel(
            exists: FileManager.default.fileExists(atPath: settings.whisperModelPath.path),
            modelDisplayName: settings.whisperModel.displayName,
            sizeMB: settings.whisperModel.approximateSizeMB
        )
    }

    /// Pure mapping from "is the transcription model on disk?" to a check row.
    static func classifyWhisperModel(exists: Bool, modelDisplayName: String, sizeMB: Int) -> ToolHealthCheck {
        if exists {
            return ToolHealthCheck(kind: .whisperModel, title: "Transcription model", status: .ok, detail: "\(modelDisplayName) is ready.")
        }
        return ToolHealthCheck(kind: .whisperModel, title: "Transcription model", status: .failed, detail: "Not downloaded yet. Open Settings to download it (about \(sizeMB) MB).")
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
        let reachable = await assistant.isReachable()
        var hasModel = false
        if reachable {
            hasModel = await assistant.hasModel(settings.ollamaModelName)
        }
        return classifyOllama(reachable: reachable, hasModel: hasModel, modelName: settings.ollamaModelName)
    }

    /// Pure mapping from Ollama reachability + model presence to a check row.
    static func classifyOllama(reachable: Bool, hasModel: Bool, modelName: String) -> ToolHealthCheck {
        guard reachable else {
            return ToolHealthCheck(kind: .ollama, title: "AI summaries & chat", status: .failed, detail: "Can't reach Ollama, the free local AI engine Aletheia runs on. Install it (once) and keep it running, then this turns green on its own.")
        }
        if hasModel {
            return ToolHealthCheck(kind: .ollama, title: "AI summaries & chat", status: .ok, detail: "\(modelName) is ready.")
        }
        return ToolHealthCheck(kind: .ollama, title: "AI summaries & chat", status: .warning, detail: "Ollama is running, but the \(modelName) model isn't downloaded yet. Use “Download” here — it downloads inside Aletheia.")
    }
}
