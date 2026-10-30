import SwiftUI

/// A guided checklist that shows each setup requirement with a one-click fix,
/// so the therapist never has to hunt through docs or Terminal. Used on first
/// run and reachable again from Settings.
struct SetupChecklistView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var integrations: Integrations

    @StateObject private var whisperDownloader = WhisperModelDownloader()
    @ObservedObject private var llamaDownloader = LlamaModelDownloader.shared
    @State private var items: [SetupItem] = []
    @State private var isChecking = false
    @State private var busyAction: SetupAction?
    @State private var errorMessage: String?
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { QuietUI.reducesMotion(systemReduceMotion) }

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
                    Text(progress.label)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted.color)
                        .monospacedDigit()
                }
                ProgressView().controlSize(.small).opacity(isChecking ? 1 : 0)
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

            Text("Everything runs on this Mac. Aletheia's AI model downloads inside Aletheia and runs here; nothing else to install.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.muted.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .liveStatusRefresh { authoritative in await refresh(authoritative: authoritative) }
        .onChange(of: settings.acceptedLegalVersion) { _, _ in
            Task { await refresh() }
        }
        .onChange(of: settings.dataRootURL) { _, _ in
            Task { await refresh() }
        }
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
                // The model's license, readable before the download starts.
                if item.action == .downloadTranscriptionModel {
                    ModelLicenseLink(settings.whisperModel)
                }
                if item.action == .downloadBuiltInModel {
                    ModelLicenseLink(settings.llamaModel)
                }
                if item.action == .downloadTranscriptionModel, whisperDownloader.isDownloading {
                    ProgressView(value: whisperDownloader.progress)
                        .tint(Theme.accent.color)
                }
                if item.action == .downloadBuiltInModel, llamaDownloader.isDownloading {
                    ProgressView(value: llamaDownloader.progress)
                        .tint(Theme.accent.color)
                    if !llamaDownloader.statusText.isEmpty {
                        Text(llamaDownloader.statusText)
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
            .disabled(busyAction != nil || whisperDownloader.isDownloading || llamaDownloader.isDownloading)
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
        let latest = Setup.items(from: await ToolHealth.runAllChecks(
            settings: settings,
            backend: integrations.effectiveAssistantBackend,
            assistant: integrations.makeAssistant(),
            authoritative: authoritative,
            includeScheduling: appModel.featureRegistry.contains(id: EventKitSchedulingFeatureModule.id)
        ))
        // Unchanged results leave the list alone.
        if latest.map(\.check) != items.map(\.check) { items = latest }
    }

    private func perform(_ action: SetupAction) async {
        let runner = SetupActionRunner(system: LiveSetupSystem(), settings: settings, rebuildStore: { appModel.rebuildStore() })
        do {
            if try await runner.perform(action) {
                await refresh()
                return
            }
        } catch {
            errorMessage = error.localizedDescription
            await refresh()
            return
        }
        switch action {
        case .downloadTranscriptionModel:
            do {
                try await whisperDownloader.download(settings.whisperModel, to: settings.whisperModelPath)
            } catch {
                errorMessage = error.localizedDescription
            }
        case .downloadBuiltInModel:
            do {
                try await llamaDownloader.download(settings.llamaModel, to: LlamaRuntime.modelURL(for: settings.llamaModel))
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
        case .reviewTerms:
            NSWorkspace.shared.open(Legal.termsURL)
        default:
            break
        }
        await refresh()
    }
}
