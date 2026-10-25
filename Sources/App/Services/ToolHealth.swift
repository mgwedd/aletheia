import AVFoundation
import Foundation

struct ToolHealthCheck: Identifiable, Equatable {
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
        case builtInModel
        case appleIntelligence
        case calendar
        case reminders
        case termsAndPrivacy
    }

    /// Stable per check kind. A fresh UUID per run made every periodic refresh
    /// look like all-new rows to SwiftUI, which rebuilt the list (visible jitter).
    var id: Kind { kind }
    let kind: Kind
    let title: String
    let status: Status
    let detail: String
    init(kind: Kind, title: String, status: Status, detail: String) {
        self.kind = kind
        self.title = title
        self.status = status
        self.detail = detail
    }
}

/// Everything the Settings screen (and first-run flow) needs to tell the
/// therapist whether the app is actually ready to record/transcribe/
/// summarize, in plain language, with no assumption she knows what any of
/// these tools are.
@MainActor
enum ToolHealth {
    /// The system facts the checks read. Live by default; tests substitute fakes
    /// so the whole run can be checked without real permissions.
    @MainActor struct Probes {
        var microphoneStatus: () -> AVAuthorizationStatus = { MicRecorder.permissionStatus }
        var eventKitStatus: (EventKitAccess.Feature) -> EventKitAccess.Status = { EventKitAccess.status($0) }
        var appleIntelligenceAvailable: () -> Bool = { Integrations.appleIntelligenceAvailable }
        /// Whether call-audio capture is granted; `authoritative` as for `runAllChecks`.
        var screenRecording: (_ authoritative: Bool) async -> ToolHealthCheck = {
            await ToolHealth.screenRecordingCheck(authoritative: $0)
        }

        static let live = Probes()
    }

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
        includeScheduling: Bool = true,
        probes: Probes = .live
    ) async -> [ToolHealthCheck] {
        // The AI check hits the network; run it concurrently with the (also
        // async) screen-recording probe. The rest are cheap local reads.
        async let ai = assistantCheck(
            settings: settings, backend: backend, assistant: assistant,
            appleIntelligenceAvailable: probes.appleIntelligenceAvailable())
        let terms = termsAndPrivacyCheck(settings: settings)
        let mic = microphoneCheck(status: probes.microphoneStatus())
        let whisperModel = whisperModelCheck(settings: settings)
        let dataFolder = dataFolderCheck(settings: settings)
        let screen = await probes.screenRecording(authoritative)
        var checks = await [terms, dataFolder, mic, screen, whisperModel, ai]
        // Calendar/Reminders belong to the `.dev`-tier EventKit scheduling
        // module. When that module isn't in the build, don't surface (or ask
        // for) their permissions at all. See `EventKitSchedulingFeatureModule`.
        if includeScheduling {
            checks.append(calendarCheck(status: probes.eventKitStatus(.calendar)))
            checks.append(remindersCheck(status: probes.eventKitStatus(.reminders)))
        }
        return checks
    }

    static func classifyTermsAndPrivacy(isAccepted: Bool) -> ToolHealthCheck {
        if isAccepted {
            return ToolHealthCheck(
                kind: .termsAndPrivacy,
                title: "Terms & Privacy",
                status: .ok,
                detail: "Terms of Service and Privacy Policy accepted."
            )
        }
        return ToolHealthCheck(
            kind: .termsAndPrivacy,
            title: "Terms & Privacy",
            status: .warning,
            detail: "Review and accept the Terms of Service and Privacy Policy."
        )
    }

    static func termsAndPrivacyCheck(settings: AppSettings) -> ToolHealthCheck {
        classifyTermsAndPrivacy(isAccepted: Legal.isAccepted(settings.acceptedLegalVersion))
    }

    static func dataFolderCheck(settings: AppSettings) -> ToolHealthCheck {
        if let url = settings.dataRootURL {
            return ToolHealthCheck(kind: .dataFolder, title: "Data folder", status: .ok, detail: url.path)
        }
        return ToolHealthCheck(kind: .dataFolder, title: "Data folder", status: .failed, detail: "No folder chosen yet. Open Settings to pick one.")
    }

    static func microphoneCheck(status: AVAuthorizationStatus = MicRecorder.permissionStatus) -> ToolHealthCheck {
        classifyMicrophone(status)
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

    static func screenRecordingCheck(
        authoritative: Bool,
        grantStore: CallAudioGrantStore = .standard
    ) async -> ToolHealthCheck {
        // Cheap non-prompting preflight first; only fall back to the live,
        // possibly-prompting SCShareableContent probe on an authoritative refresh
        // (which is exactly when the user has just come back from granting it).
        // A grant confirmed for this build in an earlier session counts too:
        // the preflight forgets grants it can't tie to this process.
        var granted = SystemAudioCapture.checkPermission() || grantStore.isConfirmed
        // The live probe can show the system dialog, so it runs only once after
        // the user has acted on the permission (see `ScreenAccessProbeGate`),
        // never on plain appear/activation refreshes.
        if !granted && authoritative && ScreenAccessProbeGate.consume() {
            granted = await SystemAudioCapture.verifyAccessGranted()
        }
        if granted { grantStore.confirm() }
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
    static func calendarCheck(status: EventKitAccess.Status = EventKitAccess.status(.calendar)) -> ToolHealthCheck {
        optionalAccessCheck(
            status: status,
            kind: .calendar,
            title: "Calendar (optional)",
            grantedDetail: "Can add “Schedule Next Session” events to your calendar.",
            featureName: "Schedule Next Session"
        )
    }

    static func remindersCheck(status: EventKitAccess.Status = EventKitAccess.status(.reminders)) -> ToolHealthCheck {
        optionalAccessCheck(
            status: status,
            kind: .reminders,
            title: "Reminders (optional)",
            grantedDetail: "Can add session follow-ups to your Reminders.",
            featureName: "Remind Me"
        )
    }

    static func optionalAccessCheck(
        status: EventKitAccess.Status,
        kind: ToolHealthCheck.Kind,
        title: String,
        grantedDetail: String,
        featureName: String
    ) -> ToolHealthCheck {
        switch status {
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
    /// built-in model download otherwise.
    static func assistantCheck(
        settings: AppSettings,
        backend: AssistantBackend,
        assistant: Assistant,
        appleIntelligenceAvailable: Bool? = nil
    ) async -> ToolHealthCheck {
        switch backend {
        case .appleIntelligence:
            if appleIntelligenceAvailable ?? Integrations.appleIntelligenceAvailable {
                return ToolHealthCheck(kind: .appleIntelligence, title: "AI summaries & chat", status: .ok, detail: "Apple Intelligence is ready — nothing to install.")
            }
            // Shouldn't normally happen (the backend only resolves to Apple
            // Intelligence when it's available), but guard the race anyway.
            return ToolHealthCheck(kind: .appleIntelligence, title: "AI summaries & chat", status: .failed, detail: "Turn on Apple Intelligence in System Settings › Apple Intelligence & Siri, then reload this screen.")
        case .localLlama:
            return builtInModelCheck(settings: settings)
        case .automatic:
            return builtInModelCheck(settings: settings)
        }
    }

    static func builtInModelCheck(settings: AppSettings) -> ToolHealthCheck {
        classifyBuiltInModel(
            installed: FileManager.default.fileExists(atPath: LlamaRuntime.modelURL(for: settings.llamaModel).path),
            modelName: settings.llamaModel.shortName,
            sizeMB: settings.llamaModel.approximateSizeMB
        )
    }

    /// Pure mapping from "is the built-in model on disk?" to a check row.
    static func classifyBuiltInModel(installed: Bool, modelName: String, sizeMB: Int) -> ToolHealthCheck {
        if installed {
            return ToolHealthCheck(kind: .builtInModel, title: "AI summaries & chat", status: .ok, detail: "\(modelName) is ready, built into Aletheia.")
        }
        return ToolHealthCheck(kind: .builtInModel, title: "AI summaries & chat", status: .failed, detail: "Download the AI model (\(modelName), about \(sizeMB) MB). It runs inside Aletheia on this Mac; nothing else to install.")
    }
}
