import AppKit
import SwiftUI

/// Settings: a sidebar of panes on the left, the selected pane on the right.
///
///   ┌──────────────┬──────────────────────────────────────┐
///   │ General      │ <pane title>                          │
///   │ AI and models├──────────────────────────────────────┤
///   │ Note format  │ cards and rows, scrolling             │
///   │ Encryption   │                                       │
///   │ Backups      │                                       │
///   │ Security     │                                       │
///   └──────────────┴──────────────────────────────────────┘
///
/// Shown both as the in-window sheet and as the app's Settings scene.
struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var integrations: Integrations
    @EnvironmentObject private var updateService: UpdateService
    @EnvironmentObject private var encryption: EncryptionManager
    @EnvironmentObject private var exports: ExportJobCenter
    @StateObject private var whisperDownloader = WhisperModelDownloader()
    @ObservedObject private var llamaDownloader = LlamaModelDownloader.shared
    @State private var healthChecks: [ToolHealthCheck] = []
    @State private var isCheckingHealth = false
    @State private var showSetup = false
    @ObservedObject private var navigator = AppNavigator.shared
    @ObservedObject private var setAside = SetAsideRecordings.shared
    @State private var newRiskPhrase = ""
    @State private var confirmClearRiskPhrases = false
    @State private var confirmResetRiskPhrases = false
    @State private var errorMessage: String?
    /// How the last audit log export ended, shown until dismissed.
    @State private var exportResult: SaveOutcome?
    @State private var showEncryptionSetup = false
    @State private var showNewRecoveryKeySheet = false
    @State private var showChangePassphraseSheet = false
    @State private var showConsentGuide = false
    @State private var confirmDisableEncryption = false
    @State private var isDisablingEncryption = false
    @State private var rememberOnDevice = false
    /// A folder chosen for Export All Records that needs a warning before writing.
    @State private var riskyExportFolder: RiskyExportFolder?
    /// The pane last shown, so Settings reopens where it was left.
    @AppStorage("settings.selectedPane") private var selectedPaneRaw: String = SettingsPane.default.rawValue
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    private var panes: [SettingsPane] { SettingsPane.available(encryptionOffered: encryptionOffered, hasSetAsideRecordings: !setAside.items.isEmpty) }

    private var pane: SettingsPane { SettingsPane.restored(rawValue: selectedPaneRaw, in: panes) }

    private var paneSelection: Binding<SettingsPane> {
        Binding(get: { pane }, set: { selectedPaneRaw = $0.rawValue })
    }

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: paneSelection, panes: panes)
            SettingsPaneContainer(title: pane.title) {
                paneContent
            }
            .id(pane)
        }
        .frame(
            minWidth: SettingsLayout.minWidth,
            idealWidth: SettingsLayout.idealWidth,
            minHeight: SettingsLayout.minHeight,
            idealHeight: SettingsLayout.idealHeight
        )
        .background(Theme.window.color)
        .tint(Theme.accent.color)
        .textSelection(.enabled)
        .navigationTitle("Settings")
        .onAppear { showRequestedSection() }
        .onChange(of: navigator.pendingSettings) { _, _ in showRequestedSection() }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .sheet(isPresented: $showSetup) {
            VStack(spacing: 0) {
                HStack {
                    Text("Setup Assistant")
                        .font(Theme.Typography.headline)
                        .foregroundStyle(Theme.text.color)
                    Spacer()
                    Button("Done") { showSetup = false }
                        .buttonStyle(.themed)
                }
                .padding()
                Rectangle().fill(Theme.line.color).frame(height: 1)
                ScrollView { SetupChecklistView().padding() }
            }
            .frame(width: 560, height: 560)
            .background(Theme.window.color)
            .environmentObject(settings)
            .environmentObject(appModel)
            .environmentObject(integrations)
            .onDisappear { Task { await runHealthChecks() } }
        }
        .sheet(isPresented: $showEncryptionSetup) {
            EncryptionSetupSheet()
                .environmentObject(encryption)
        }
        .sheet(isPresented: $showChangePassphraseSheet) {
            ChangePassphraseSheet()
                .environmentObject(encryption)
        }
        .sheet(isPresented: $showNewRecoveryKeySheet) {
            NewRecoveryKeySheet()
                .environmentObject(encryption)
        }
        .sheet(isPresented: $showConsentGuide) {
            ConsentGuideView()
        }
        .confirmationDialog(
            "Turn off encryption?",
            isPresented: $confirmDisableEncryption,
            titleVisibility: .visible
        ) {
            Button("Turn Off and Decrypt", role: .destructive) { disableEncryption() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your notes, transcripts, summaries, chat, records and recordings will be decrypted back to plain files on disk. FileVault, if on, still protects them.")
        }
        .liveStatusRefresh { authoritative in await runHealthChecks(authoritative: authoritative) }
        .onAppear {
            rememberOnDevice = encryption.isRememberedOnDevice
        }
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .exportResultAlert($exportResult)
        .confirmationDialog(
            riskyExportFolder?.warnings.first?.title ?? "",
            isPresented: Binding(get: { riskyExportFolder != nil }, set: { if !$0 { riskyExportFolder = nil } }),
            titleVisibility: .visible,
            presenting: riskyExportFolder
        ) { risky in
            Button("Export Anyway") { startExportAll(into: risky.folder) }
            // After the dialog has closed, so a second warning isn't cleared by its dismissal.
            Button("Choose Another Folder…") { DispatchQueue.main.async { chooseExportAllFolder() } }
            Button("Cancel", role: .cancel) {}
        } message: { risky in
            Text(risky.warnings.map(\.message).joined(separator: "\n\n"))
        }
    }

    /// Shows what another part of the app asked for (e.g. the Doctor's "Set
    /// up…"): selects its pane and opens its sheet.
    private func showRequestedSection() {
        guard let request = navigator.takeSettingsRequest() else { return }
        selectedPaneRaw = request.pane.rawValue
        switch request {
        case .setupAssistant: showSetup = true
        case .setAsideRecordings: break
        }
    }

    @ViewBuilder
    private var paneContent: some View {
        switch pane {
        case .general: generalPane
        case .ai: aiPane
        case .format: formatPane
        case .encryption: encryptionPane
        case .backups: backupsPane
        case .security: securityPane
        case .licenses: LicensesPane()
        case .setAsideRecordings:
            SetAsideRecordingsPane(model: setAside) { selectedPaneRaw = SettingsPane.general.rawValue }
        }
    }

    // MARK: - General

    @ViewBuilder
    private var generalPane: some View {
        dataFolderSection
        SettingsHairline()
        if SettingsAvailability.showsKeepAudio(encryptionOffered: encryptionOffered) {
            SettingsSwitchRow(
                title: "Keep raw audio after transcription",
                detail: audioRetentionCaption,
                isOn: $settings.keepAudioRecordings
            )
            .disabled(!encryption.isEnabled)
        }
        SettingsSwitchRow(
            title: "Transcribe automatically when a recording ends",
            tip: HelpTips.autoTranscribe,
            isOn: $settings.autoTranscribeAfterRecording
        )
        SettingsRow(title: "Appearance") {
            ThemeSegmentedControl(
                options: [AppearancePreference.light, .system, .dark].map { ThemeTab(value: $0, title: $0.title) },
                selection: $settings.appearance
            )
            .frame(width: 240)
            .accessibilityLabel("Appearance")
        }
        if appModel.featureRegistry.contains(id: SpotlightFeatureModule.id) {
            SettingsSwitchRow(
                title: "Find patients in Spotlight",
                detail: "Lets you open a patient or session straight from macOS Spotlight. Only names and dates are indexed — never transcripts or summaries. Anyone using this Mac can see indexed names, so leave this off on a shared computer.",
                isOn: $settings.spotlightIndexingEnabled
            )
            .onChange(of: settings.spotlightIndexingEnabled) { _, _ in appModel.reindexSpotlight() }
        }
        softwareUpdateSection
        legalSection
        statusSection
    }

    private var dataFolderSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Data folder").eyebrowStyle()
            HStack(spacing: 8) {
                Text(settings.dataRootURL?.path ?? "Not chosen yet")
                    .font(Theme.Typography.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(settings.dataRootURL == nil ? Theme.muted.color : Theme.text.color)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                    .themeField()
                    .accessibilityLabel("Data folder")
                Button("Choose…", action: chooseFolder)
                    .buttonStyle(.themed)
                Button("Show in Finder") {
                    if let url = settings.dataRootURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                .buttonStyle(.themed)
                .disabled(settings.dataRootURL == nil)
            }
            SettingsCaption("Everything lives here. Changing it moves nothing; point it at an existing Aletheia folder to switch.")
        }
    }

    private var softwareUpdateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Software update").eyebrowStyle()
            SettingsRowsCard {
                SettingsRow(title: "Current version") {
                    Text(appVersionString)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.muted.color)
                }
                .padding(.vertical, 12)
                SettingsHairline()
                SettingsRow(
                    title: "Notarization",
                    detail: "Signed with Developer ID and notarized by Apple so macOS Gatekeeper allows it to run without warnings."
                ) {
                    Text(CodeSigningStatus.current().description)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.muted.color)
                }
                .padding(.vertical, 12)
                SettingsHairline()
                SettingsSwitchRow(
                    title: "Check for updates automatically",
                    detail: "Aletheia checks on launch and when switching back to the app.",
                    isOn: $settings.autoCheckForUpdates
                )
                .padding(.vertical, 12)
                SettingsHairline()
                SettingsRow(
                    title: "Check for updates",
                    detail: "Aletheia can check GitHub for published releases. No patient or client data is ever transmitted."
                ) {
                    HStack(spacing: 8) {
                        if updateService.isChecking {
                            ProgressView().controlSize(.small)
                            Text("Checking…")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.muted.color)
                        } else {
                            if let status = manualCheckStatusText {
                                Text(status)
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(Theme.muted.color)
                            }
                            Button("Check for Updates") {
                                Task { await updateService.checkForUpdates(force: true) }
                            }
                            .buttonStyle(.themed)
                        }
                    }
                }
                .padding(.vertical, 12)
                SettingsHairline()
                HStack {
                    Link("View Releases on GitHub", destination: URL(string: "https://github.com/mgwedd/aletheia/releases")!)
                        .font(Theme.Typography.body)
                    Spacer()
                }
                .padding(.vertical, 12)
            }
        }
    }

    private var legalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Legal").eyebrowStyle()
            SettingsRowsCard {
                HStack(spacing: 16) {
                    Link("Terms of Service", destination: Legal.termsURL)
                    Link("Privacy Policy", destination: Legal.privacyURL)
                    Button("Consent Guide…") { showConsentGuide = true }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent.color)
                    Spacer()
                }
                .font(Theme.Typography.body)
                .padding(.vertical, 12)
                if let accepted = settings.acceptedLegalDate, settings.hasAcceptedCurrentLegal {
                    SettingsHairline()
                    SettingsRow(title: "Accepted") {
                        Text(legalAcceptanceStamp(version: settings.acceptedLegalVersion, at: accepted))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.muted.color)
                    }
                    .padding(.vertical, 12)
                }
            }
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Status").eyebrowStyle()
            SettingsRowsCard {
                // First load only; later refreshes are silent so rows don't shift.
                if isCheckingHealth && healthChecks.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        SettingsCaption("Checking…")
                        Spacer()
                    }
                    .padding(.vertical, 12)
                    SettingsHairline()
                }
                ForEach(healthChecks) { check in
                    SettingsRow(title: check.title, detail: check.detail) {
                        statusChip(check.status)
                    }
                    .padding(.vertical, 12)
                    SettingsHairline()
                }
                HStack(spacing: 8) {
                    Label("Updates automatically", systemImage: "arrow.triangle.2.circlepath")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.muted.color)
                    Spacer()
                    if appModel.featureRegistry.contains(id: DoctorFeatureModule.id) {
                        Button("Aletheia Doctor…") { openWindow(id: DoctorFeatureModule.windowID) }
                            .buttonStyle(.themed)
                    }
                    Button("Setup Assistant…") { showSetup = true }
                        .buttonStyle(.themed)
                }
                .padding(.vertical, 12)
                SettingsHairline()
                SettingsSwitchRow(
                    title: "Show recording diagnostics",
                    detail: "Adds a technical readout about call audio to the recording screen, for troubleshooting. It shows permission and stream state only, never session content.",
                    isOn: $settings.debugDiagnosticsEnabled
                )
            }
        }
    }

    @ViewBuilder
    private func statusChip(_ status: ToolHealthCheck.Status) -> some View {
        switch status {
        case .ok: Chip("OK", tone: .ok)
        case .warning: Chip("Warning", tone: .warn)
        case .failed: Chip("Problem", tone: .recording)
        }
    }

    /// Explains the audio-retention toggle, and why it's unavailable until
    /// at-rest encryption is on — kept audio must be ciphertext, never plaintext.
    private var audioRetentionCaption: String {
        if encryption.isEnabled {
            return "By default, recordings are deleted the moment a session is transcribed — the transcript is kept as the document of record. (If no speech is detected, the recording is kept so nothing is lost.) Turn this on to keep the original audio too; it stays encrypted at rest with your other data."
        } else {
            return "By default, recordings are deleted the moment a session is transcribed — only the transcript is kept. (If no speech is detected, the recording is kept so nothing is lost, and it isn't encrypted while Extra Encryption is off.) Keeping the original audio requires turning on encryption (Encryption pane), so any retained recording stays encrypted at rest rather than sitting on disk in the clear."
        }
    }

    // MARK: - AI and models

    @ViewBuilder
    private var aiPane: some View {
        speechCard
        languageCard
        if Integrations.appleIntelligenceBlocked {
            HStack(alignment: .top, spacing: 10) {
                Chip("Off")
                SettingsCaption("Apple Intelligence is turned off on purpose.")
            }
        }
        // The "Built-in Model" (embedded llama.cpp) management UI — offered
        // when the module ships AND the runtime is linked.
        if LlamaRuntime.isBuilt && appModel.featureRegistry.contains(id: EmbeddedLlamaFeatureModule.id) {
            builtInModelCard
        }
        instructionsCard
        riskPhrasesCard
    }

    private var whisperInstalled: Bool {
        FileManager.default.fileExists(atPath: settings.whisperModelPath.path)
    }

    private var speechCard: some View {
        SettingsCard {
            SettingsCardHeader(title: "Speech recognition") {
                if whisperDownloader.isDownloading {
                    Chip("Downloading", tone: .info)
                } else if whisperInstalled {
                    Chip("Installed", tone: .ok)
                } else {
                    Chip("Not downloaded", tone: .warn)
                }
            }
            SettingsRow(
                title: "Whisper \(settings.whisperModel.rawValue)",
                detail: "Recommended for your Mac (\(settings.hardware.shortDescription)): \(settings.recommendation.whisperModel.shortName)."
            ) {
                Picker("Speech model", selection: $settings.whisperModel) {
                    ForEach(WhisperModel.allCases) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 280)
            }
            ModelLicenseLink(settings.whisperModel)
            if whisperDownloader.isDownloading {
                downloadProgress(whisperDownloader.progress)
            } else if whisperInstalled {
                HStack {
                    DownloadedMark()
                    Spacer()
                    Button("Re-download") { Task { await downloadWhisperModel() } }
                        .buttonStyle(.themed)
                }
            } else {
                HStack {
                    SettingsCaption("Not downloaded (~\(settings.whisperModel.approximateSizeMB) MB)")
                    Spacer()
                    Button("Download") { Task { await downloadWhisperModel() } }
                        .buttonStyle(.themePrimary)
                }
            }
        }
    }

    private func downloadProgress(_ value: Double) -> some View {
        HStack(spacing: 12) {
            ThemeProgressBar(value: value)
            Text("\(Int(value * 100))%")
                .font(Theme.Typography.caption)
                .monospacedDigit()
                .foregroundStyle(Theme.muted.color)
        }
    }

    private var languageCard: some View {
        SettingsCard {
            SettingsCardHeader(title: "Language model") { EmptyView() }
            SettingsRow(title: "Engine", detail: settings.assistantBackend.summary) {
                Picker("Engine", selection: $settings.assistantBackend) {
                    // Apple Intelligence is intentionally hidden for now (see
                    // Integrations.appleIntelligenceBlocked) — keep AI fully on
                    // backends we can prove stay on this Mac. "Built-in model"
                    // shows when EmbeddedLlamaFeatureModule is registered (every
                    // tier); AssistantBackend.selectableOptions does the gating
                    // so it's unit-tested.
                    ForEach(AssistantBackend.selectableOptions(
                        embeddedLlamaAvailable: appModel.featureRegistry.contains(id: EmbeddedLlamaFeatureModule.id),
                        appleIntelligenceBlocked: Integrations.appleIntelligenceBlocked
                    )) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 220)
            }
            HStack(spacing: 6) {
                Text("In use now")
                    .foregroundStyle(Theme.muted.color)
                Text(integrations.effectiveAssistantBackend.displayName)
                    .foregroundStyle(Theme.text.color)
                Spacer()
            }
            .font(Theme.Typography.caption)
            .accessibilityElement(children: .combine)

            if integrations.effectiveAssistantBackend == .appleIntelligence {
                Label("Runs on your Mac with Apple Intelligence — nothing to install or download.", systemImage: "apple.logo")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.muted.color)
            }
        }
    }

    private var builtInModelCard: some View {
        let installed = FileManager.default.fileExists(atPath: LlamaRuntime.modelURL(for: settings.llamaModel).path)
        return SettingsCard {
            SettingsCardHeader(title: "Built-in model (llama.cpp)") {
                if llamaDownloader.isDownloading {
                    Chip("Downloading", tone: .info)
                } else if installed {
                    Chip("Installed", tone: .ok)
                } else {
                    Chip("Not downloaded", tone: .warn)
                }
            }
            SettingsRow(title: "Model") {
                Picker("Model", selection: $settings.llamaModel) {
                    ForEach(LlamaModel.allCases) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 280)
            }
            ModelLicenseLink(settings.llamaModel)
            if llamaDownloader.isDownloading {
                downloadProgress(llamaDownloader.progress)
                if !llamaDownloader.statusText.isEmpty {
                    SettingsCaption(llamaDownloader.statusText)
                }
            } else if installed {
                HStack {
                    DownloadedMark()
                    Spacer()
                    Button("Re-download") { Task { await downloadLlamaModel() } }
                        .buttonStyle(.themed)
                }
            } else {
                HStack {
                    SettingsCaption("Not downloaded (~\(settings.llamaModel.approximateSizeMB) MB)")
                    Spacer()
                    Button("Download") { Task { await downloadLlamaModel() } }
                        .buttonStyle(.themePrimary)
                }
            }
            if !llamaDownloader.isDownloading {
                ForEach(LlamaRuntime.unusedDownloadedModels(besides: settings.llamaModel)) { unused in
                    SettingsHairline()
                    HStack {
                        SettingsCaption("\(unused.shortName) is also on disk (~\(unused.approximateSizeMB) MB).")
                        Spacer()
                        Button("Remove \(unused.shortName)") {
                            do {
                                try LlamaRuntime.removeModel(unused)
                                Task { await runHealthChecks() }
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                        .buttonStyle(.themed)
                    }
                }
            }
        }
    }

    private var instructionsCard: some View {
        SettingsCard {
            SettingsCardHeader(title: "AI instructions") { EmptyView() }
            EditorField(text: $settings.systemPrompt, minHeight: 140)
            HStack {
                Spacer()
                Button("Reset to Default") { settings.systemPrompt = Prompts.defaultSystemPrompt }
                    .buttonStyle(.themed)
                    .disabled(settings.systemPrompt == Prompts.defaultSystemPrompt)
            }
        }
        // On the section, opening above its header: on the editor the
        // popover sat over the instructions being read.
        .hoverTip(HelpTips.aiInstructions, arrowEdge: .top)
    }

    private var riskPhrasesCard: some View {
        SettingsCard {
            SettingsCardHeader(title: "Risk phrases") { EmptyView() }
            SettingsCaption("For a session too long to send whole, lines with these phrases are always put into the note first, and the note says so if any don't fit. Matching ignores case and whole words only. The list stays on this Mac.")
            if settings.riskPhrases.isEmpty {
                Text("No phrases. No lines will be prioritised for risk in long sessions.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.text.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .themeBanner(.warn)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(settings.riskPhrases.enumerated()), id: \.offset) { index, phrase in
                            HStack(spacing: 8) {
                                Text(phrase)
                                    .font(Theme.Typography.body)
                                    .foregroundStyle(Theme.text.color)
                                Spacer(minLength: 8)
                                Button {
                                    settings.riskPhrases.remove(at: index)
                                } label: {
                                    Label("Remove \(phrase)", systemImage: "minus.circle")
                                        .labelStyle(.iconOnly)
                                }
                                .buttonStyle(.themeIcon)
                                .controlSize(.small)
                                .help("Remove this phrase")
                            }
                            .padding(.vertical, 4)
                            if index < settings.riskPhrases.count - 1 { SettingsHairline() }
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .frame(maxHeight: 220)
                .themeField()
            }
            HStack(spacing: 8) {
                TextField("Add a phrase", text: $newRiskPhrase)
                    .textFieldStyle(.plain)
                    .font(Theme.Typography.body)
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .themeField()
                    .onSubmit(addRiskPhrase)
                Button("Add", action: addRiskPhrase)
                    .buttonStyle(.themePrimary)
                    .disabled(newRiskPhrase.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack {
                Button("Clear All") { confirmClearRiskPhrases = true }
                    .buttonStyle(.themed)
                    .disabled(settings.riskPhrases.isEmpty)
                Spacer()
                Button("Reset to Defaults") { confirmResetRiskPhrases = true }
                    .buttonStyle(.themed)
                    .disabled(settings.riskPhrases == LongSessionNote.defaultRiskPhrases)
            }
        }
        .confirmationDialog("Clear all risk phrases?", isPresented: $confirmClearRiskPhrases, titleVisibility: .visible) {
            Button("Clear All", role: .destructive) { settings.riskPhrases = [] }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("No lines will be prioritised for risk in long sessions until you add your own.")
        }
        .confirmationDialog("Reset risk phrases?", isPresented: $confirmResetRiskPhrases, titleVisibility: .visible) {
            Button("Reset to Defaults", role: .destructive) { settings.resetRiskPhrases() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your list is replaced by the built-in one.")
        }
    }

    private func addRiskPhrase() {
        settings.addRiskPhrase(newRiskPhrase)
        newRiskPhrase = ""
    }

    // MARK: - Note format

    @ViewBuilder
    private var formatPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Default progress note format").eyebrowStyle()
            ThemeSegmentedControl(
                options: ProgressNoteFormat.allCases.map { ThemeTab(value: $0, title: $0.shortName) },
                selection: $settings.progressNoteFormat
            )
            .accessibilityLabel("Default progress note format")
            .hoverTip(HelpTips.defaultNoteFormat)
        }
        SettingsHairline()
        VStack(alignment: .leading, spacing: 6) {
            Text("Summary length").eyebrowStyle()
            ThemeSegmentedControl(
                options: SummaryVerbosity.allCases.map { ThemeTab(value: $0, title: $0.displayName) },
                selection: $settings.summaryVerbosity
            )
            .accessibilityLabel("Summary length")
            SettingsCaption(settings.summaryVerbosity.blurb)
        }
        SettingsHairline()
        SettingsSwitchRow(
            title: "Include comments in drafts",
            tip: HelpTips.includeComments,
            isOn: $settings.includeCommentsInDrafts
        )
        SettingsSwitchRow(
            title: "Include patient background",
            detail: "The patient's clinical history, profile notes, and current medications are provided to the assistant.",
            isOn: $settings.includePatientBackground
        )
        SettingsSwitchRow(
            title: "Prepare summaries on battery",
            tip: HelpTips.summariesOnBattery,
            isOn: $settings.prepareSummariesOnBattery
        )
    }

    // MARK: - Encryption

    /// Hidden controls only when there's nothing to manage: encryption is off and
    /// this build doesn't offer turning it on. Once a folder is encrypted — by
    /// this build or an earlier one — the unlock/manage affordances stay
    /// unconditional regardless of build tier.
    private var encryptionOffered: Bool {
        SettingsAvailability.encryptionOffered(
            isEnabled: encryption.isEnabled,
            moduleInBuild: appModel.featureRegistry.contains(id: AtRestEncryptionFeatureModule.id)
        )
    }

    @ViewBuilder
    private var encryptionPane: some View {
        switch encryption.state {
        case .disabled:
            HStack(alignment: .center, spacing: 14) {
                Chip("Off", tone: .warn)
                Text("Encryption is not on. Notes, transcripts and audio are stored unencrypted in your data folder.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.text.color)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .themeBanner(.warn)
        case .unlocked:
            HStack(alignment: .center, spacing: 14) {
                Chip("On", tone: .ok)
                Text("Unlocked for this session. Your data folder is encrypted at rest with your recovery passphrase.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.text.color)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .themeBanner(.info)
        case .keystoreMissing:
            HStack(alignment: .center, spacing: 14) {
                Chip("Keystore missing", tone: .recording)
                Text(EncryptionManager.ManagerError.keystoreMissing.localizedDescription)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.text.color)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .themeBanner(.warn)
        case .lockedNeedsPassphrase:
            HStack(alignment: .center, spacing: 14) {
                Chip("On — locked")
                Text("Unlock from the main window to manage encryption.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.text.color)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .themeBanner(.info)
        }
        SettingsCard(spacing: 10) {
            Text("AES-256-GCM, passphrase-protected")
                .font(Theme.Typography.body.weight(.semibold))
                .foregroundStyle(Theme.text.color)
            Text(encryptionSchemeDescription)
                .font(Theme.Typography.control.weight(.regular))
                .foregroundStyle(Theme.muted.color)
                .fixedSize(horizontal: false, vertical: true)
            if encryption.state == .disabled {
                SettingsCaption("Encrypt your notes, transcripts, summaries, chat, patient records and recordings on disk with a passphrase — protecting them even on an external drive, a backup, or a synced folder. FileVault is still recommended as the baseline.")
            }
            encryptionActions
        }
        if encryption.state == .unlocked {
            SettingsRowsCard {
                SettingsRow(
                    title: "Unlock automatically on this Mac",
                    detail: "Stores the key in this Mac's login keychain so you don't retype your passphrase each launch. Turn off for maximum security — Aletheia will always ask."
                ) {
                    Toggle("Unlock automatically on this Mac", isOn: $rememberOnDevice)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(Theme.accent.color)
                        .onChange(of: rememberOnDevice) { _, on in
                            do {
                                if on { try encryption.rememberOnDevice() } else { encryption.forgetOnDevice() }
                            } catch {
                                errorMessage = error.localizedDescription
                                rememberOnDevice = false
                            }
                        }
                }
                .padding(.vertical, 12)
                SettingsHairline()
                SettingsRow(
                    title: "Passphrase",
                    detail: "Change the passphrase that unlocks your data folder. Your files aren't re-encrypted, and your recovery key keeps working."
                ) {
                    Button("Change Passphrase…") {
                        showChangePassphraseSheet = true
                    }
                    .buttonStyle(.themed)
                }
                .padding(.vertical, 12)
                SettingsHairline()
                SettingsRow(
                    title: "Emergency recovery key",
                    detail: "A 24-word key allows unlocking your data folder if you forget your passphrase. If you misplace your printed key, create a new one to invalidate the old one."
                ) {
                    Button("Create New Recovery Key…") {
                        showNewRecoveryKeySheet = true
                    }
                    .buttonStyle(.themed)
                }
                .padding(.vertical, 12)
            }
            if let failure = encryption.rememberError {
                SettingsCaption("This Mac's keychain couldn't keep the key: \(failure)")
            }
        }
    }

    /// Only states what the crypto code does: see `DataCipher`, `ChunkedCipher`,
    /// `Keystore` and `PassphraseKDF`.
    private var encryptionSchemeDescription: String {
        let chunkMiB = ChunkedCipher.defaultChunkSize / (1 << 20)
        let iterations = PassphraseKDF.defaultIterations.formatted()
        return "A random data key seals each file with AES-256-GCM; long recordings are sealed in \(chunkMiB) MiB chunks. Your passphrase wraps that key (PBKDF2-HMAC-SHA256, \(iterations) iterations). A 24-word emergency recovery key provides a fallback if you lose your passphrase."
    }

    @ViewBuilder
    private var encryptionActions: some View {
        switch encryption.state {
        case .disabled:
            if appModel.featureRegistry.contains(id: AtRestEncryptionFeatureModule.id) {
                HStack(spacing: 8) {
                    Button("Turn On…") { showEncryptionSetup = true }
                        .buttonStyle(.themePrimary)
                        .disabled(settings.dataRootURL == nil)
                    if settings.dataRootURL == nil {
                        SettingsCaption("Choose a data folder in General first.")
                    }
                }
                .padding(.top, 4)
            }
        case .unlocked:
            HStack(spacing: 8) {
                if isDisablingEncryption {
                    ProgressView().controlSize(.small)
                    SettingsCaption("Decrypting…")
                } else {
                    Button("Turn Off Encryption…", role: .destructive) { confirmDisableEncryption = true }
                        .buttonStyle(.themed)
                }
            }
            .padding(.top, 4)
        case .lockedNeedsPassphrase, .keystoreMissing:
            EmptyView()
        }
    }

    // MARK: - Backups

    @ViewBuilder
    private var backupsPane: some View {
        HStack(alignment: .center, spacing: 14) {
            Chip("Time Machine", tone: .info)
            Text(settings.keepDataOutOfSystemBackups
                 ? "Your data folder is kept out of Time Machine and iCloud backups. Aletheia does not make its own backup copies yet, so keep a copy of your own."
                 : "Aletheia does not make its own backup copies yet. Time Machine includes the data folder by default.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.text.color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .themeBanner(.info)
        SettingsRowsCard {
            SettingsSwitchRow(
                title: "Keep my data out of Time Machine & iCloud backups",
                detail: "Off by default, so Time Machine includes your data folder — without it you'd have only one copy. Your data folder can hold unencrypted patient data (and audio/transcript files), so keep your Time Machine backups on an encrypted disk. Turn this on only if you'd rather keep the folder out of macOS system backups and rely on your own copy instead.",
                isOn: $settings.keepDataOutOfSystemBackups
            )
            .padding(.vertical, 12)
        }
        SettingsCaption("Before a database schema change or an encryption change, Aletheia saves a safety copy of the database in a hidden .backups folder inside your data folder.")
        Button("Show backups folder in Finder", action: showBackupsFolder)
            .buttonStyle(.themed)
            .disabled(settings.dataRootURL == nil)
        SettingsHairline()
        exportAllSection
    }

    private var exportAllSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Export all records").eyebrowStyle()
            SettingsCaption("Copies every patient's notes, transcripts, comments and kept recordings into a folder of ordinary files that open without Aletheia. This never needs a license key. The copy isn't encrypted by Aletheia, so save it to this Mac with FileVault on or to an encrypted external drive.")
            HStack(spacing: 8) {
                Button("Export All Records…", action: chooseExportAllFolder)
                    .buttonStyle(.themed)
                    .disabled(appModel.store == nil || exports.isRunning)
                if case let .running(_, label) = exports.state {
                    SettingsCaption(label)
                }
                Spacer()
            }
        }
    }

    /// Asks for a folder, then checks it before writing anything.
    private func chooseExportAllFolder() {
        guard appModel.store != nil, !exports.isRunning else { return }
        guard let folder = FileSaver.chooseFolder(
            prompt: "Export Here",
            message: "Choose where to put a folder with all your records. Pick an encrypted disk that doesn't sync to the cloud."
        ) else { return }
        let warnings = ExportDestinationInspector().warnings(for: folder)
        if warnings.isEmpty {
            startExportAll(into: folder)
        } else {
            riskyExportFolder = RiskyExportFolder(folder: folder, warnings: warnings)
        }
    }

    private func startExportAll(into folder: URL) {
        guard let store = appModel.store, !exports.isRunning else { return }
        let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        let destination = folder.appendingPathComponent(
            AllRecordsExport.folderName(exportedOn: Date(), existing: existing), isDirectory: true)
        let model = appModel
        exports.start(destination: destination, onFinished: { outcome in
            model.recordAudit(
                .recordExported,
                detail: "All records, folder of \(outcome.patientCount ?? 0) patients, \(outcome.sessionCount) sessions"
            )
        }) { progress, isCancelled in
            progress(0, "Listing patients")
            let source = try StoreAllRecordsSource(store: store)
            return try AllRecordsExport.write(from: source, to: destination, progress: progress, isCancelled: isCancelled)
        }
    }

    /// Reveals `.backups` in Finder, or the data folder itself when no backup
    /// has been written yet.
    private func showBackupsFolder() {
        guard let root = settings.dataRootURL else { return }
        let backups = BackupLayout.root(dataRoot: root)
        let target = FileManager.default.fileExists(atPath: backups.path) ? backups : root
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    // MARK: - Security

    @ViewBuilder
    private var securityPane: some View {
        SettingsSwitchRow(
            title: "App lock",
            detail: "Require Touch ID or your Mac password to open. Aletheia locks after 15 minutes of inactivity by default, when the display sleeps, or when your Mac locks or switches user.",
            isOn: $settings.appLockEnabled
        )
        SettingsSwitchRow(
            title: "Lock when Aletheia is hidden",
            detail: "Require another unlock after hiding the app with ⌘H.",
            isOn: $settings.lockWhenHidden
        )
        SettingsRow(
            title: "Lock after inactivity",
            detail: "Choose how long Aletheia can sit unused before it locks. Needs App lock turned on."
        ) {
            Picker("Auto-lock after", selection: idleAutoLockSelection) {
                ForEach(IdleAutoLockTimeout.allCases) { timeout in
                    Text(timeout.displayName).tag(timeout)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 180)
            .disabled(!settings.appLockEnabled)
        }
        SettingsSwitchRow(
            title: "Hide Aletheia from screen sharing",
            detail: "Protect patient windows from capture. A locked window is always hidden from capture.",
            isOn: $settings.hideFromScreenSharing
        )
        SettingsSwitchRow(
            title: "Allow screen sharing this session",
            detail: "Temporary exception for a clinical screen share. Resets when Aletheia quits.",
            isOn: $settings.allowScreenSharingThisSession
        )
        SettingsSwitchRow(
            title: "Show patient names in notifications",
            detail: "Off by default. Notifications appear on the lock screen and stay in Notification Center, so they just say that a session is ready. Turn this on to include the patient's name and the session date.",
            isOn: $settings.notificationsShowPatientNames
        )
        SettingsRow(
            title: "Encrypt this Mac's disk with FileVault",
            detail: "Required before adding new patients, sessions or recordings. FileVault encrypts everything on this Mac at rest so patient data can't be read if the computer is lost or stolen. macOS manages it; it doesn't affect your backups. Existing records stay readable either way."
        ) {
            Button("Open Settings") { SystemSettingsLinks.openFileVaultSettings() }
                .buttonStyle(.themed)
        }
        SettingsHairline()
        VStack(alignment: .leading, spacing: 8) {
            Text("Security posture").eyebrowStyle()
            SecurityPostureView()
        }
        NetworkAccessView()
        AuditLogSection(exportResult: $exportResult)
    }

    private func disableEncryption() {
        isDisablingEncryption = true
        Task { @MainActor in
            do {
                try encryption.disable()
            } catch {
                errorMessage = error.localizedDescription
            }
            isDisablingEncryption = false
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

    /// Bridges the `Int`-backed `idleAutoLockMinutes` setting to the
    /// `IdleAutoLockTimeout` picker. Falls back to the default timeout if the
    /// stored value ever doesn't match one of the offered choices.
    private var idleAutoLockSelection: Binding<IdleAutoLockTimeout> {
        Binding(
            get: { IdleAutoLockTimeout(rawValue: settings.idleAutoLockMinutes) ?? .defaultTimeout },
            set: { settings.idleAutoLockMinutes = $0.rawValue }
        )
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

    private var manualCheckStatusText: String? {
        guard let result = updateService.manualCheckResult else { return nil }
        switch result {
        case .upToDate(let checkedAt):
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return "You're up to date (checked at \(formatter.string(from: checkedAt)))"
        case .couldNotCheck:
            return "Couldn't check for updates"
        case .updateAvailable(let version):
            return "v\(version) available"
        }
    }

    private func runHealthChecks(authoritative: Bool = true) async {
        guard !isCheckingHealth else { return }
        isCheckingHealth = true
        defer { isCheckingHealth = false }
        let latest = await ToolHealth.runAllChecks(
            settings: settings,
            backend: integrations.effectiveAssistantBackend,
            assistant: integrations.makeAssistant(),
            authoritative: authoritative,
            includeScheduling: appModel.featureRegistry.contains(id: EventKitSchedulingFeatureModule.id)
        )
        // Only touch the view when something changed.
        if latest != healthChecks { healthChecks = latest }
    }
}

/// A downloaded model: a checkmark is enough (everything is on this Mac).
private struct DownloadedMark: View {
    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 14))
            .foregroundStyle(Theme.accent.color)
            .help("Downloaded")
            .accessibilityLabel("Downloaded")
    }
}

/// A folder chosen for Export All Records and why it needs a second look.
private struct RiskyExportFolder {
    let folder: URL
    let warnings: [ExportDestinationCheck.Warning]
}
