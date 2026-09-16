import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var appModel: AppModel
    @StateObject private var whisperDownloader = WhisperModelDownloader()
    @State private var ollamaPullProgress: Double = 0
    @State private var ollamaPullStatus: String = ""
    @State private var isPullingOllamaModel = false
    @State private var healthChecks: [ToolHealthCheck] = []
    @State private var isCheckingHealth = false
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

            Section("AI Summaries & Chat (Ollama)") {
                TextField("Model name", text: $settings.ollamaModelName)
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
                Button("Refresh Status") { Task { await runHealthChecks() } }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
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
            let client = OllamaClient(baseURL: settings.ollamaBaseURL)
            try await client.pullModel(settings.ollamaModelName) { progress, status in
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

    private func runHealthChecks() async {
        isCheckingHealth = true
        defer { isCheckingHealth = false }
        healthChecks = await ToolHealth.runAllChecks(settings: settings)
    }
}
