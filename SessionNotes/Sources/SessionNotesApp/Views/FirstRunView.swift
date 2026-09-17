import SwiftUI

struct FirstRunView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var appModel: AppModel

    /// Set once the user ticks the acceptance box. Not persisted until they
    /// press "Get Started" — that's the moment acceptance is recorded on disk.
    @State private var agreedToLegal = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Welcome to Aletheia").font(.largeTitle.bold())

                    Text("""
                    Everything Aletheia does — recording, transcription, and \
                    AI summaries — happens on this Mac. Nothing is uploaded anywhere.
                    """)
                    .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Recordings, transcripts, and summaries are saved as plain files you can open in Finder.", systemImage: "folder")
                        Label("It captures your microphone and the call's audio straight from your Mac — Zoom, a browser (Tebra), FaceTime, any call — no extra audio setup.", systemImage: "waveform")
                        Label("Speech-to-text runs on-device. AI summaries use a local model through Ollama, also on this Mac.", systemImage: "lock.shield")
                        Label("Recording a session requires the client's consent and compliance with your licensing board's rules — that's on you to confirm before you hit record.", systemImage: "exclamationmark.triangle")
                    }
                    .font(.callout)

                    Divider()

                    SetupChecklistView()

                    Divider()

                    legalSection
                }
                .padding(32)
            }

            Divider()
            HStack {
                Text(footerHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Get Started") {
                    // Record acceptance locally (version + timestamp) at the
                    // exact moment the user proceeds, then unlock the app.
                    settings.recordLegalAcceptance()
                    settings.hasCompletedFirstRun = true
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canContinue)
            }
            .padding(20)
        }
        .frame(width: 600, height: 680)
    }

    private var legalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Terms & Privacy").font(.headline)
            Text("Before using Aletheia, please review and accept the terms. Your acceptance is recorded on this Mac and is never sent anywhere.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                Link("Terms of Service", destination: Legal.termsURL)
                Link("Privacy Policy", destination: Legal.privacyURL)
            }
            .font(.callout)
            Toggle(isOn: $agreedToLegal) {
                Text("I have read and agree to the Terms of Service and Privacy Policy.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.checkbox)
        }
    }

    private var canContinue: Bool {
        settings.dataRootURL != nil && agreedToLegal
    }

    private var footerHint: String {
        if settings.dataRootURL == nil {
            return "Choose a data folder above to continue."
        }
        if !agreedToLegal {
            return "Accept the Terms of Service and Privacy Policy to continue."
        }
        return "You can finish the rest of the checklist now or any time from Settings."
    }
}
