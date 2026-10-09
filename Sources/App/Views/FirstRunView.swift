import SwiftUI

struct FirstRunView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var encryption: EncryptionManager

    /// Set once the user ticks the acceptance box. Not persisted until they
    /// press "Get Started" — that's the moment acceptance is recorded on disk.
    @State private var agreedToLegal = false
    @State private var showEncryptionSetup = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Set up Aletheia")
                        .font(Theme.Typography.display)
                        .foregroundStyle(Theme.text.color)
                        .accessibilityAddTraits(.isHeader)

                    Text("""
                    Everything Aletheia does — recording, transcription, and \
                    AI summaries — happens on this Mac. Nothing is uploaded anywhere.
                    """)
                    .font(Theme.Typography.reading)
                    .foregroundStyle(Theme.muted.color)
                    .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Recordings, transcripts, and summaries are saved as plain files you can open in Finder.", systemImage: "folder")
                        Label("It captures your microphone and the call's audio straight from your Mac — Zoom, a browser (Tebra), FaceTime, any call — no extra audio setup.", systemImage: "waveform")
                        Label("Speech-to-text runs on-device. AI summaries use a local model through Ollama, also on this Mac.", systemImage: "lock.shield")
                        Label("Recording a session requires the client's consent and compliance with your licensing board's rules — that's on you to confirm before you hit record.", systemImage: "exclamationmark.triangle")
                    }
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.text.color)
                    .labelStyle(AccentIconLabelStyle())

                    hairline

                    SetupChecklistView()

                    if appModel.featureRegistry.contains(id: AtRestEncryptionFeatureModule.id) {
                        hairline

                        encryptionSection
                    }

                    hairline

                    legalSection
                }
                .padding(32)
            }

            HStack {
                Text(footerHint)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.muted.color)
                Spacer()
                Button("Get Started") {
                    // Record acceptance locally (version + timestamp) at the
                    // exact moment the user proceeds, then unlock the app.
                    settings.recordLegalAcceptance()
                    settings.hasCompletedFirstRun = true
                }
                .buttonStyle(.themePrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(!canContinue)
            }
            .padding(20)
            .background(Theme.panel.color)
            .themeDivider(.top)
        }
        .frame(width: 600, height: 680)
        .background(Theme.window.color)
    }

    private var hairline: some View {
        Rectangle().fill(Theme.line.color).frame(height: 1)
    }

    /// Recommends turning on at-rest encryption as part of setup — Aletheia's
    /// default posture. Shown as an opt-out step: the therapist can set it up now
    /// or proceed and turn it on later in Settings; it never blocks "Get Started".
    @ViewBuilder
    private var encryptionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Protect your data")
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.text.color)
            if encryption.isEnabled {
                Label("At-rest encryption is on for this folder.", systemImage: "checkmark.seal.fill")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.accent.color)
            } else if EncryptionOnboarding.isRecommended(
                dataFolderChosen: settings.dataRootURL != nil,
                alreadyEnabled: encryption.isEnabled
            ) {
                Text("Recommended: encrypt your notes, transcripts, summaries, chat, and recordings on disk with a recovery passphrase — on top of the app lock. It keeps your data protected even on an external drive, in a backup, or in a synced folder.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.muted.color)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button {
                        showEncryptionSetup = true
                    } label: {
                        Label("Set Up Encryption", systemImage: "lock.shield")
                    }
                    .buttonStyle(.themePrimary)
                    Text("Or turn it on later in Settings. FileVault is recommended either way.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.muted.color)
                }
            } else {
                // No data folder chosen yet — the checklist above prompts for it.
                Text("Choose a data folder above, then you can turn on at-rest encryption here.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.muted.color)
            }
        }
        .sheet(isPresented: $showEncryptionSetup) {
            EncryptionSetupSheet()
                .environmentObject(encryption)
        }
    }

    private var legalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Terms & Privacy")
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.text.color)
            Text("Before using Aletheia, please review and accept the terms. Your acceptance is recorded on this Mac and is never sent anywhere.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.muted.color)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                Link("Terms of Service", destination: Legal.termsURL)
                Link("Privacy Policy", destination: Legal.privacyURL)
            }
            .font(Theme.Typography.body)
            .tint(Theme.accent.color)
            Toggle(isOn: $agreedToLegal) {
                Text("I have read and agree to the Terms of Service and Privacy Policy.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.text.color)
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

/// The intro list: accent icons in a fixed column, text beside them.
private struct AccentIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            configuration.icon
                .foregroundStyle(Theme.accent.color)
                .frame(width: 18)
            configuration.title
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
