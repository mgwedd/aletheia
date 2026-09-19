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

    var body: some View {
        Form {
            Section("Security Overview") {
                SecurityPostureView()
            }

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
                    Picker("Model", selection: ollamaModelSelection) {
                        ForEach(OllamaCatalog.options) { option in
                            Text("\(option.label) (~\(String(format: "%.1f", option.approxSizeGB)) GB)")
                                .tag(option.tag)
                        }
                        Text("Custom…").tag(OllamaCatalog.customTag)
                    }
                    if let option = OllamaCatalog.option(for: settings.ollamaModelName) {
                        Text(option.blurb).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Recommended for your Mac (\(settings.hardware.shortDescription)): \(settings.recommendation.ollamaModel).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !OllamaCatalog.contains(settings.ollamaModelName) {
                        TextField("Ollama model tag (e.g. qwen2.5:7b)", text: $settings.ollamaModelName)
                    }
                    Text("Ollama must be installed and running (its icon shows in the menu bar). Get it from ollama.com.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        if isPullingOllamaModel {
                            ProgressView(value: ollamaPullProgress)
                            Text(ollamaPullStatus).font(.caption).foregroundStyle(.secondary)
                        } else {
                            Button("Download \(settings.ollamaModelName)") { Task { await pullOllamaModel() } }
                                .disabled(settings.ollamaModelName.trimmingCharacters(in: .whitespaces).isEmpty)
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

            Section("Note-Taking Format") {
                Picker("Default format", selection: $settings.progressNoteFormat) {
                    ForEach(ProgressNoteFormat.allCases) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                Text(settings.progressNoteFormat.blurb)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("The format new session notes start in. You can still switch formats for any single session on its Note tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

            Section("Privacy") {
                Toggle("Keep audio recordings after transcription", isOn: $settings.keepAudioRecordings)
                    .disabled(!encryption.isEnabled)
                Text(audioRetentionCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Security") {
                Toggle("Require Touch ID or password to open", isOn: $settings.appLockEnabled)
                Text("Locks the app when it opens and whenever it's hidden, so your patients' notes stay behind your Touch ID or Mac password.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                Picker("Auto-lock after", selection: idleAutoLockSelection) {
                    ForEach(IdleAutoLockTimeout.allCases) { timeout in
                        Text(timeout.displayName).tag(timeout)
                    }
                }
                .disabled(!settings.appLockEnabled)
                Text("Automatically re-locks after this much time with no activity — HIPAA's required \"automatic logoff.\" Needs \"Require Touch ID or password to open\" turned on above.")
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

            Section("Extra Encryption") {
                encryptionSection
            }

            Section("Security Audit Log") {
                Text("An on-device record of actions that touch patient data — app unlocks, encryption changes, exports and deletions. It holds no names or clinical content, never leaves this Mac, and satisfies HIPAA's audit-control requirement (§164.312(b)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if auditEntries.isEmpty {
                    Text("No activity recorded yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(auditEntries.prefix(auditPreviewLimit).enumerated()), id: \.offset) { item in
                        HStack {
                            Text(item.element.action.displayName)
                            Spacer()
                            Text(auditTimestamp(item.element)).foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                    if auditEntries.count > auditPreviewLimit {
                        Text("Showing the \(auditPreviewLimit) most recent of \(auditEntries.count) entries.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("Refresh", action: loadAuditEntries)
                    Spacer()
                    Button("Export…", action: exportAuditLog)
                        .disabled(auditEntries.isEmpty)
                }
            }

            Section("Backup") {
                Toggle("Keep my data out of Time Machine & iCloud backups", isOn: $settings.keepDataOutOfSystemBackups)
                Text("On by default. Your data folder can hold unencrypted patient data (and audio/transcript files), so Aletheia keeps it out of macOS system backups — nothing ends up in Time Machine or iCloud in the clear. Use the encrypted snapshot below for off-device recovery. Turn this off only if you back up to an encrypted Time Machine disk and want it included.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                Toggle("Keep an encrypted backup copy on this Mac", isOn: $settings.localEncryptedBackupEnabled)
                Text("An end-to-end-encrypted snapshot of your database, sealed with your key — safe to sit in Time Machine or on an external drive. Only you can open it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                Toggle("Also back up to iCloud (end-to-end encrypted)", isOn: $settings.iCloudEncryptedBackupEnabled)
                Text("Uploads the same encrypted snapshot to your private iCloud. It's sealed with your key before it leaves this Mac, so Apple only ever stores data it can't read. Activates in a signed build with iCloud configured; your choice is saved until then.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    Label("Updates automatically", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            return "By default, recordings are deleted the moment a session is transcribed — the transcript is kept as the document of record. Turn this on to keep the original audio too; it stays encrypted at rest with your other data."
        } else {
            return "By default, recordings are deleted the moment a session is transcribed — only the transcript is kept. Keeping the original audio requires \"Extra Encryption\" below, so any retained recording stays encrypted at rest rather than sitting on disk in the clear."
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
                    Text("Off").font(.body.weight(.medium))
                    Text("Encrypt your notes, transcripts, summaries, chat, patient records and recordings on disk with a passphrase — protecting them even on an external drive, a backup, or a synced folder. FileVault is still recommended as the baseline.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Turn On…") { showEncryptionSetup = true }
                    .disabled(settings.dataRootURL == nil)
            }
        case .unlocked:
            Label("On — unlocked for this session", systemImage: "lock.fill")
                .foregroundStyle(.green)
            Text("Your data folder is encrypted at rest with your recovery passphrase.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                if isDisablingEncryption {
                    ProgressView().controlSize(.small)
                    Text("Decrypting…").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("Turn Off Encryption…", role: .destructive) { confirmDisableEncryption = true }
                }
                Spacer()
            }
        case .lockedNeedsPassphrase:
            Label("On — locked", systemImage: "lock")
                .foregroundStyle(.secondary)
            Text("Unlock from the main window to manage encryption.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
        healthChecks = await ToolHealth.runAllChecks(
            settings: settings,
            backend: integrations.effectiveAssistantBackend,
            assistant: integrations.makeAssistant(),
            authoritative: authoritative
        )
    }
}
