import Foundation

/// The one-click fix that helps when a setup requirement isn't satisfied.
enum SetupAction: Equatable {
    case chooseFolder
    case requestMicrophone
    case openMicrophoneSettings
    case requestScreenRecording
    case openScreenRecordingSettings
    case downloadTranscriptionModel
    case installOrOpenOllama
    case launchOllama
    case downloadOllamaModel
    case enableAppleIntelligence
    case requestCalendarAccess
    case requestRemindersAccess

    var label: String {
        switch self {
        case .chooseFolder: return "Choose Folder…"
        case .requestMicrophone: return "Allow Microphone"
        case .openMicrophoneSettings: return "Open Settings"
        case .requestScreenRecording: return "Allow"
        case .openScreenRecordingSettings: return "Open Settings"
        case .downloadTranscriptionModel: return "Download"
        case .installOrOpenOllama: return "Get Ollama"
        case .launchOllama: return "Launch Ollama"
        case .downloadOllamaModel: return "Download Model"
        case .enableAppleIntelligence: return "Open Settings"
        case .requestCalendarAccess: return "Allow"
        case .requestRemindersAccess: return "Allow"
        }
    }
}

struct SetupItem: Identifiable {
    let id: UUID
    let check: ToolHealthCheck
    let action: SetupAction?

    var status: ToolHealthCheck.Status { check.status }
    var title: String { check.title }
    var detail: String { check.detail }
}

/// Maps the tool-health checks into a guided checklist, choosing the fix for
/// each unmet requirement. Pure logic so the mapping is unit-tested; the view
/// just renders items and dispatches their actions.
enum Setup {
    static func action(for check: ToolHealthCheck) -> SetupAction? {
        switch (check.kind, check.status) {
        case (_, .ok):
            return nil
        case (.dataFolder, _):
            return .chooseFolder
        case (.microphone, .warning):
            return .requestMicrophone       // not yet asked — trigger the prompt
        case (.microphone, .failed):
            return .openMicrophoneSettings   // previously denied — send to Settings
        case (.screenRecording, _):
            // One button that asks for access with a single system prompt; if
            // it was previously denied (macOS won't re-prompt), the handler
            // falls back to opening System Settings.
            return .requestScreenRecording
        case (.whisperModel, _):
            return .downloadTranscriptionModel
        case (.ollama, .failed):
            // Not reachable: send to the download page only when it's actually
            // missing, otherwise launch the already-installed app. An
            // `.ollama` check built without `ollamaState` (e.g. an older
            // caller, or a test fixture) falls back to the old "install"
            // action rather than guessing it's already there.
            return check.ollamaState == .installedNotRunning ? .launchOllama : .installOrOpenOllama
        case (.ollama, .warning):
            return .downloadOllamaModel      // running, model missing
        case (.appleIntelligence, .failed):
            return .enableAppleIntelligence  // supported but turned off
        case (.appleIntelligence, .warning):
            return nil                       // e.g. model still downloading — nothing to click
        case (.calendar, _):
            return .requestCalendarAccess    // optional; asks once, falls back to Settings if denied
        case (.reminders, _):
            return .requestRemindersAccess
        }
    }

    static func items(from checks: [ToolHealthCheck]) -> [SetupItem] {
        checks.map { SetupItem(id: $0.id, check: $0, action: action(for: $0)) }
    }

    /// Nothing is in a failed state — the app can record, transcribe, and
    /// summarize. Warnings (mic not yet prompted, model still downloading) are
    /// not failures, so they don't block finishing setup.
    static func isReady(_ checks: [ToolHealthCheck]) -> Bool {
        !checks.contains { $0.status == .failed }
    }
}
