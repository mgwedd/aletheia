import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var integrations: Integrations
    @EnvironmentObject private var updateService: UpdateService
    @EnvironmentObject private var encryption: EncryptionManager
    @StateObject private var whisperDownloader = WhisperModelDownloader()
    @StateObject private var llamaDownloader = LlamaModelDownloader()
    @State private var ollamaPullProgress: Double = 0
    @State private var ollamaPullStatus: String = ""
    @State private var isPullingOllamaModel = false
    @State private var healthChecks: [ToolHealthCheck] = []
    @State private var isCheckingHealth = false
    @State private var showSetup = false
    @State private var errorMessage: String?
    @State private var showEncryptionSetup = false
    @State private var confirmDisableEncryption = false
    @State private var isDisablingEncryption = false
    @State private var rememberOnDevice = false
    /// Audit-log entries for the viewer, newest first. Loaded on appear and after
    /// an export; a snapshot, not a live binding (the log is append-only on disk).
    @State private var auditEntries: [AuditEvent] = []
    private let auditPreviewLimit = 15
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(AppearancePreference.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Security Overview") {
                SecurityPostureView()
            }

            Section("Data Folder") {
                HStack {
                    Text(settings.dataRootURL?.path ?? "Not chosen yet")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(settings.dataRootURL == nil ? Theme.muted.color : Theme.text.color)
                    Spacer()
                    Button("Change…", action: chooseFolder)
                        .buttonStyle(.themed)
                        .controlSize(.small)
                }
            }

            Section("Speech-to-Text Model") {
                Picker("Model", selection: $settings.whisperModel) {
                    ForEach(WhisperModel.allCases) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                Text("Recommended for your Mac (\(settings.hardware.shortDescription)): \(settings.recommendation.whisperModel.shortName).")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.muted.color)
                HStack {
                    if whisperDownloader.isDownloading {
                        ProgressView(value: whisperDownloader.progress)
                        Text("\(Int(whisperDownloader.progress * 100))%")
                    } else if FileManager.default.fileExists(atPath: settings.whisperModelPath.path) {
                        Label("Downloaded", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.accent.color)
                        Spacer()
                        Button("Re-download") { Task { await downloadWhisperModel() } }
                            .buttonStyle(.themed)
                            .controlSize(.small)
                    } else {
                        Text("Not downloaded (~\(settings.whisperModel.approximateSizeMB) MB)").foregroundStyle(Theme.muted.color)
                        Spacer()
                        Button("Download") { Task { await downloadWhisperModel() } }
                            .buttonStyle(.themed)
                            .controlSize(.small)
                    }
                }
            }

            Section("AI Summaries & Chat") {
                Picker("Engine", selection: $settings.assistantBackend) {
                    // Apple Intelligence is intentionally hidden for now (see
                    // Integrations.appleIntelligenceBlocked) — keep AI fully on
                    // backends we can prove stay on this Mac. "Built-in model"
                    // (embedded llama.cpp) is a .dev-tier module until stable, so
                    // production/preview don't advertise a backend that today
                    // falls back to Ollama. See EmbeddedLlamaFeatureModule and
                    // AssistantBackend.selectableOptions, which this defers to
                    // so the gating itself is unit-tested.
                    ForEach(AssistantBackend.selectableOptions(
                        embeddedLlamaAvailable: appModel.featureRegistry.contains(id: EmbeddedLlamaFeatureModule.id),
                        appleIntelligenceBlocked: Integrations.appleIntelligenceBlocked
                    )) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }
                Text(settings.assistantBackend.summary)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.muted.color)
                LabeledContent("In use now", value: integrations.effectiveAssistantBackend.displayName)
                    .font(Theme.Typography.caption)

                if integrations.effectiveAssistantBackend == .ollama {
                    Divider()
                    Picker("Model", selection: ollamaModelSelection) {
                        ForEach(OllamaCatalog.options) { option in
                            Text("\(option.label) (~\(String(format: "%.1f", option.approxSizeGB)) GB)")
                                .tag(option.tag)
                        }
                        Text("Custom…").tag(OllamaCatalog.customTag)
                    }
                    if let option = OllamaCatalog.option(for: settings.ollamaModelName) {
                        Text(option.blurb).font(Theme.Typography.caption).foregroundStyle(Theme.muted.color)
                    }
                    Text("Recommended for your Mac (\(settings.hardware.shortDescription)): \(settings.recommendation.ollamaModel).")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.muted.color)
                    if !OllamaCatalog.contains(settings.ollamaModelName) {
                        TextField("Ollama model tag (e.g. qwen2.5:7b)", text: $settings.ollamaModelName)
                    }
                    Text("Ollama must be installed and running (its icon shows in the menu bar). Get it from ollama.com.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.muted.color)
                    HStack {
                        if isPullingOllamaModel {
                            ProgressView(value: ollamaPullProgress)
                            Text(ollamaPullStatus).font(Theme.Typography.caption).foregroundStyle(Theme.muted.color)
                        } else {
                            Button("Download \(settings.ollamaModelName)") { Task { await pullOllamaModel() } }
                                .buttonStyle(.themed)
                                .controlSize(.small)
                                .disabled(settings.ollamaModelName.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                } else if integrations.effectiveAssistantBackend == .appleIntelligence {
                    Label("Runs on your Mac with Apple Intelligence — nothing to install or download.", systemImage: "apple.logo")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.muted.color)
                }
            }

            Section("AI Instructions") {
                Text("The standing instructions sent with every AI request — the assistant's voice and rules. Editing this changes how summaries and chat behave.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.muted.color)
                EditorField(text: $settings.systemPrompt, minHeight: 140)
                HStack {
                    Spacer()
                    Button("Reset to Default") { settings.systemPrompt = Prompts.defaultSystemPrompt }
                        .buttonStyle(.themed)
                        .controlSize(.small)
                        .disabled(settings.systemPrompt == Prompts.defaultSystemPrompt)
                }
            }

            Section("Note-Taking Format") {
                Picker("Default format", selection: $settings.progressNoteFormat) {
                    ForEach(ProgressNoteFormat.allCases) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                Text(settings.progressNoteFormat.blurb)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.muted.color)
                Text("The format new session notes start in. You can still switch formats for any single session on its Note tab.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.muted.color)
                Picker("Summary length", selection: $settings.summaryVerbosity) {
                    ForEach(SummaryVerbosity.allCases) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                Text(settings.summaryVerbosity.blurb + " Clarity comes first at every length.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.muted.color)
            }

            // The .dev-tier "Built-in Model" (embedded llama.cpp) management UI —
            // offered only when the module ships AND the runtime is linked.
            if LlamaRuntime.isBuilt && appModel.featureRegistry.contains(id: EmbeddedLlamaFeatureModule.id) {
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
                            Label("Downloaded", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.accent.color)
                            Spacer()
                            Button("Re-download") { Task { await downloadLlamaModel() } }
                                .buttonStyle(.themed)
                                .controlSize(.small)
                        } else {
                            Text("Not downloaded (~\(settings.llamaModel.approximateSizeMB) MB)").foregroundStyle(Theme.muted.color)
                            Spacer()
                            Button("Download") { Task { await downloadLlamaModel() } }
                                .buttonStyle(.themed)
                                .controlSize(.small)
                        }
                    }
                }
            }

            if appModel.featureRegistry.contains(id: SpotlightFeatureModule.id) {
                Section("Spotlight Search") {
                    Toggle("Find patients in Spotlight", isOn: $settings.spotlightIndexingEnabled)
                        .onChange(of: settings.spotlightIndexingEnabled) { _, _ in appModel.reindexSpotlight() }
                    Text("Lets you open a patient or session straight from macOS Spotlight. Only names and dates are indexed — never transcripts or summaries. Anyone using this Mac can see indexed names, so leave this off on a shared computer.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.muted.color)
                }
            }

            Section("Privacy") {
                Toggle("Keep audio recordings after transcription", isOn: $settings.keepAudioRecordings)
                    .disabled(!encryption.isEnabled)
                Text(audioRetentionCaption)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.muted.color)
            }

            Section("Security") {
                Toggle("Require Touch ID or password to open", isOn: $settings.appLockEnabled)
                Text("Locks the app when it opens and whenever it's hidden, so your patients' notes stay behind your Touch ID or Mac password.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.muted.color)
                Divider()
                Picker("Auto-lock after", selection: idleAutoLockSelection) {
                    ForEach(IdleAutoLockTimeout.allCases) { timeout in
                        Text(timeout.displayName).tag(timeout)
                    }
                }
                .disabled(!settings.appLockEnabled)
                Text("Automatically re-locks after this much time with no activity — HIPAA's required \"automatic logoff.\" Needs \"Require Touch ID or password to open\" turned on above.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.muted.color)
                Divider()
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Encrypt this Mac's disk with FileVault")
                            .font(Theme.Typography.body.weight(.medium))
                        Text("Recommended. FileVault encrypts everything on this Mac at rest so patient data can't be read if the computer is lost or stolen. macOS manages it; it doesn't affect your backups.")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.muted.color)
                    }
                    Spacer()
                    Button("Open Settings") { SystemSettingsLinks.openFileVaultSettings() }
                        .buttonStyle(.themed)
                        .controlSize(.small)
                }
            }

            // Hidden only when there's nothing to manage: encryption is off and this
            // build doesn't offer turning it on. Once a folder is encrypted — by
            // this build or an earlier one — the section (and its unlock/manage
            // affordances) stays unconditional regardless of build tier.
            if encryption.isEnabled || appModel.featureRegistry.contains(id: AtRestEncryptionFeatureModule.id) {
                Section("Extra Encryption") {
                    encryptionSection
                }
            }

            Section("Security Audit Log") {
                Text("An on-device record of actions that touch patient data — app unlocks, encryption changes, exports and deletions. It holds no names or clinical content, never leaves this Mac, and satisfies HIPAA's audit-control requirement (§164.312(b)).")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.muted.color)
                if auditEntries.isEmpty {
                    Text("No activity recorded yet.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.muted.color)
                } else {
                    ForEach(Array(auditEntries.prefix(auditPreviewLimit).enumerated()), id: \.offset) { item in
                        HStack {
                            Text(item.element.action.displayName)
                            Spacer()
                            Text(auditTimestamp(item.element)).foregroundStyle(Theme.muted.color)
                        }
                        .font(Theme.Typography.caption)
                    }
                    if auditEntries.count > auditPreviewLimit {
                        Text("Showing the \(auditPreviewLimit) most recent of \(auditEntries.count) entries.")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.muted.color)
                    }
                }
                HStack {
                    Button("Refresh", action: loadAuditEntries)
                        .buttonStyle(.themed)
                        .controlSize(.small)
                    Spacer()
                    Button("Export…", action: exportAuditLog)
                        .buttonStyle(.themed)
                        .controlSize(.small)
                        .disabled(auditEntries.isEmpty)
                }
            }

            Section("Backup") {
                Toggle("Keep my data out of Time Machine & iCloud backups", isOn: $settings.keepDataOutOfSystemBackups)
                Text("Off by default, so Time Machine includes your data folder — Aletheia doesn't make a backup of its own yet, so without this you'd have only one copy. Your data folder can hold unencrypted patient data (and audio/transcript files), so keep your Time Machine backups on an encrypted disk. Turn this on only if you'd rather keep the folder out of macOS system backups and rely on your own copy instead.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.muted.color)
                Divider()
                Toggle("Keep an encrypted backup copy on this Mac", isOn: $settings.localEncryptedBackupEnabled)
                Text("An end-to-end-encrypted snapshot of your database, sealed with your key — safe to sit in Time Machine or on an external drive. Only you can open it. Not active in this build yet: your choice is saved, but no backup copy is written until it is.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.muted.color)
                Divider()
                Toggle("Also back up to iCloud (end-to-end encrypted)", isOn: $settings.iCloudEncryptedBackupEnabled)
                Text("Uploads the same encrypted snapshot to your private iCloud. It's sealed with your key before it leaves this Mac, so Apple only ever stores data it can't read. Activates in a signed build with iCloud configured; your choice is saved until then.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.muted.color)
            }

            Section("Legal") {
                HStack(spacing: 16) {
                    Link("Terms of Service", destination: Legal.termsURL)
                    Link("Privacy Policy", destination: Legal.privacyURL)
                }
                if let accepted = settings.acceptedLegalDate, settings.hasAcceptedCurrentLegal {
                    LabeledContent("Accepted", value: legalAcceptanceStamp(version: settings.acceptedLegalVersion, at: accepted))
                        .font(Theme.Typography.caption)
                }
                Text("Your acceptance of the terms is recorded only on this Mac. It is never sent anywhere.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.muted.color)
            }

            Section("Software Update") {
                LabeledContent("Current version", value: appVersionString)
                HStack {
                    if updateService.isChecking {
                        ProgressView().controlSize(.small)
                        Text("Checking…").foregroundStyle(Theme.muted.color)
                    } else {
                        Button("Check for Updates") {
                            Task { await updateService.checkForUpdates(force: true) }
                        }
                        .buttonStyle(.themed)
                        .controlSize(.small)
                    }
                    Spacer()
                }
                Text("Aletheia checks for a new version on launch and lets you know when one is ready.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.muted.color)
            }

            Section("Status") {
                // Only on the very first load; later refreshes are silent so the
                // list doesn't gain and lose a row every few seconds.
                if isCheckingHealth && healthChecks.isEmpty {
                    ProgressView("Checking…")
                }
                ForEach(healthChecks) { check in
                    HStack(alignment: .top) {
                        statusIcon(check.status)
                        VStack(alignment: .leading) {
                            Text(check.title).font(Theme.Typography.body.weight(.medium))
                            Text(check.detail).font(Theme.Typography.caption).foregroundStyle(Theme.muted.color)
                        }
                    }
                }
                HStack {
                    Label("Updates automatically", systemImage: "arrow.triangle.2.circlepath")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.muted.color)
                    Spacer()
                    if appModel.featureRegistry.contains(id: DoctorFeatureModule.id) {
                        Button("Aletheia Doctor…") { openWindow(id: DoctorFeatureModule.windowID) }
                            .buttonStyle(.themed)
                            .controlSize(.small)
                    }
                    Button("Setup Assistant…") { showSetup = true }
                        .buttonStyle(.themed)
                        .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        .tint(Theme.accent.color)
        .navigationTitle("Settings")
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

    /// Explains the audio-retention toggle, and why it's unavailable until
    /// at-rest encryption is on — kept audio must be ciphertext, never plaintext.
    private var audioRetentionCaption: String {
        if encryption.isEnabled {
            return "By default, recordings are deleted the moment a session is transcribed — the transcript is kept as the document of record. (If no speech is detected, the recording is kept so nothing is lost.) Turn this on to keep the original audio too; it stays encrypted at rest with your other data."
        } else {
            return "By default, recordings are deleted the moment a session is transcribed — only the transcript is kept. (If no speech is detected, the recording is kept so nothing is lost, and it isn't encrypted while Extra Encryption is off.) Keeping the original audio requires \"Extra Encryption\" below, so any retained recording stays encrypted at rest rather than sitting on disk in the clear."
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

    @ViewBuilder
    private var encryptionSection: some View {
        switch encryption.state {
        case .disabled:
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Off").font(Theme.Typography.body.weight(.medium))
                    Text("Encrypt your notes, transcripts, summaries, chat, patient records and recordings on disk with a passphrase — protecting them even on an external drive, a backup, or a synced folder. FileVault is still recommended as the baseline.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.muted.color)
                }
                Spacer()
                Button("Turn On…") { showEncryptionSetup = true }
                    .buttonStyle(.themed)
                    .controlSize(.small)
                    .disabled(settings.dataRootURL == nil)
            }
        case .unlocked:
            Label("On — unlocked for this session", systemImage: "lock.fill")
                .foregroundStyle(Theme.accent.color)
            Text("Your data folder is encrypted at rest with your recovery passphrase.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.muted.color)
            Toggle("Unlock automatically on this Mac", isOn: $rememberOnDevice)
                .onChange(of: rememberOnDevice) { _, on in
                    do {
                        if on { try encryption.rememberOnDevice() } else { encryption.forgetOnDevice() }
                    } catch {
                        errorMessage = error.localizedDescription
                        rememberOnDevice = false
                    }
                }
            Text("Stores the key in this Mac's login keychain so you don't retype your passphrase each launch. Turn off for maximum security — Aletheia will always ask.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.muted.color)
            HStack {
                if isDisablingEncryption {
                    ProgressView().controlSize(.small)
                    Text("Decrypting…").font(Theme.Typography.caption).foregroundStyle(Theme.muted.color)
                } else {
                    Button("Turn Off Encryption…", role: .destructive) { confirmDisableEncryption = true }
                        .buttonStyle(.themed)
                        .controlSize(.small)
                }
                Spacer()
            }
        case .lockedNeedsPassphrase:
            Label("On — locked", systemImage: "lock")
                .foregroundStyle(Theme.muted.color)
            Text("Unlock from the main window to manage encryption.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.muted.color)
        }
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

    @ViewBuilder
    private func statusIcon(_ status: ToolHealthCheck.Status) -> some View {
        switch status {
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent.color)
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.callAudio.color)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.recording.color)
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
        // Only touch the view when something changed, so the 2.5 s refresh
        // doesn't re-render (and shift) an unchanged list.
        if latest != healthChecks { healthChecks = latest }
    }
}
