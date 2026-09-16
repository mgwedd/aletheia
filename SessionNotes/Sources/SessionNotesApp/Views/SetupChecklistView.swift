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
                Button("Refresh") { Task { await refresh() } }
                    .disabled(isChecking)
            }

            ForEach(items) { item in
                row(item)
                if item.id != items.last?.id { Divider() }
            }

            Text("Everything runs on this Mac. The only thing to install is Ollama; the models download here in the app.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task { await refresh() }
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

    private func refresh() async {
        isChecking = true
        defer { isChecking = false }
        items = Setup.items(from: await ToolHealth.runAllChecks(settings: settings, assistant: integrations.makeAssistant()))
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
        case .openScreenRecordingSettings:
            SystemSettingsLinks.openScreenRecordingSettings()
        case .downloadTranscriptionModel:
            do {
                try await whisperDownloader.download(settings.whisperModel, to: settings.whisperModelPath)
            } catch {
                errorMessage = error.localizedDescription
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
