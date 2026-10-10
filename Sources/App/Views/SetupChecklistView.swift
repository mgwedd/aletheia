import SwiftUI

/// A guided checklist that shows each setup requirement with a one-click fix,
/// so the therapist never has to hunt through docs or Terminal. Used on first
/// run and reachable again from Settings.
struct SetupChecklistView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var integrations: Integrations

    @StateObject private var whisperDownloader = WhisperModelDownloader()
    @State private var items: [SetupItem] = []
    @State private var isChecking = false
    @State private var busyAction: SetupAction?
    @State private var ollamaPullProgress: Double = 0
    @State private var ollamaPullStatus = ""
    @State private var errorMessage: String?

    //   Setup checklist                         3 of 6 done
    //   ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━──────────────────────
    //   ┌──────────────────────────────────────────────────┐
    //   │ ✓  Data folder                              Done │
    //   │ 2  Microphone                     [Allow access] │  ← current: tinted, primary
    //   │ 3  Transcription model               [Download]  │
    //   └──────────────────────────────────────────────────┘
    var body: some View {
        let progress = Setup.progress(items)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Setup checklist")
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.text.color)
                Spacer()
                ProgressView().controlSize(.small).opacity(isChecking ? 1 : 0)
                if progress.total > 0 {
                    Text("\(progress.done) of \(progress.total) done")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.muted.color)
                        .monospacedDigit()
                }
            }
            progressBar(progress.fraction)

            VStack(spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.element.check.kind) { index, item in
                    row(item, number: index + 1, isCurrent: item.id == progress.currentID)
                }
            }
            .padding(6)
            .themeCard()
            .animation(.easeOut(duration: 0.2), value: progress)

            Label(settings.recommendation.summary, systemImage: "cpu")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.muted.color)

            Text("Everything runs on this Mac. Aletheia's AI uses Ollama — a free local engine you install once — and the AI model then downloads inside Aletheia. This list updates itself as you grant each permission; no restart needed.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.muted.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .liveStatusRefresh { authoritative in await refresh(authoritative: authoritative) }
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func progressBar(_ fraction: Double) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.chip.color)
                Capsule()
                    .fill(Theme.accent.color)
                    .frame(width: geometry.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.25), value: fraction)
        .accessibilityElement()
        .accessibilityLabel("Setup progress")
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
    }

    private func row(_ item: SetupItem, number: Int, isCurrent: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            marker(item.status, number: number)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(Theme.Typography.body.weight(.medium))
                    .foregroundStyle(Theme.text.color)
                Text(item.detail)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.muted.color)
                    .fixedSize(horizontal: false, vertical: true)
                if item.action == .downloadTranscriptionModel, whisperDownloader.isDownloading {
                    ProgressView(value: whisperDownloader.progress)
                        .tint(Theme.accent.color)
                }
                if item.action == .downloadOllamaModel, busyAction == .downloadOllamaModel {
                    ProgressView(value: ollamaPullProgress)
                        .tint(Theme.accent.color)
                    Text(ollamaPullStatus)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted.color)
                }
                if item.action == .launchOllama, busyAction == .launchOllama {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Starting Ollama…")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.muted.color)
                    }
                }
            }
            Spacer(minLength: 8)
            if item.status == .ok {
                Text("Done")
                    .font(Theme.Typography.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent.color)
                    .padding(.top, 2)
            } else if let action = item.action {
                actionButton(action, isCurrent: isCurrent)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            isCurrent ? Theme.accentTint.color : .clear,
            in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
        )
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func actionButton(_ action: SetupAction, isCurrent: Bool) -> some View {
        let button = Button(action.label) { Task { await perform(action) } }
            .controlSize(.small)
            .disabled(busyAction != nil || whisperDownloader.isDownloading)
        if isCurrent {
            button.buttonStyle(.themePrimary)
        } else {
            button.buttonStyle(.themed)
        }
    }

    /// A filled check when done; the step's number otherwise (a warning keeps
    /// its triangle so "needs attention" still reads at a glance).
    @ViewBuilder
    private func marker(_ status: ToolHealthCheck.Status, number: Int) -> some View {
        switch status {
        case .ok:
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.accentInk.color)
                .frame(width: 22, height: 22)
                .background(Theme.accent.color, in: Circle())
                .accessibilityLabel("Done")
        case .warning:
            Image(systemName: "exclamationmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.callAudio.color)
                .frame(width: 22, height: 22)
                .overlay(Circle().strokeBorder(Theme.callAudio.color, lineWidth: 1.5))
                .accessibilityLabel("Needs attention")
        case .failed:
            Text("\(number)")
                .font(Theme.Typography.caption.weight(.semibold))
                .foregroundStyle(Theme.muted.color)
                .frame(width: 22, height: 22)
                .overlay(Circle().strokeBorder(Theme.line.color, lineWidth: 1.5))
                .accessibilityLabel("Step \(number), not done")
        }
    }

    /// Re-runs the checks and updates the rows. Skips a run that would overlap an
    /// in-flight one (the background timer can tick mid-check), so the fast poll
    /// never piles up. `authoritative` is forwarded to the Screen Recording check
    /// so a just-granted permission is confirmed live on appear/activation.
    private func refresh(authoritative: Bool = true) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        let latest = Setup.items(from: await ToolHealth.runAllChecks(
            settings: settings,
            backend: integrations.effectiveAssistantBackend,
            assistant: integrations.makeAssistant(),
            authoritative: authoritative,
            includeScheduling: appModel.featureRegistry.contains(id: EventKitSchedulingFeatureModule.id)
        ))
        // Unchanged results leave the list alone, so the periodic refresh
        // doesn't redraw it.
        if latest.map(\.check) != items.map(\.check) { items = latest }
    }

    /// After sending the therapist to grant Screen Recording, watch for the grant
    /// and refresh the checklist the moment it lands — so the row turns green on
    /// its own, with no "quit and relaunch" step. Gives up quietly after a while;
    /// the Refresh button and the next `.task` still catch it later.
    private func pollForScreenRecordingGrant() async {
        for _ in 0..<60 { // ~30s at 0.5s intervals
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
            // Non-prompting check only: probing ScreenCaptureKit twice a second
            // re-showed the system dialog each time. When the user comes back
            // from System Settings, the activation refresh runs the one live
            // probe (see `ScreenAccessProbeGate`).
            if SystemAudioCapture.checkPermission() {
                await refresh()
                return
            }
        }
    }

    private func perform(_ action: SetupAction) async {
        switch action {
        case .chooseFolder:
            if let url = FolderPicker.choose() {
                do {
                    try settings.setDataRoot(url)
                    appModel.rebuildStore()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        case .requestMicrophone:
            _ = await MicRecorder.requestPermission()
        case .openMicrophoneSettings:
            SystemSettingsLinks.openMicrophoneSettings()
        case .requestScreenRecording:
            // One explicit system prompt. If already granted or the user grants
            // it now, we're done and the live poll flips the row green without a
            // relaunch. If macOS won't prompt (previously denied), send them to
            // the exact Settings pane instead. `requestPermission()` is async
            // because the underlying system call blocks until the user responds
            // to the dialog — awaiting it here keeps that wait off the main
            // thread instead of freezing the wizard step.
            let granted = await SystemAudioCapture.requestPermission()
            if !granted {
                ScreenAccessProbeGate.arm()
                SystemSettingsLinks.openScreenRecordingSettings()
                await pollForScreenRecordingGrant()
            }
        case .openScreenRecordingSettings:
            ScreenAccessProbeGate.arm()
            SystemSettingsLinks.openScreenRecordingSettings()
            await pollForScreenRecordingGrant()
        case .downloadTranscriptionModel:
            do {
                try await whisperDownloader.download(settings.whisperModel, to: settings.whisperModelPath)
            } catch {
                errorMessage = error.localizedDescription
            }
        case .enableAppleIntelligence:
            SystemSettingsLinks.openAppleIntelligenceSettings()
        case .requestCalendarAccess:
            // Ask up front; a prior denial won't re-prompt, so fall back to Settings.
            if await EventKitAccess.request(.calendar) == false,
               EventKitAccess.status(.calendar) == .denied {
                SystemSettingsLinks.openCalendarSettings()
            }
        case .requestRemindersAccess:
            if await EventKitAccess.request(.reminders) == false,
               EventKitAccess.status(.reminders) == .denied {
                SystemSettingsLinks.openRemindersSettings()
            }
        case .installOrOpenOllama:
            SystemSettingsLinks.openOllamaDownload()
        case .launchOllama:
            busyAction = .launchOllama
            defer { busyAction = nil }
            do {
                try await OllamaLauncher.launchAndWaitUntilReachable {
                    await integrations.makeAssistant().isReachable()
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        case .downloadOllamaModel:
            busyAction = .downloadOllamaModel
            ollamaPullProgress = 0
            defer { busyAction = nil }
            do {
                try await integrations.makeAssistant().pullModel(settings.ollamaModelName) { progress, status in
                    Task { @MainActor in
                        ollamaPullProgress = progress
                        ollamaPullStatus = status
                    }
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        await refresh()
    }
}
