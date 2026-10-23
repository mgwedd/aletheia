import SwiftUI

struct FirstRunView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var encryption: EncryptionManager
    @EnvironmentObject private var license: LicenseState

    /// Set once the user ticks the acceptance box. Not persisted until they
    /// press "Finish setup" — that's the moment acceptance is recorded on disk.
    @State private var agreedToLegal = false
    @State private var showEncryptionSetup = false
    @State private var showConsentGuide = false

    //   Set up Aletheia
    //   Recording, transcription and the AI all run on this Mac…
    //   ━━━━━━━━━━━━━━━━━━━━──────────  2 of 6 done
    //   ┌─ checklist card (SetupChecklistView) ────────────┐
    //   └──────────────────────────────────────────────────┘
    //   About · Protect your data · Terms & Privacy       (scrolls)
    //  ─────────────────────────────────────────────────────
    //   disclaimer / hint                      [Finish setup]
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Set up Aletheia")
                            .font(Theme.Typography.display)
                            .foregroundStyle(Theme.text.color)
                            .accessibilityAddTraits(.isHeader)

                        Text("Recording, transcription and the AI all run on this Mac. Client data is never sent to a server. Downloads happen once.")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.muted.color)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 600, alignment: .leading)
                    }

                    licenseSection

                    hairline

                    SetupChecklistView()

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Recordings, transcripts, and summaries are saved as plain files you can open in Finder.", systemImage: "folder")
                        Label("It captures your microphone and the call's audio straight from your Mac — Zoom, a browser (Tebra), FaceTime, any call — no extra audio setup.", systemImage: "waveform")
                        Label("Speech-to-text runs on-device. AI summaries use a model built into Aletheia, also on this Mac.", systemImage: "lock.shield")
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(Theme.accent.color)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Recording a session requires the client's consent and compliance with your licensing board's rules — that's on you to confirm before you hit record.")
                                Button("Read the consent guide before recording anyone…") {
                                    showConsentGuide = true
                                }
                                .buttonStyle(.plain)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.accent.color)
                            }
                        }
                    }
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.text.color)
                    .labelStyle(AccentIconLabelStyle())

                    if appModel.featureRegistry.contains(id: AtRestEncryptionFeatureModule.id) {
                        hairline

                        encryptionSection
                    }

                    hairline

                    legalSection
                }
                .padding(.horizontal, 48)
                .padding(.top, 40)
                .padding(.bottom, 28)
            }

            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Aletheia is a tool, not legal or clinical advice. Get your client's consent before recording, and follow your licensing board's rules.")
                    Text(footerHint)
                }
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.muted.color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460, alignment: .leading)
                Spacer(minLength: 8)
                finishButton
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 20)
            .background(Theme.panel.color)
            .themeDivider(.top)
        }
        .frame(width: 720, height: 720)
        .background(Theme.panel.color)
        .textSelection(.enabled)
        .sheet(isPresented: $showConsentGuide) {
            ConsentGuideView()
        }
        .onAppear {
            if Legal.isAccepted(settings.acceptedLegalVersion) {
                agreedToLegal = true
            }
        }
    }

    /// Primary once the required steps are done; the standard (disabled) style
    /// until then. Recording acceptance happens at the moment it is pressed.
    @ViewBuilder
    private var finishButton: some View {
        if canContinue {
            Button("Finish setup", action: finish)
                .buttonStyle(.themePrimary)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        } else {
            Button("Finish setup", action: finish)
                .buttonStyle(.themed)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(true)
        }
    }

    private func finish() {
        // Record acceptance locally (version + timestamp) at the exact moment
        // the user proceeds, then unlock the app.
        settings.recordLegalAcceptance(license: license.status.token)
        settings.hasCompletedFirstRun = true
    }

    private var hairline: some View {
        Rectangle().fill(Theme.line.color).frame(height: 1)
    }

    /// Recommends turning on at-rest encryption as part of setup — Aletheia's
    /// default posture. Shown as an opt-out step: the therapist can set it up now
    /// or proceed and turn it on later in Settings; it never blocks "Finish setup".
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
                    Text("Or turn it on later in Settings. FileVault needs to be on before you add patients.")
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

    /// Step 1: the license key, checked on this Mac. It comes before the terms, so
    /// the acceptance below is recorded against a named licensee. Once setup has
    /// been completed, re-accepting updated terms never needs a license: a lapsed
    /// one must not stand between a clinician and their records.
    private var licenseSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("License")
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.text.color)
            if license.status.isActive, let token = license.status.token {
                Label("Licensed to \(token.sub), valid until \(token.expiresAt.licenseText).", systemImage: "checkmark.seal.fill")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.accent.color)
            } else {
                Text("Paste the license key from your email. It is checked on this Mac and never sent anywhere.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.muted.color)
                    .fixedSize(horizontal: false, vertical: true)
                LicenseEntryView()
            }
        }
    }

    /// The license step is done: a current license, or setup was completed before
    /// (terms re-acceptance only).
    private var licenseStepDone: Bool {
        license.status.isActive || settings.hasCompletedFirstRun
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
            Toggle(isOn: licenseGatedAgreement) {
                Text("I have read and agree to the Terms of Service and Privacy Policy.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.text.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.checkbox)
            .onChange(of: agreedToLegal) { _, agreed in
                if agreed {
                    settings.recordLegalAcceptance(license: license.status.token)
                }
            }
        }
    }

    /// The acceptance box does nothing until the license step is done.
    private var licenseGatedAgreement: Binding<Bool> {
        Binding(get: { agreedToLegal && licenseStepDone }, set: { if licenseStepDone { agreedToLegal = $0 } })
    }

    private var canContinue: Bool {
        settings.dataRootURL != nil && agreedToLegal && licenseStepDone
    }

    private var footerHint: String {
        if !licenseStepDone {
            return "Paste your license key above to continue."
        }
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
