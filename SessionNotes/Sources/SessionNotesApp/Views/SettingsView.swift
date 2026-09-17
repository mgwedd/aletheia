import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var integrations: Integrations
    @EnvironmentObject private var updateService: UpdateService
    @StateObject private var whisperDownloader = WhisperModelDownloader()
    @State private var ollamaPullProgress: Double = 0
    @State private var ollamaPullStatus: String = ""
    @State private var isPullingOllamaModel = false
    @State private var healthChecks: [ToolHealthCheck] = []
    @State private var isCheckingHealth = false
    @State private var showSetup = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Data Folder") {
                HStack {
                    Text(settings.dataRootURL?.path ?? "Not chosen yet")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(settings.dataRootURL == nil ? .secondary : .primary)
                    Spacer()
                    Button("Change…", action: chooseFolder)
                }
            }

            Section("Speech-to-Text Model") {
                Picker("Model", selection: $settings.whisperModel) {
                    ForEach(WhisperModel.allCases) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                Text("Recommended for your Mac (\(settings.hardware.shortDescription)): \(settings.recommendation.whisperModel.shortName).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    if whisperDownloader.isDownloading {
                        ProgressView(value: whisperDownloader.progress)
                        Text("\(Int(whisperDownloader.progress * 100))%")
                    } else if FileManager.default.fileExists(atPath: settings.whisperModelPath.path) {
                        Label("Downloaded", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Spacer()
                        Button("Re-download") { Task { await downloadWhisperModel() } }
                    } else {
                        Text("Not downloaded (~\(settings.whisperModel.approximateSizeMB) MB)").foregroundStyle(.secondary)
                        Spacer()
                        Button("Download") { Task { await downloadWhisperModel() } }
                    }
                }
            }

            Section("AI Summaries & Chat") {
                Picker("Engine", selection: $settings.assistantBackend) {
                    ForEach(AssistantBackend.allCases) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }
                Text(settings.assistantBackend.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("In use now", value: integrations.effectiveAssistantBackend.displayName)
                    .font(.caption)

                if integrations.effectiveAssistantBackend == .ollama {
                    Divider()
                    TextField("Ollama model name", text: $settings.ollamaModelName)
                    Text("Ollama must be installed and running (its icon shows in the menu bar). Get it from ollama.com.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        if isPullingOllamaModel {
                            ProgressView(value: ollamaPullProgress)
                            Text(ollamaPullStatus).font(.caption).foregroundStyle(.secondary)
                        } else {
                            Button("Download \(settings.ollamaModelName)") { Task { await pullOllamaModel() } }
                        }
                    }
                } else if integrations.effectiveAssistantBackend == .appleIntelligence {
                    Label("Runs on your Mac with Apple Intelligence — nothing to install or download.", systemImage: "apple.logo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Software Update") {
                LabeledContent("Current version", value: appVersionString)
                HStack {
                    if updateService.isChecking {
                        ProgressView().controlSize(.small)
                        Text("Checking…").foregroundStyle(.secondary)
                    } else {
                        Button("Check for Updates") {
                            Task { await updateService.checkForUpdates(force: true) }
                        }
                    }
                    Spacer()
                }
                Text("Session Notes checks for a new version on launch and lets you know when one is ready.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Status") {
                if isCheckingHealth {
                    ProgressView("Checking…")
                }
                ForEach(healthChecks) { check in
                    HStack(alignment: .top) {
                        statusIcon(check.status)
                        VStack(alignment: .leading) {
                            Text(check.title).font(.body.weight(.medium))
                            Text(check.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    Button("Refresh Status") { Task { await runHealthChecks() } }
                    Spacer()
                    Button("Setup Assistant…") { showSetup = true }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .sheet(isPresented: $showSetup) {
            VStack(spacing: 0) {
                HStack {
                    Text("Setup Assistant").font(.headline)
                    Spacer()
                    Button("Done") { showSetup = false }
                }
                .padding()
                Divider()
                ScrollView { SetupChecklistView().padding() }
            }
            .frame(width: 560, height: 560)
            .environmentObject(settings)
            .environmentObject(appModel)
            .environmentObject(integrations)
            .onDisappear { Task { await runHealthChecks() } }
        }
        .task { await runHealthChecks() }
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func statusIcon(_ status: ToolHealthCheck.Status) -> some View {
        switch status {
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    private func chooseFolder() {
        guard let url = FolderPicker.choose() else { return }
        do {
            try settings.setDataRoot(url)
            appModel.rebuildStore()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func downloadWhisperModel() async {
        do {
            try await whisperDownloader.download(settings.whisperModel, to: settings.whisperModelPath)
            await runHealthChecks()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func pullOllamaModel() async {
        isPullingOllamaModel = true
        ollamaPullProgress = 0
        defer { isPullingOllamaModel = false }
        do {
            let assistant = integrations.makeAssistant()
            try await assistant.pullModel(settings.ollamaModelName) { progress, status in
                Task { @MainActor in
                    ollamaPullProgress = progress
                    ollamaPullStatus = status
                }
            }
            await runHealthChecks()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var appVersionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private func runHealthChecks() async {
        isCheckingHealth = true
        defer { isCheckingHealth = false }
        healthChecks = await ToolHealth.runAllChecks(settings: settings, backend: integrations.effectiveAssistantBackend, assistant: integrations.makeAssistant())
    }
}
