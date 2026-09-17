import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var integrations: Integrations
    @EnvironmentObject private var updateService: UpdateService
    @StateObject private var whisperDownloader = WhisperModelDownloader()
    @StateObject private var llamaDownloader = LlamaModelDownloader()
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
                    // Apple Intelligence is intentionally hidden for now (see
                    // Integrations.appleIntelligenceBlocked) — keep AI fully on
                    // backends we can prove stay on this Mac.
                    ForEach(AssistantBackend.allCases.filter {
                        !($0 == .appleIntelligence && Integrations.appleIntelligenceBlocked)
                    }) { backend in
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

            Section("AI Instructions") {
                Text("The standing instructions sent with every AI request — the assistant's voice and rules. Editing this changes how summaries and chat behave.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $settings.systemPrompt)
                    .font(.callout)
                    .frame(minHeight: 120)
                HStack {
                    Spacer()
                    Button("Reset to Default") { settings.systemPrompt = Prompts.defaultSystemPrompt }
                        .disabled(settings.systemPrompt == Prompts.defaultSystemPrompt)
                }
            }

            if LlamaRuntime.isBuilt {
                Section("Built-in Model (llama.cpp)") {
                    Picker("Model", selection: $settings.llamaModel) {
                        ForEach(LlamaModel.allCases) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                    HStack {
                        if llamaDownloader.isDownloading {
                            ProgressView(value: llamaDownloader.progress)
                            Text("\(Int(llamaDownloader.progress * 100))%")
                        } else if FileManager.default.fileExists(atPath: LlamaRuntime.modelURL(for: settings.llamaModel).path) {
                            Label("Downloaded", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            Spacer()
                            Button("Re-download") { Task { await downloadLlamaModel() } }
                        } else {
                            Text("Not downloaded (~\(settings.llamaModel.approximateSizeMB) MB)").foregroundStyle(.secondary)
                            Spacer()
                            Button("Download") { Task { await downloadLlamaModel() } }
                        }
                    }
                }
            }

            Section("Spotlight Search") {
                Toggle("Find patients in Spotlight", isOn: $settings.spotlightIndexingEnabled)
                    .onChange(of: settings.spotlightIndexingEnabled) { _, _ in appModel.reindexSpotlight() }
                Text("Lets you open a patient or session straight from macOS Spotlight. Only names and dates are indexed — never transcripts or summaries. Anyone using this Mac can see indexed names, so leave this off on a shared computer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Security") {
                Toggle("Require Touch ID or password to open", isOn: $settings.appLockEnabled)
                Text("Locks the app when it opens and whenever it's hidden, so your patients' notes stay behind your Touch ID or Mac password.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Encrypt this Mac's disk with FileVault")
                            .font(.body.weight(.medium))
                        Text("Recommended. FileVault encrypts everything on this Mac at rest so patient data can't be read if the computer is lost or stolen. macOS manages it; it doesn't affect your backups.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open Settings") { SystemSettingsLinks.openFileVaultSettings() }
                }
            }

            Section("Legal") {
                HStack(spacing: 16) {
                    Link("Terms of Service", destination: Legal.termsURL)
                    Link("Privacy Policy", destination: Legal.privacyURL)
                }
                if let accepted = settings.acceptedLegalDate, settings.hasAcceptedCurrentLegal {
                    LabeledContent("Accepted", value: legalAcceptanceStamp(version: settings.acceptedLegalVersion, at: accepted))
                        .font(.caption)
                }
                Text("Your acceptance of the terms is recorded only on this Mac. It is never sent anywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                Text("Aletheia checks for a new version on launch and lets you know when one is ready.")
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

    private func downloadLlamaModel() async {
        do {
            try await llamaDownloader.download(settings.llamaModel, to: LlamaRuntime.modelURL(for: settings.llamaModel))
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

    private func legalAcceptanceStamp(version: String, at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "v\(version) on \(formatter.string(from: date))"
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
