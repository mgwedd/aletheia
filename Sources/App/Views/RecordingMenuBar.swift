import SwiftUI
import AppKit

/// The menu-bar panel for controlling session recording without hunting through
/// the main window. Because recording isn't automatic — the therapist decides
/// when the client has consented and the session has started — this makes the
/// Start / Pause / Stop controls reachable from anywhere, with the call window
/// in front.
///
/// Uses the shared app-level `SessionRecorder`, so what it shows and controls is
/// the same recording the session view drives.
struct RecordingMenuBar: View {
    @EnvironmentObject private var recorder: SessionRecorder
    @EnvironmentObject private var transcription: TranscriptionCoordinator
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var integrations: Integrations
    @State private var engineState: EngineRunState = .loading

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            engineStatusRow
            if let status = transcription.statusLine {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(status)
                }
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.muted.color)
            }
            hairline
            if let active = recorder.active {
                recordingControls(active)
            } else {
                startControls
            }
            hairline
            HStack {
                Button("Open Aletheia") { NSApp.activate(ignoringOtherApps: true) }
                Spacer()
                Button("Quit Aletheia") { NSApp.terminate(nil) }
            }
            .buttonStyle(.themed)
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 280)
        .background(Theme.panel.color)
        // Every time the menu is opened (this view is re-created) and every
        // 5s while it's open — cheap enough for the local-only health check
        // this reuses, and nothing here is data anyone would need faster.
        .liveStatusRefresh(every: 5) { _ in
            engineState = await EngineStatusProbe.currentState(settings: settings, integrations: integrations)
        }
    }

    // MARK: Engine status

    /// Read-only line showing whether the local AI engine (Ollama, or the
    /// embedded llama.cpp runtime) is reachable and which model is active —
    /// reuses the same health-check seam as Settings/setup, just polled here
    /// on a slower cadence since the menu bar is glanced at, not stared at.
    private var engineStatusRow: some View {
        let presentation = EngineStatusPresentation.present(engineState)
        return Label(presentation.label, systemImage: presentation.symbolName)
            .font(Theme.Typography.caption)
            .foregroundStyle(presentation.tint.color)
    }

    private var hairline: some View {
        Rectangle().fill(Theme.line.color).frame(height: 1)
    }

    // MARK: Recording

    @ViewBuilder
    private func recordingControls(_ active: SessionRecorder.ActiveRecording) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Chip(recorder.isPaused ? "Paused" : "Recording", tone: .recording, showsDot: true)
            Text(active.patientName)
                .font(Theme.Typography.body.weight(.semibold))
                .foregroundStyle(Theme.text.color)
                .lineLimit(1)
        }
        elapsedLabel

        HStack(spacing: 8) {
            if recorder.isPaused {
                Button { recorder.resume() } label: {
                    Label("Resume", systemImage: "play.fill")
                }
                .buttonStyle(.themed)
            } else {
                Button { recorder.pause() } label: {
                    Label("Pause", systemImage: "pause.fill")
                }
                .buttonStyle(.themed)
            }
            Button(role: .destructive) {
                Task { await recorder.stop() }
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.themeRecording)
        }

        Button("Show this session") {
            NSApp.activate(ignoringOtherApps: true)
            AppNavigator.shared.requestOpen(patientID: active.patientID)
        }
        .buttonStyle(.themed)
        .controlSize(.small)
    }

    /// Live elapsed time, in the same form as the session screen. TimelineView
    /// drives the per-second refresh; the paused span is still counted as
    /// wall-clock, which is fine for a "how long has this been open" cue.
    private var elapsedLabel: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(elapsedString(now: context.date))
                .font(Theme.Typography.display.monospacedDigit())
                .foregroundStyle(recorder.isPaused ? Theme.muted.color : Theme.text.color)
        }
    }

    private func elapsedString(now: Date) -> String {
        TranscriptTimeline.format(Int(recorder.elapsed(at: now)))
    }

    // MARK: Start

    @ViewBuilder
    private var startControls: some View {
        Text("Start a recording")
            .font(Theme.Typography.headline)
            .foregroundStyle(Theme.text.color)
        if appModel.patients.isEmpty {
            Text("Add a patient in the main window first.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.muted.color)
        } else {
            Text("Records a new session. Make sure your client has consented first.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.muted.color)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(appModel.patients) { patient in
                Button {
                    Task { await start(for: patient) }
                } label: {
                    Label(patient.name, systemImage: "record.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.themed)
            }
        }
    }

    private func start(for patient: Patient) async {
        guard let store = appModel.store,
              let session = appModel.startNewSession(for: patient) else { return }
        await recorder.start(
            micURL: store.micRecordingURL(for: patient, session: session),
            callURL: store.callRecordingURL(for: patient, session: session),
            context: .init(
                patientID: patient.id,
                patientName: patient.name,
                patientSlug: patient.slug,
                sessionFolder: session.folderName
            ),
            protector: appModel.currentProtector
        )
        NSApp.activate(ignoringOtherApps: true)
        AppNavigator.shared.requestOpen(patientID: patient.id)
    }
}

private extension EngineStatusTint {
    /// Running reads as the accent, starting/warning as the amber used for the
    /// call track, stopped as the recording red; unknown is muted. All have
    /// readable contrast on the panel in light, dark and Increase Contrast.
    var color: Color {
        switch self {
        case .green: return Theme.accent.color
        case .yellow: return Theme.callAudio.color
        case .red: return Theme.recording.color
        case .gray: return Theme.muted.color
        }
    }
}
