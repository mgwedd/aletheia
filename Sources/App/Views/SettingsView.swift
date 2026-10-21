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
    @StateObject private var whisperDownloader = WhisperModelDownloader()
    @ObservedObject private var llamaDownloader = LlamaModelDownloader.shared
    @State private var ollamaPullProgress: Double = 0
    @State private var ollamaPullStatus: String = ""
    @State private var isPullingOllamaModel = false
    @State private var isStartingOllama = false
    @State private var healthChecks: [ToolHealthCheck] = []
    @State private var isCheckingHealth = false
    @State private var showSetup = false
    @ObservedObject private var navigator = AppNavigator.shared
    @State private var newRiskPhrase = ""
    @State private var confirmClearRiskPhrases = false
    @State private var confirmResetRiskPhrases = false
    @State private var errorMessage: String?
    @State private var showEncryptionSetup = false
    @State private var showConsentGuide = false
    @State private var confirmDisableEncryption = false
    @State private var isDisablingEncryption = false
    @State private var rememberOnDevice = false
    /// Audit-log entries for the viewer, newest first. Loaded on appear and after
    /// an export; a snapshot, not a live binding (the log is append-only on disk).
    @State private var auditEntries: [AuditEvent] = []
    /// The pane last shown, so Settings reopens where it was left.
    @AppStorage("settings.selectedPane") private var selectedPaneRaw: String = SettingsPane.default.rawValue
    private let auditPreviewLimit = 15
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    private var panes: [SettingsPane] { SettingsPane.available(encryptionOffered: encryptionOffered) }

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
            loadAuditEntries()
        }
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    /// Shows what another part of the app asked for (e.g. the Doctor's "Set
    /// up…"): selects its pane and opens its sheet.
    private func showRequestedSection() {
        guard let request = navigator.takeSettingsRequest() else { return }
        selectedPaneRaw = request.pane.rawValue
        switch request {
        case .setupAssistant: showSetup = true
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

    /// The Ollama engine's state as the last health check saw it, if known.
    private var ollamaEngineState: OllamaEngineState? {
        healthChecks.first { $0.kind == .ollama }?.ollamaState
    }

    @ViewBuilder
    private var ollamaChip: some View {
        if integrations.effectiveAssistantBackend == .ollama, let state = ollamaEngineState {
            switch state {
            case .notInstalled: Chip("Ollama not installed", tone: .warn)
            case .installedNotRunning: Chip("Ollama not running", tone: .warn)
            case .starting: Chip("Ollama starting", tone: .info)
            case .running, .modelMissing, .ready: Chip("Ollama running", tone: .ok)
            }
        }
    }

    private var languageCard: some View {
        SettingsCard {
            SettingsCardHeader(title: "Language model") { ollamaChip }
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

            if integrations.effectiveAssistantBackend == .ollama {
                SettingsHairline()
                ollamaControls
            } else if integrations.effectiveAssistantBackend == .appleIntelligence {
                Label("Runs on your Mac with Apple Intelligence — nothing to install or download.", systemImage: "apple.logo")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.muted.color)
            }
        }
    }

    @ViewBuilder
    private var ollamaControls: some View {
        SettingsRow(
            title: "Model",
            detail: OllamaCatalog.option(for: settings.ollamaModelName)?.blurb
        ) {
            Picker("Model", selection: ollamaModelSelection) {
                ForEach(OllamaCatalog.options) { option in
                    Text("\(option.label) (~\(String(format: "%.1f", option.approxSizeGB)) GB)")
                        .tag(option.tag)
                }
                Text("Custom…").tag(OllamaCatalog.customTag)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 280)
        }
        SettingsCaption("Recommended for your Mac (\(settings.hardware.shortDescription)): \(settings.recommendation.ollamaModel).")
        if !OllamaCatalog.contains(settings.ollamaModelName) {
            TextField("Ollama model tag (e.g. qwen2.5:7b)", text: $settings.ollamaModelName)
                .textFieldStyle(.plain)
                .font(Theme.Typography.body)
                .padding(.horizontal, 12)
                .frame(height: 38)
                .themeField()
        }
        SettingsCaption("Ollama must be installed and running (its icon shows in the menu bar). Get it from ollama.com.")
        HStack(spacing: 8) {
            if isPullingOllamaModel {
                ThemeProgressBar(value: ollamaPullProgress)
                Text(ollamaPullStatus)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.muted.color)
                    .lineLimit(1)
            } else {
                Button("Download \(settings.ollamaModelName)") { Task { await pullOllamaModel() } }
                    .buttonStyle(.themed)
                    .disabled(settings.ollamaModelName.trimmingCharacters(in: .whitespaces).isEmpty)
                if ollamaEngineState == .notInstalled {
                    Button("Get Ollama") { SystemSettingsLinks.openOllamaDownload() }
                        .buttonStyle(.themed)
                }
                if ollamaEngineState == .installedNotRunning {
                    Button(isStartingOllama ? "Starting…" : "Start Ollama") { Task { await startOllama() } }
                        .buttonStyle(.themePrimary)
                        .disabled(isStartingOllama)
                }
                if ollamaEngineState == .running || ollamaEngineState == .ready || ollamaEngineState == .modelMissing {
                    Button("Open Ollama") {
                        OllamaLauncher.openOllamaApp()
                    }
                    .buttonStyle(.themed)
                }
                Spacer()
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
            }
        }
    }

    /// Only states what the crypto code does: see `DataCipher`, `ChunkedCipher`,
    /// `Keystore` and `PassphraseKDF`.
    private var encryptionSchemeDescription: String {
        let chunkMiB = ChunkedCipher.defaultChunkSize / (1 << 20)
        let iterations = PassphraseKDF.defaultIterations.formatted()
        return "A random data key seals each file with AES-256-GCM; long recordings are sealed in \(chunkMiB) MiB chunks. Your passphrase wraps that key (PBKDF2-HMAC-SHA256, \(iterations) iterations). If you forget the passphrase, your data cannot be recovered."
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
        case .lockedNeedsPassphrase:
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
            detail: "Require Touch ID or your Mac password to open. You unlock once when it opens. It locks again when your Mac sleeps, its screen locks or you switch user, so your patients' notes stay behind it.",
            isOn: $settings.appLockEnabled
        )
        SettingsRow(
            title: "Lock after inactivity",
            detail: "Optional. Aletheia already locks when your Mac locks or sleeps (set that in System Settings > Lock Screen). Choose a time to also lock after this long with no activity in Aletheia. Needs App lock turned on."
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
            title: "Show patient names in notifications",
            detail: "Off by default. Notifications appear on the lock screen and stay in Notification Center, so they just say that a session is ready. Turn this on to include the patient's name and the session date.",
            isOn: $settings.notificationsShowPatientNames
        )
        SettingsRow(
            title: "Encrypt this Mac's disk with FileVault",
            detail: "Recommended. FileVault encrypts everything on this Mac at rest so patient data can't be read if the computer is lost or stolen. macOS manages it; it doesn't affect your backups."
        ) {
            Button("Open Settings") { SystemSettingsLinks.openFileVaultSettings() }
                .buttonStyle(.themed)
        }
        SettingsHairline()
        VStack(alignment: .leading, spacing: 8) {
            Text("Security posture").eyebrowStyle()
            SecurityPostureView()
        }
        auditLogSection
    }

    private var auditLogSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Security audit log").eyebrowStyle()
            SettingsCaption("An on-device record of app unlocks (when app lock is on), encryption changes and exports. Deletions and backups are not recorded yet. It holds no names or clinical content and never leaves this Mac. It supports, but does not by itself satisfy, HIPAA's audit-control requirement (§164.312(b)).")
            if auditEntries.isEmpty {
                SettingsCard {
                    SettingsCaption("No activity recorded yet. App unlocks are only logged when app lock is on.")
                }
            } else {
                SettingsRowsCard {
                    ForEach(Array(auditEntries.prefix(auditPreviewLimit).enumerated()), id: \.offset) { item in
                        if item.offset > 0 { SettingsHairline() }
                        HStack {
                            Text(item.element.action.displayName)
                                .foregroundStyle(Theme.text.color)
                            Spacer()
                            Text(auditTimestamp(item.element))
                                .foregroundStyle(Theme.muted.color)
                        }
                        .font(Theme.Typography.caption)
                        .padding(.vertical, 9)
                    }
                }
                if auditEntries.count > auditPreviewLimit {
                    SettingsCaption("Showing the \(auditPreviewLimit) most recent of \(auditEntries.count) entries.")
                }
            }
            HStack(spacing: 8) {
                Button("Refresh", action: loadAuditEntries)
                    .buttonStyle(.themed)
                Button("Export…", action: exportAuditLog)
                    .buttonStyle(.themed)
                    .disabled(auditEntries.isEmpty)
                Spacer()
            }
        }
    }

    // MARK: - Audit log viewer

    /// Load the log into the viewer, newest first. `entries()` reads file order
    /// (oldest first), so reverse for a most-recent-at-top list.
    private func loadAuditEntries() {
        auditEntries = Array((appModel.audit?.entries() ?? []).reversed())
    }

    private func auditTimestamp(_ entry: AuditEvent) -> String {
        guard let date = entry.date else { return entry.at }
        return Self.auditDateFormatter.string(from: date)
    }

    /// Human-readable, oldest-first rendering for the exported file (a log reads
    /// naturally top-to-bottom in time). Header states the PHI-free scope.
    private func auditExportText() -> String {
        let all = appModel.audit?.entries() ?? []
        let header = """
        Aletheia security audit log (HIPAA §164.312(b)) — an on-device record with no PHI.
        Exported \(Self.auditDateFormatter.string(from: Date()))

        """
        let lines = all.map { entry -> String in
            let ts = entry.date.map { Self.auditDateFormatter.string(from: $0) } ?? entry.at
            var parts = ["\(ts)  \(entry.action.displayName)"]
            if let subject = entry.subjectID { parts.append("record \(subject)") }
            if let detail = entry.detail { parts.append(detail) }
            return parts.joined(separator: "  ·  ")
        }
        return header + lines.joined(separator: "\n") + "\n"
    }

    private func exportAuditLog() {
        let name = FileSaver.fileName("Aletheia Audit Log", Self.auditFileStamp())
        if FileSaver.saveText(auditExportText(), suggestedName: "\(name).txt") {
            // The export itself is an ePHI-adjacent action worth recording.
            appModel.recordAudit(.auditLogExported)
            loadAuditEntries()
        }
    }

    private static let auditDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private static func auditFileStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
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

    /// Launches the installed Ollama and waits until it answers, then refreshes
    /// the status chip.
    private func startOllama() async {
        isStartingOllama = true
        defer { isStartingOllama = false }
        do {
            try await AIEngineRecovery.perform(.notRunning, actions: .live(integrations: integrations))
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

    /// Maps the free-form `ollamaModelName` to the tiered picker: a known catalog
    /// tag selects that row; anything else selects "Custom…" and reveals the text
    /// field. Picking a catalog row sets the tag; switching to Custom clears a
    /// catalog tag so the field starts empty for typing.
    private var ollamaModelSelection: Binding<String> {
        Binding(
            get: { OllamaCatalog.contains(settings.ollamaModelName) ? settings.ollamaModelName : OllamaCatalog.customTag },
            set: { newValue in
                if newValue == OllamaCatalog.customTag {
                    if OllamaCatalog.contains(settings.ollamaModelName) { settings.ollamaModelName = "" }
                } else {
                    settings.ollamaModelName = newValue
                }
            }
        )
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
