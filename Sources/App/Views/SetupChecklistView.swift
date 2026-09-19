import SwiftUI

/// A guided checklist that shows each setup requirement with a one-click fix,
/// so the therapist never has to hunt through docs or Terminal. Used on first
/// run and reachable again from Settings.
struct SetupChecklistView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var integrations: Integrations

    @StateObject private var whisperDownloader = WhisperModelDownloader()
    @State private var items: [SetupItem] = []
    @State private var isChecking = false
    @State private var busyAction: SetupAction?
    @State private var ollamaPullProgress: Double = 0
    @State private var ollamaPullStatus = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Setup Checklist").font(.headline)
                Spacer()
                if isChecking { ProgressView().controlSize(.small) }
                Text("Updates on its own")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(items) { item in
                row(item)
                if item.id != items.last?.id { Divider() }
            }

            Label(settings.recommendation.summary, systemImage: "cpu")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Everything runs on this Mac. Aletheia's AI uses Ollama — a free local engine you install once — and the AI model then downloads inside Aletheia. This list updates itself as you grant each permission; no restart needed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .liveStatusRefresh { authoritative in await refresh(authoritative: authoritative) }
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func row(_ item: SetupItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            statusIcon(item.status)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.body.weight(.medium))
                Text(item.detail).font(.caption).foregroundStyle(.secondary)
                if item.action == .downloadTranscriptionModel, whisperDownloader.isDownloading {
                    ProgressView(value: whisperDownloader.progress)
                }
                if item.action == .downloadOllamaModel, busyAction == .downloadOllamaModel {
                    ProgressView(value: ollamaPullProgress)
                    Text(ollamaPullStatus).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let action = item.action {
                Button(action.label) { Task { await perform(action) } }
                    .disabled(busyAction != nil || whisperDownloader.isDownloading)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func statusIcon(_ status: ToolHealthCheck.Status) -> some View {
        switch status {
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        case .failed: Image(systemName: "circle").foregroundStyle(.secondary)
        }
    }

    /// Re-runs the checks and updates the rows. Skips a run that would overlap an
    /// in-flight one (the background timer can tick mid-check), so the fast poll
    /// never piles up. `authoritative` is forwarded to the Screen Recording check
    /// so a just-granted permission is confirmed live on appear/activation.
    private func refresh(authoritative: Bool = true) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        items = Setup.items(from: await ToolHealth.runAllChecks(
            settings: settings,
            backend: integrations.effectiveAssistantBackend,
            assistant: integrations.makeAssistant(),
            authoritative: authoritative
        ))
    }

    /// After sending the therapist to grant Screen Recording, watch for the grant
    /// and refresh the checklist the moment it lands — so the row turns green on
    /// its own, with no "quit and relaunch" step. Gives up quietly after a while;
    /// the Refresh button and the next `.task` still catch it later.
    private func pollForScreenRecordingGrant() async {
        for _ in 0..<60 { // ~30s at 0.5s intervals
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
            if await SystemAudioCapture.verifyAccessGranted() {
                await refresh()
                return
            }
        }
    }

    private func perform(_ action: SetupAction) async {
        switch action {
        case .chooseFolder:
            if let url = FolderPicker.choose() {
                do {
                    try settings.setDataRoot(url)
                    appModel.rebuildStore()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        case .requestMicrophone:
            _ = await MicRecorder.requestPermission()
        case .openMicrophoneSettings:
            SystemSettingsLinks.openMicrophoneSettings()
        case .requestScreenRecording:
            // One explicit system prompt. If already granted or the user grants
            // it now, we're done and the live poll flips the row green without a
            // relaunch. If macOS won't prompt (previously denied), send them to
            // the exact Settings pane instead.
            if !SystemAudioCapture.requestPermission() {
                SystemSettingsLinks.openScreenRecordingSettings()
                await pollForScreenRecordingGrant()
            }
        case .openScreenRecordingSettings:
            SystemSettingsLinks.openScreenRecordingSettings()
            await pollForScreenRecordingGrant()
        case .downloadTranscriptionModel:
            do {
                try await whisperDownloader.download(settings.whisperModel, to: settings.whisperModelPath)
            } catch {
                errorMessage = error.localizedDescription
            }
        case .enableAppleIntelligence:
            SystemSettingsLinks.openAppleIntelligenceSettings()
        case .requestCalendarAccess:
            // Ask up front; a prior denial won't re-prompt, so fall back to Settings.
            if await EventKitAccess.request(.calendar) == false,
               EventKitAccess.status(.calendar) == .denied {
                SystemSettingsLinks.openCalendarSettings()
            }
        case .requestRemindersAccess:
            if await EventKitAccess.request(.reminders) == false,
               EventKitAccess.status(.reminders) == .denied {
                SystemSettingsLinks.openRemindersSettings()
            }
        case .installOrOpenOllama:
            SystemSettingsLinks.openOllamaDownload()
        case .downloadOllamaModel:
            busyAction = .downloadOllamaModel
            ollamaPullProgress = 0
            defer { busyAction = nil }
            do {
                try await integrations.makeAssistant().pullModel(settings.ollamaModelName) { progress, status in
                    Task { @MainActor in
                        ollamaPullProgress = progress
                        ollamaPullStatus = status
                    }
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        await refresh()
    }
}
