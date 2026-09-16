import SwiftUI

struct FirstRunView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Welcome to Session Notes").font(.largeTitle.bold())

                    Text("""
                    Everything Session Notes does — recording, transcription, and \
                    AI summaries — happens on this Mac. Nothing is uploaded anywhere.
                    """)
                    .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Recordings, transcripts, and summaries are saved as plain files you can open in Finder.", systemImage: "folder")
                        Label("It captures your microphone and the call's audio straight from your Mac — any browser video call, no extra audio setup.", systemImage: "waveform")
                        Label("Speech-to-text runs on-device. AI summaries use a local model through Ollama, also on this Mac.", systemImage: "lock.shield")
                        Label("Recording a session requires the client's consent and compliance with your licensing board's rules — that's on you to confirm before you hit record.", systemImage: "exclamationmark.triangle")
                    }
                    .font(.callout)

                    Divider()

                    SetupChecklistView()
                }
                .padding(32)
            }

            Divider()
            HStack {
                Text(settings.dataRootURL == nil
                     ? "Choose a data folder above to continue."
                     : "You can finish the rest of the checklist now or any time from Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Get Started") {
                    settings.hasCompletedFirstRun = true
                }
                .keyboardShortcut(.defaultAction)
                .disabled(settings.dataRootURL == nil)
            }
            .padding(20)
        }
        .frame(width: 600, height: 620)
    }
}
