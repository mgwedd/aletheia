import SwiftUI

struct FirstRunView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var appModel: AppModel
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Welcome to Session Notes").font(.largeTitle.bold())

            Text("""
            Everything Session Notes does — recording, transcription, and \
            AI summaries — happens on this Mac. Nothing is uploaded anywhere.
            """)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Label("Recordings, transcripts, and summaries are saved as plain files you can open in Finder.", systemImage: "folder")
                Label("Speech-to-text runs on-device. AI summaries use a local model through Ollama, also on this Mac.", systemImage: "lock.shield")
                Label("Recording a session requires the client's consent and compliance with your licensing board's rules — that's on you to confirm before you hit record.", systemImage: "exclamationmark.triangle")
            }
            .font(.callout)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Step 1: Choose where your data lives").font(.headline)
                Text("Pick a folder inside iCloud Drive so it backs up automatically, or any folder you like.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    if let url = settings.dataRootURL {
                        Label(url.path, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Label("No folder chosen yet", systemImage: "circle")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(settings.dataRootURL == nil ? "Choose Folder…" : "Change…", action: chooseFolder)
                }
            }

            Spacer()

            HStack {
                Text("You can fine-tune the AI model and check setup status any time from Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Get Started") {
                    settings.hasCompletedFirstRun = true
                }
                .keyboardShortcut(.defaultAction)
                .disabled(settings.dataRootURL == nil)
            }
        }
        .padding(32)
        .frame(width: 560, height: 480)
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
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
}
