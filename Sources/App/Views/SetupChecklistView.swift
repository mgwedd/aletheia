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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    //   ━━━━━━━━━━━━━━━━━━━━━━──────────────  2 of 6 done
    //   ┌──────────────────────────────────────────────────┐
    //   │ ✓  Data folder                              Done │
    //   │ ✓  Microphone                               Done │
    //   │ 3  Screen Recording              [Allow]         │  ← current: tinted, primary
    //   │ 4  Transcription model           [Download]      │
    //   └──────────────────────────────────────────────────┘
    var body: some View {
        let progress = Setup.progress(items)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ThemeProgressBar(value: progress.fraction)
                    .frame(maxWidth: 280)
                    .accessibilityLabel("Setup progress")
                if progress.total > 0 {
                    Text("\(progress.done) of \(progress.total) done")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted.color)
                        .monospacedDigit()
                }
                if isChecking { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
            }

            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.check.kind) { index, item in
                    if index > 0 {
                        Rectangle().fill(Theme.line.color).frame(height: 1)
                    }
                    row(item, number: index + 1, isCurrent: item.id == progress.currentID)
                }
            }
            .background(Theme.window.color)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.line.color, lineWidth: 1)
            )
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: progress)

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

    private func row(_ item: SetupItem, number: Int, isCurrent: Bool) -> some View {
        HStack(alignment: .center, spacing: 16) {
            marker(item.status, number: number, isCurrent: isCurrent)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text.color)
                Text(item.detail)
                    .font(.system(size: 13))
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
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accent.color)
            } else if let action = item.action {
                actionButton(action, isCurrent: isCurrent)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isCurrent ? Theme.accentTint.color : .clear)
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

    /// The 26pt step marker. Done: accent fill with a check. Current: accent
    /// ring with the number. Pending: hairline ring with a muted number. A
    /// warning that isn't the current step keeps its "!" so "needs attention"
    /// still reads at a glance.
    @ViewBuilder
    private func marker(_ status: ToolHealthCheck.Status, number: Int, isCurrent: Bool) -> some View {
        if status == .ok {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.accentInk.color)
                .frame(width: 26, height: 26)
                .background(Theme.accent.color, in: Circle())
                .accessibilityLabel("Done")
        } else if isCurrent {
            Text("\(number)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accent.color)
                .frame(width: 26, height: 26)
                .overlay(Circle().strokeBorder(Theme.accent.color, lineWidth: 1.5))
                .accessibilityLabel("Step \(number), current")
        } else if status == .warning {
            Image(systemName: "exclamationmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.callAudio.color)
                .frame(width: 26, height: 26)
                .overlay(Circle().strokeBorder(Theme.callAudio.color, lineWidth: 1.5))
                .accessibilityLabel("Needs attention")
        } else {
            Text("\(number)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.muted.color)
                .frame(width: 26, height: 26)
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
        items = Setup.items(from: await ToolHealth.runAllChecks(
            settings: settings,
            backend: integrations.effectiveAssistantBackend,
            assistant: integrations.makeAssistant(),
            authoritative: authoritative,
            includeScheduling: appModel.featureRegistry.contains(id: EventKitSchedulingFeatureModule.id)
        ))
    }

    /// After sending the therapist to grant Screen Recording, watch for the grant
    /// and refresh the checklist the moment it lands — so the row turns green on
    /// its own, with no "quit and relaunch" step. Gives up quietly after a while;
    /// the Refresh button and the next `.task` still catch it later.
    private func pollForScreenRecordingGrant() async {
        for _ in 0..<60 { // ~30s at 0.5s intervals
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
            if await SystemAudioCapture.verifyAccessGranted() {
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
                SystemSettingsLinks.openScreenRecordingSettings()
                await pollForScreenRecordingGrant()
            }
        case .openScreenRecordingSettings:
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
